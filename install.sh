#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.1.0"
PROJECT_NAME="nat-v2ray"
HYSTERIA_BIN="/usr/local/bin/hysteria"
HY2_CONFIG_DIR="/etc/hysteria"
HY2_CONFIG_FILE="${HY2_CONFIG_DIR}/config.yaml"
HY2_ENV_FILE="${HY2_CONFIG_DIR}/nat-v2ray-hy2.env"
HY2_CERT_FILE="${HY2_CONFIG_DIR}/server.crt"
HY2_KEY_FILE="${HY2_CONFIG_DIR}/server.key"
HY2_SERVICE_FILE="/etc/systemd/system/hysteria-server.service"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue() { printf '\033[34m%s\033[0m\n' "$*"; }
die() { red "错误：$*"; exit 1; }

banner() {
  cat <<EOF
============================================================
 ${PROJECT_NAME} ${VERSION}
 NAT VPS 多协议一键脚本
============================================================
EOF
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "请使用 root 用户执行：sudo bash install.sh"
  fi
}

require_linux() {
  if [ "$(uname -s)" != "Linux" ]; then
    die "当前脚本只支持 Linux 服务器"
  fi
}

prompt_value() {
  local message="$1"
  local default_value="$2"
  local value
  printf '%s [%s]: ' "${message}" "${default_value}" >&2
  read -r value
  if [ -z "${value}" ]; then
    printf '%s\n' "${default_value}"
  else
    printf '%s\n' "${value}"
  fi
}

prompt_yes_no() {
  local message="$1"
  local default_value="$2"
  local value
  while true; do
    printf '%s [%s]: ' "${message}" "${default_value}" >&2
    read -r value
    value="${value:-${default_value}}"
    case "${value}" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) yellow "请输入 y 或 n" >&2 ;;
    esac
  done
}

validate_port() {
  local port="$1"
  if ! [[ "${port}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ]
}

prompt_port() {
  local message="$1"
  local default_port="$2"
  local port
  while true; do
    port="$(prompt_value "${message}" "${default_port}")"
    if validate_port "${port}"; then
      printf '%s\n' "${port}"
      return 0
    fi
    yellow "端口必须是 1-65535 的数字" >&2
  done
}

random_hex() {
  local bytes="$1"
  openssl rand -hex "${bytes}"
}

public_ipv4() {
  curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true
}

is_ipv4() {
  local value="$1"
  [[ "${value}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

subject_alt_name_for_host() {
  local host="$1"
  if is_ipv4 "${host}"; then
    printf 'IP:%s\n' "${host}"
  else
    printf 'DNS:%s\n' "${host}"
  fi
}

urlencode() {
  local raw="$1"
  local encoded=""
  local i char hex
  local old_lc_all="${LC_ALL:-}"
  export LC_ALL=C
  for ((i = 0; i < ${#raw}; i++)); do
    char="${raw:i:1}"
    case "${char}" in
      [a-zA-Z0-9.~_-]) encoded+="${char}" ;;
      *) printf -v hex '%%%02X' "'${char}"; encoded+="${hex}" ;;
    esac
  done
  if [ -n "${old_lc_all}" ]; then
    export LC_ALL="${old_lc_all}"
  else
    unset LC_ALL
  fi
  printf '%s\n' "${encoded}"
}

install_base_packages() {
  if ! command -v apt-get >/dev/null 2>&1; then
    die "第一版只支持 Debian/Ubuntu 系统"
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl openssl ca-certificates iproute2 dnsutils
}

hysteria_asset_name() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) printf 'hysteria-linux-amd64\n' ;;
    aarch64|arm64) printf 'hysteria-linux-arm64\n' ;;
    armv7l|armv6l) printf 'hysteria-linux-arm\n' ;;
    *) die "暂不支持当前架构：${arch}" ;;
  esac
}

install_hysteria_binary() {
  local asset
  local url
  asset="$(hysteria_asset_name)"
  url="https://download.hysteria.network/app/latest/${asset}"

  blue "下载 Hysteria2：${url}"
  curl -fL --retry 3 --connect-timeout 20 -o "/tmp/${asset}" "${url}"
  install -m 0755 "/tmp/${asset}" "${HYSTERIA_BIN}"
}

port_is_used() {
  local port="$1"
  ss -H -lntup 2>/dev/null | awk -v port="${port}" '
    {
      local_addr = $5
      if (local_addr ~ ":" port "$") {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  '
}

show_port_usage() {
  local port="$1"
  yellow "端口 ${port} 已被占用："
  ss -lntup 2>/dev/null | awk -v port="${port}" '
    NR == 1 || $0 ~ ":" port "([^0-9]|$)" { print }
  '
}

ensure_port_available() {
  local -n port_ref="$1"
  local choice
  local service_name

  while port_is_used "${port_ref}"; do
    show_port_usage "${port_ref}"
    cat <<EOF

请选择处理方式：
  1) 换一个端口
  2) 我确认要停用占用端口的 systemd 服务
  3) 退出
EOF
    printf '选择 [1]: ' >&2
    read -r choice
    choice="${choice:-1}"
    case "${choice}" in
      1)
        port_ref="$(prompt_port '请输入新的端口' "${port_ref}")"
        ;;
      2)
        printf '请输入要停用的服务名，例如 nginx 或 caddy: ' >&2
        read -r service_name
        if [ -z "${service_name}" ]; then
          yellow "未输入服务名，返回端口处理菜单"
          continue
        fi
        systemctl disable --now "${service_name}" || die "停用 ${service_name} 失败"
        ;;
      3)
        die "端口被占用，已退出"
        ;;
      *)
        yellow "无效选择"
        ;;
    esac
  done
}

render_hy2_config() {
  local port="$1"
  local cert_file="$2"
  local key_file="$3"
  local auth_password="$4"
  local obfs_password="$5"
  local masquerade_url="$6"

  cat <<EOF
listen: :${port}

tls:
  cert: ${cert_file}
  key: ${key_file}

auth:
  type: password
  password: ${auth_password}

obfs:
  type: salamander
  salamander:
    password: ${obfs_password}

masquerade:
  type: proxy
  proxy:
    url: ${masquerade_url}
    rewriteHost: true
EOF
}

write_hy2_service() {
  cat > "${HY2_SERVICE_FILE}" <<EOF
[Unit]
Description=Hysteria2 Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${HYSTERIA_BIN} server -c ${HY2_CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

create_self_signed_cert() {
  local host="$1"
  local san
  san="$(subject_alt_name_for_host "${host}")"

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${HY2_KEY_FILE}" \
    -out "${HY2_CERT_FILE}" \
    -subj "/CN=${host}" \
    -addext "subjectAltName=${san}" \
    -days 3650 >/dev/null 2>&1

  chmod 600 "${HY2_KEY_FILE}"
  chmod 644 "${HY2_CERT_FILE}"
}

build_hy2_uri() {
  local host="$1"
  local port="$2"
  local auth_password="$3"
  local obfs_password="$4"
  local sni="$5"
  local pin_sha256="$6"
  local encoded_auth
  local encoded_obfs
  local encoded_sni
  local uri_host
  local query

  encoded_auth="$(urlencode "${auth_password}")"
  encoded_obfs="$(urlencode "${obfs_password}")"
  encoded_sni="$(urlencode "${sni}")"
  uri_host="${host}"
  if [[ "${host}" == *:* && "${host}" != \[*\] ]]; then
    uri_host="[${host}]"
  fi

  query="insecure=1&obfs=salamander&obfs-password=${encoded_obfs}&sni=${encoded_sni}"
  if [ -n "${pin_sha256}" ]; then
    query="insecure=1&pinSHA256=${pin_sha256}&obfs=salamander&obfs-password=${encoded_obfs}&sni=${encoded_sni}"
  fi

  printf 'hysteria2://%s@%s:%s/?%s#HY2-%s\n' "${encoded_auth}" "${uri_host}" "${port}" "${query}" "${host}"
}

hy2_install() {
  local detected_ip
  local server_host
  local port
  local masquerade_url
  local auth_password
  local obfs_password
  local pin_sha256
  local normal_uri
  local pinned_uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port="$(prompt_port '请输入 HY2 UDP 端口，必须在 NAT 面板转发 UDP' '63272')"
  ensure_port_available port
  masquerade_url="$(prompt_value '请输入伪装站点 URL' 'https://www.bing.com/')"
  auth_password="$(prompt_value '请输入 HY2 认证密码，留空使用随机值' "$(random_hex 16)")"
  obfs_password="$(prompt_value '请输入 salamander 混淆密码，留空使用随机值' "$(random_hex 16)")"

  yellow "请确认 NAT 面板已转发 UDP ${port} 到本机。HY2 不走 TCP，只有 TCP 转发会连不上。"
  if ! prompt_yes_no '确认继续安装 HY2' 'y'; then
    die "用户取消"
  fi

  mkdir -p "${HY2_CONFIG_DIR}"
  chmod 700 "${HY2_CONFIG_DIR}"

  install_hysteria_binary
  create_self_signed_cert "${server_host}"

  if [ -f "${HY2_CONFIG_FILE}" ]; then
    cp -a "${HY2_CONFIG_FILE}" "${HY2_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  render_hy2_config "${port}" "${HY2_CERT_FILE}" "${HY2_KEY_FILE}" "${auth_password}" "${obfs_password}" "${masquerade_url}" > "${HY2_CONFIG_FILE}"
  chmod 600 "${HY2_CONFIG_FILE}"

  cat > "${HY2_ENV_FILE}" <<EOF
HY2_HOST=${server_host}
HY2_PORT=${port}
HY2_AUTH=${auth_password}
HY2_OBFS=${obfs_password}
HY2_MASQUERADE=${masquerade_url}
EOF
  chmod 600 "${HY2_ENV_FILE}"

  write_hy2_service
  systemctl daemon-reload
  systemctl enable --now hysteria-server
  systemctl restart hysteria-server

  pin_sha256="$(openssl x509 -in "${HY2_CERT_FILE}" -noout -fingerprint -sha256 | sed 's/^.*=//' | tr -d ':')"
  normal_uri="$(build_hy2_uri "${server_host}" "${port}" "${auth_password}" "${obfs_password}" "${server_host}" '')"
  pinned_uri="$(build_hy2_uri "${server_host}" "${port}" "${auth_password}" "${obfs_password}" "${server_host}" "${pin_sha256}")"

  echo
  green "HY2 安装完成"
  echo "服务状态：$(systemctl is-active hysteria-server || true)"
  echo
  echo "监听检查："
  ss -lunp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${normal_uri}"
  echo
  echo "带 pinSHA256 的链接："
  echo "${pinned_uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否转发 UDP ${port}，不是 TCP。"
}

tls_txt_record_name() {
  local domain="$1"
  printf '_acme-challenge.%s\n' "${domain}"
}

txt_record_values() {
  local record="$1"
  dig +short TXT "${record}" 2>/dev/null | sed 's/^"//; s/"$//; s/" "//g'
}

wait_for_txt_record() {
  local domain="$1"
  local expected_value="$2"
  local record
  local current
  record="$(tls_txt_record_name "${domain}")"

  blue "请添加 TXT 记录："
  echo "记录名：${record}"
  echo "记录值：${expected_value}"
  echo

  while true; do
    current="$(txt_record_values "${record}")"
    if printf '%s\n' "${current}" | grep -Fxq "${expected_value}"; then
      green "TXT 验证通过：${record}"
      return 0
    fi

    yellow "还没检测到目标 TXT。当前值："
    if [ -n "${current}" ]; then
      printf '%s\n' "${current}"
    else
      echo "(无)"
    fi

    if ! prompt_yes_no '等待 15 秒后重试' 'y'; then
      return 1
    fi
    sleep 15
  done
}

txt_check_tool() {
  local domain
  local expected

  require_linux
  if ! command -v dig >/dev/null 2>&1; then
    require_root
    install_base_packages
  fi

  domain="$(prompt_value '请输入要验证 TLS DNS-01 的域名' 'example.com')"
  expected="$(prompt_value '请输入期望的 TXT 值' 'token-value')"
  wait_for_txt_record "${domain}" "${expected}"
}

coming_soon() {
  local name="$1"
  yellow "${name} 正在规划中。第一版先提供 HY2 和 TLS TXT 检测工具。"
}

show_menu() {
  cat <<EOF

请选择要安装或配置的协议：
  1) Hysteria2 (HY2) - 推荐 NAT 机优先使用，UDP
  2) Reality - 规划中
  3) VLESS WS TLS - 规划中，TLS 将使用 TXT 检测
  4) Trojan TLS - 规划中，TLS 将使用 TXT 检测
  5) TLS TXT 检测工具
  0) 退出
EOF
}

main() {
  local choice
  banner
  while true; do
    show_menu
    printf '请输入选项 [1]: ' >&2
    read -r choice
    choice="${choice:-1}"
    case "${choice}" in
      1) hy2_install ;;
      2) coming_soon 'Reality' ;;
      3) coming_soon 'VLESS WS TLS' ;;
      4) coming_soon 'Trojan TLS' ;;
      5) txt_check_tool ;;
      0) exit 0 ;;
      *) yellow "无效选项" ;;
    esac
  done
}

if [ "${NAT_V2RAY_LIB_ONLY:-0}" != "1" ]; then
  main "$@"
fi
