#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.12.0"
PROJECT_NAME="nat-v2ray"
HYSTERIA_BIN="/usr/local/bin/hysteria"
HY2_CONFIG_DIR="/etc/hysteria"
HY2_CONFIG_FILE="${HY2_CONFIG_DIR}/config.yaml"
HY2_ENV_FILE="${HY2_CONFIG_DIR}/nat-v2ray-hy2.env"
HY2_CERT_FILE="${HY2_CONFIG_DIR}/server.crt"
HY2_KEY_FILE="${HY2_CONFIG_DIR}/server.key"
HY2_SERVICE_FILE="/etc/systemd/system/hysteria-server.service"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
XRAY_ENV_FILE="${XRAY_CONFIG_DIR}/nat-v2ray.env"
XRAY_SERVICE_FILE="/etc/systemd/system/xray.service"
CERT_BASE_DIR="/etc/nat-v2ray/certs"
ACME_SH="${HOME}/.acme.sh/acme.sh"

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

validate_port_range() {
  local port_range="$1"
  local start_port
  local end_port
  if ! [[ "${port_range}" =~ ^[0-9]+-[0-9]+$ ]]; then
    return 1
  fi
  start_port="${port_range%-*}"
  end_port="${port_range#*-}"
  validate_port "${start_port}" && validate_port "${end_port}" && [ "${start_port}" -le "${end_port}" ]
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

prompt_port_range() {
  local message="$1"
  local default_range="$2"
  local port_range
  while true; do
    port_range="$(prompt_value "${message}" "${default_range}")"
    if validate_port_range "${port_range}"; then
      printf '%s\n' "${port_range}"
      return 0
    fi
    yellow "端口范围必须形如 20000-20010，且起始端口不能大于结束端口" >&2
  done
}

validate_kcp_header_type() {
  local header_type="$1"
  header_type="$(printf '%s' "${header_type}" | tr '[:upper:]' '[:lower:]')"
  case "${header_type}" in
    none|dns|dtls|srtp|utp|wechat|wireguard) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_kcp_header_type() {
  local message="$1"
  local default_type="$2"
  local header_type
  while true; do
    header_type="$(prompt_value "${message}" "${default_type}")"
    header_type="$(printf '%s' "${header_type}" | tr '[:upper:]' '[:lower:]')"
    if validate_kcp_header_type "${header_type}"; then
      printf '%s\n' "${header_type}"
      return 0
    fi
    yellow "mKCP header type 只能是 none、dns、dtls、srtp、utp、wechat、wireguard" >&2
  done
}

normalise_kcp_header_type() {
  local header_type="$1"
  header_type="$(printf '%s' "${header_type}" | tr '[:upper:]' '[:lower:]')"
  if [ "${header_type}" = "none" ]; then
    printf '\n'
  else
    printf '%s\n' "${header_type}"
  fi
}

render_kcp_finalmask_udp() {
  local header_type="$1"
  local seed="$2"
  local finalmask_header
  finalmask_header="$(normalise_kcp_header_type "${header_type}")"

  if [ -n "${finalmask_header}" ]; then
    cat <<EOF
            {
              "type": "header-${finalmask_header}",
              "settings": {}
            },
EOF
  fi

  if [ -n "${seed}" ]; then
    cat <<EOF
            {
              "type": "mkcp-aes128gcm",
              "settings": {
                "password": "${seed}"
              }
            }
EOF
  else
    cat <<EOF
            {
              "type": "mkcp-original",
              "settings": {}
            }
EOF
  fi
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

base64_no_wrap() {
  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w 0
  else
    base64 | tr -d '\n'
  fi
}

install_base_packages() {
  if ! command -v apt-get >/dev/null 2>&1; then
    die "第一版只支持 Debian/Ubuntu 系统"
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl openssl ca-certificates iproute2 dnsutils unzip
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

xray_asset_name() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) printf 'Xray-linux-64.zip\n' ;;
    aarch64|arm64) printf 'Xray-linux-arm64-v8a.zip\n' ;;
    armv7l) printf 'Xray-linux-arm32-v7a.zip\n' ;;
    *) die "暂不支持当前架构：${arch}" ;;
  esac
}

install_xray_binary() {
  local asset
  local url
  local work_dir
  asset="$(xray_asset_name)"
  url="https://github.com/XTLS/Xray-core/releases/latest/download/${asset}"
  work_dir="/tmp/nat-v2ray-xray"

  blue "下载 Xray：${url}"
  rm -rf "${work_dir}"
  mkdir -p "${work_dir}"
  curl -fL --retry 3 --connect-timeout 20 -o "/tmp/${asset}" "${url}"
  unzip -oq "/tmp/${asset}" -d "${work_dir}"
  install -m 0755 "${work_dir}/xray" "${XRAY_BIN}"
  if [ -f "${work_dir}/geoip.dat" ]; then
    install -m 0644 "${work_dir}/geoip.dat" "/usr/local/share/xray/geoip.dat" 2>/dev/null || true
  fi
  if [ -f "${work_dir}/geosite.dat" ]; then
    install -m 0644 "${work_dir}/geosite.dat" "/usr/local/share/xray/geosite.dat" 2>/dev/null || true
  fi
}

write_xray_service() {
  mkdir -p "${XRAY_CONFIG_DIR}"
  cat > "${XRAY_SERVICE_FILE}" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

random_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    "${XRAY_BIN}" uuid
  fi
}

generate_reality_keys() {
  local output
  local private_key
  local public_key
  output="$("${XRAY_BIN}" x25519)"
  private_key="$(printf '%s\n' "${output}" | awk -F': ' '/Private key:/ {print $2} /PrivateKey:/ {print $2}' | tail -1)"
  public_key="$(printf '%s\n' "${output}" | awk -F': ' '/Public key:/ {print $2} /Password \(PublicKey\):/ {print $2}' | tail -1)"
  if [ -z "${private_key}" ] || [ -z "${public_key}" ]; then
    die "生成 Reality 密钥失败：${output}"
  fi
  printf '%s %s\n' "${private_key}" "${public_key}"
}

render_reality_config() {
  local port="$1"
  local uuid="$2"
  local private_key="$3"
  local short_id="$4"
  local server_name="$5"
  local dest="$6"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${dest}",
          "xver": 0,
          "serverNames": [
            "${server_name}"
          ],
          "privateKey": "${private_key}",
          "shortIds": [
            "${short_id}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ]
}
EOF
}

build_reality_uri() {
  local host="$1"
  local port="$2"
  local uuid="$3"
  local server_name="$4"
  local public_key="$5"
  local short_id="$6"
  local encoded_server_name
  local encoded_public_key
  local encoded_short_id
  encoded_server_name="$(urlencode "${server_name}")"
  encoded_public_key="$(urlencode "${public_key}")"
  encoded_short_id="$(urlencode "${short_id}")"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#Reality-%s\n' \
    "${uuid}" "${host}" "${port}" "${encoded_server_name}" "${encoded_public_key}" "${encoded_short_id}" "${host}"
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
        printf '请输入要停用的 systemd 服务名，留空返回: ' >&2
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

reality_install() {
  local detected_ip
  local server_host
  local port
  local uuid
  local server_name
  local dest
  local short_id
  local keys
  local private_key
  local public_key
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port="$(prompt_port '请输入 Reality TCP 端口，必须在 NAT 面板转发 TCP' '443')"
  ensure_port_available port
  server_name="$(prompt_value '请输入 Reality 伪装 SNI' 'www.cloudflare.com')"
  dest="$(prompt_value '请输入 Reality 伪装目标 host:port' "${server_name}:443")"
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"
  short_id="$(prompt_value '请输入 Reality shortId，留空使用随机值' "$(random_hex 4)")"

  yellow "请确认 NAT 面板已转发 TCP ${port} 到本机。Reality 不需要申请 TLS 证书。"
  if ! prompt_yes_no '确认继续安装 Reality' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  keys="$(generate_reality_keys)"
  private_key="${keys%% *}"
  public_key="${keys##* }"

  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_reality_config "${port}" "${uuid}" "${private_key}" "${short_id}" "${server_name}" "${dest}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=reality
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
REALITY_SNI=${server_name}
REALITY_DEST=${dest}
REALITY_PRIVATE_KEY=${private_key}
REALITY_PUBLIC_KEY=${public_key}
REALITY_SHORT_ID=${short_id}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_reality_uri "${server_host}" "${port}" "${uuid}" "${server_name}" "${public_key}" "${short_id}")"

  echo
  green "Reality 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lntp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
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

install_acme_sh() {
  if [ -x "${ACME_SH}" ]; then
    return 0
  fi

  blue "安装 acme.sh"
  curl -fsSL https://get.acme.sh | sh -s email="$(prompt_value '请输入证书通知邮箱' 'admin@example.com')"
  if [ ! -x "${ACME_SH}" ]; then
    die "acme.sh 安装失败"
  fi
  "${ACME_SH}" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
}

cert_dir_for_domain() {
  local domain="$1"
  printf '%s/%s\n' "${CERT_BASE_DIR}" "${domain}"
}

extract_acme_txt_value() {
  sed -n \
    -e "s/.*TXT value:[[:space:]]*'\\([^']*\\)'.*/\\1/p" \
    -e 's/.*TXT value:[[:space:]]*"\([^"]*\)".*/\1/p' \
    -e 's/.*TXT value:[[:space:]]*\([^[:space:]]*\).*/\1/p' | tail -1
}

request_tls_cert_manual_dns() {
  local domain="$1"
  local cert_dir
  local key_file
  local fullchain_file
  local issue_output
  local renew_output
  local txt_value
  local rc

  require_root
  install_base_packages
  install_acme_sh

  cert_dir="$(cert_dir_for_domain "${domain}")"
  key_file="${cert_dir}/private.key"
  fullchain_file="${cert_dir}/fullchain.cer"
  mkdir -p "${cert_dir}"
  chmod 700 "${cert_dir}"

  if [ -s "${key_file}" ] && [ -s "${fullchain_file}" ]; then
    if prompt_yes_no "检测到 ${domain} 已有证书，是否直接复用" 'y'; then
      printf '%s %s\n' "${fullchain_file}" "${key_file}"
      return 0
    fi
  fi

  set +e
  issue_output="$("${ACME_SH}" --issue --dns -d "${domain}" --yes-I-know-dns-manual-mode-enough-go-ahead-please 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "${issue_output}"

  txt_value="$(printf '%s\n' "${issue_output}" | extract_acme_txt_value)"
  if [ -z "${txt_value}" ]; then
    yellow "未能自动解析 acme.sh 输出里的 TXT 值。"
    txt_value="$(prompt_value '请手动粘贴 acme.sh 要求的 TXT 值' '')"
  fi
  if [ -z "${txt_value}" ]; then
    die "没有 TXT 值，无法继续申请证书"
  fi

  wait_for_txt_record "${domain}" "${txt_value}" || die "TXT 验证未通过"

  set +e
  renew_output="$("${ACME_SH}" --renew -d "${domain}" --yes-I-know-dns-manual-mode-enough-go-ahead-please --force 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "${renew_output}"
  if [ "${rc}" -ne 0 ]; then
    die "证书签发失败，请检查 DNS TXT 是否已生效"
  fi

  "${ACME_SH}" --install-cert -d "${domain}" \
    --key-file "${key_file}" \
    --fullchain-file "${fullchain_file}" \
    --reloadcmd "systemctl restart xray >/dev/null 2>&1 || true"

  chmod 600 "${key_file}"
  chmod 644 "${fullchain_file}"
  printf '%s %s\n' "${fullchain_file}" "${key_file}"
}

render_vless_tcp_tls_config() {
  local port="$1"
  local uuid="$2"
  local cert_file="$3"
  local key_file="$4"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-tcp-tls",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${cert_file}",
              "keyFile": "${key_file}"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vless_ws_tls_config() {
  local port="$1"
  local uuid="$2"
  local ws_path="$3"
  local cert_file="$4"
  local key_file="$5"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-ws-tls",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${cert_file}",
              "keyFile": "${key_file}"
            }
          ]
        },
        "wsSettings": {
          "path": "${ws_path}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_trojan_tls_config() {
  local port="$1"
  local password="$2"
  local cert_file="$3"
  local key_file="$4"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "trojan-tls",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${password}"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${cert_file}",
              "keyFile": "${key_file}"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

build_vless_tcp_tls_uri() {
  local host="$1"
  local port="$2"
  local uuid="$3"
  local domain="$4"
  local encoded_domain
  encoded_domain="$(urlencode "${domain}")"
  printf 'vless://%s@%s:%s?encryption=none&security=tls&type=tcp&sni=%s#VLESS-TCP-TLS-%s\n' \
    "${uuid}" "${host}" "${port}" "${encoded_domain}" "${host}"
}

build_vless_ws_tls_uri() {
  local host="$1"
  local port="$2"
  local uuid="$3"
  local domain="$4"
  local ws_path="$5"
  local encoded_domain
  local encoded_path
  encoded_domain="$(urlencode "${domain}")"
  encoded_path="$(urlencode "${ws_path}")"
  printf 'vless://%s@%s:%s?encryption=none&security=tls&type=ws&host=%s&sni=%s&path=%s#VLESS-WS-TLS-%s\n' \
    "${uuid}" "${host}" "${port}" "${encoded_domain}" "${encoded_domain}" "${encoded_path}" "${host}"
}

build_vless_grpc_uri() {
  local host="$1"
  local port="$2"
  local uuid="$3"
  local service_name="$4"
  local encoded_service_name
  encoded_service_name="$(urlencode "${service_name}")"
  printf 'vless://%s@%s:%s?encryption=none&security=none&type=grpc&serviceName=%s&mode=gun#VLESS-gRPC-%s\n' \
    "${uuid}" "${host}" "${port}" "${encoded_service_name}" "${host}"
}

build_vless_xhttp_uri() {
  local host="$1"
  local port="$2"
  local uuid="$3"
  local xhttp_path="$4"
  local xhttp_mode="$5"
  local encoded_path
  local encoded_mode
  encoded_path="$(urlencode "${xhttp_path}")"
  encoded_mode="$(urlencode "${xhttp_mode}")"
  printf 'vless://%s@%s:%s?encryption=none&security=none&type=xhttp&path=%s&mode=%s#VLESS-XHTTP-%s\n' \
    "${uuid}" "${host}" "${port}" "${encoded_path}" "${encoded_mode}" "${host}"
}

build_trojan_tls_uri() {
  local host="$1"
  local port="$2"
  local password="$3"
  local domain="$4"
  local encoded_password
  local encoded_domain
  encoded_password="$(urlencode "${password}")"
  encoded_domain="$(urlencode "${domain}")"
  printf 'trojan://%s@%s:%s?security=tls&type=tcp&sni=%s#Trojan-TLS-%s\n' \
    "${encoded_password}" "${host}" "${port}" "${encoded_domain}" "${host}"
}

build_vless_grpc_tls_uri() {
  local host="$1"
  local port="$2"
  local uuid="$3"
  local domain="$4"
  local service_name="$5"
  local encoded_domain
  local encoded_service_name
  encoded_domain="$(urlencode "${domain}")"
  encoded_service_name="$(urlencode "${service_name}")"
  printf 'vless://%s@%s:%s?encryption=none&security=tls&type=grpc&serviceName=%s&mode=gun&sni=%s#VLESS-gRPC-TLS-%s\n' \
    "${uuid}" "${host}" "${port}" "${encoded_service_name}" "${encoded_domain}" "${host}"
}

build_trojan_ws_tls_uri() {
  local host="$1"
  local port="$2"
  local password="$3"
  local domain="$4"
  local ws_path="$5"
  local encoded_password
  local encoded_domain
  local encoded_path
  encoded_password="$(urlencode "${password}")"
  encoded_domain="$(urlencode "${domain}")"
  encoded_path="$(urlencode "${ws_path}")"
  printf 'trojan://%s@%s:%s?security=tls&type=ws&host=%s&sni=%s&path=%s#Trojan-WS-TLS-%s\n' \
    "${encoded_password}" "${host}" "${port}" "${encoded_domain}" "${encoded_domain}" "${encoded_path}" "${host}"
}

build_trojan_grpc_tls_uri() {
  local host="$1"
  local port="$2"
  local password="$3"
  local domain="$4"
  local service_name="$5"
  local encoded_password
  local encoded_domain
  local encoded_service_name
  encoded_password="$(urlencode "${password}")"
  encoded_domain="$(urlencode "${domain}")"
  encoded_service_name="$(urlencode "${service_name}")"
  printf 'trojan://%s@%s:%s?security=tls&type=grpc&serviceName=%s&mode=gun&sni=%s#Trojan-gRPC-TLS-%s\n' \
    "${encoded_password}" "${host}" "${port}" "${encoded_service_name}" "${encoded_domain}" "${host}"
}

render_vmess_tcp_tls_config() {
  local port="$1"
  local uuid="$2"
  local cert_file="$3"
  local key_file="$4"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vmess-tcp-tls",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${cert_file}",
              "keyFile": "${key_file}"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

build_vmess_tcp_tls_link() {
  local name="$1"
  local host="$2"
  local port="$3"
  local uuid="$4"
  local domain="$5"
  local json

  json="{\"v\":\"2\",\"ps\":\"${name}\",\"add\":\"${host}\",\"port\":\"${port}\",\"id\":\"${uuid}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"${domain}\",\"path\":\"\",\"tls\":\"tls\",\"sni\":\"${domain}\"}"
  printf 'vmess://%s\n' "$(printf '%s' "${json}" | base64_no_wrap)"
}

render_vmess_ws_tls_config() {
  local port="$1"
  local uuid="$2"
  local ws_path="$3"
  local cert_file="$4"
  local key_file="$5"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vmess-ws-tls",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${cert_file}",
              "keyFile": "${key_file}"
            }
          ]
        },
        "wsSettings": {
          "path": "${ws_path}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vmess_grpc_tls_config() {
  local port="$1"
  local uuid="$2"
  local service_name="$3"
  local cert_file="$4"
  local key_file="$5"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vmess-grpc-tls",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "grpc",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${cert_file}",
              "keyFile": "${key_file}"
            }
          ]
        },
        "grpcSettings": {
          "serviceName": "${service_name}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vless_grpc_tls_config() {
  local port="$1"
  local uuid="$2"
  local service_name="$3"
  local cert_file="$4"
  local key_file="$5"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-grpc-tls",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${cert_file}",
              "keyFile": "${key_file}"
            }
          ]
        },
        "grpcSettings": {
          "serviceName": "${service_name}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_trojan_ws_tls_config() {
  local port="$1"
  local password="$2"
  local ws_path="$3"
  local cert_file="$4"
  local key_file="$5"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "trojan-ws-tls",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${password}"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${cert_file}",
              "keyFile": "${key_file}"
            }
          ]
        },
        "wsSettings": {
          "path": "${ws_path}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_trojan_grpc_tls_config() {
  local port="$1"
  local password="$2"
  local service_name="$3"
  local cert_file="$4"
  local key_file="$5"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "trojan-grpc-tls",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${password}"
          }
        ]
      },
      "streamSettings": {
        "network": "grpc",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${cert_file}",
              "keyFile": "${key_file}"
            }
          ]
        },
        "grpcSettings": {
          "serviceName": "${service_name}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vless_tcp_config() {
  local port="$1"
  local uuid="$2"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-tcp",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vless_ws_config() {
  local port="$1"
  local uuid="$2"
  local ws_path="$3"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-ws",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${ws_path}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vless_httpupgrade_config() {
  local port="$1"
  local uuid="$2"
  local http_path="$3"
  local host_header="$4"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-httpupgrade",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "httpupgrade",
        "security": "none",
        "httpupgradeSettings": {
          "path": "${http_path}",
          "host": "${host_header}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vless_grpc_config() {
  local port="$1"
  local uuid="$2"
  local service_name="$3"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-grpc",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": {
          "serviceName": "${service_name}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vless_xhttp_config() {
  local port="$1"
  local uuid="$2"
  local xhttp_path="$3"
  local xhttp_mode="$4"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-xhttp",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "${xhttp_path}",
          "mode": "${xhttp_mode}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vless_tcp_dynamic_config() {
  local port_range="$1"
  local uuid="$2"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-tcp-dynamic",
      "listen": "0.0.0.0",
      "port": "${port_range}",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      },
      "allocate": {
        "strategy": "random",
        "refresh": 5,
        "concurrency": 3
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vless_ws_dynamic_config() {
  local port_range="$1"
  local uuid="$2"
  local ws_path="$3"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-ws-dynamic",
      "listen": "0.0.0.0",
      "port": "${port_range}",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${ws_path}"
        }
      },
      "allocate": {
        "strategy": "random",
        "refresh": 5,
        "concurrency": 3
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

build_vless_uri() {
  local name="$1"
  local host="$2"
  local port="$3"
  local uuid="$4"
  local network="$5"
  local path="${6:-}"
  local host_header="${7:-}"
  local tls="${8:-none}"
  local seed="${9:-}"
  local header_type="${10:-none}"
  local encoded_name
  local encoded_path
  local encoded_host
  local encoded_seed
  local extra=""

  encoded_name="$(urlencode "${name}")"
  encoded_path="$(urlencode "${path}")"
  encoded_host="$(urlencode "${host_header}")"
  encoded_seed="$(urlencode "${seed}")"

  if [ "${network}" = "ws" ] || [ "${network}" = "httpupgrade" ]; then
    extra="$(printf '&host=%s&path=%s' "${encoded_host}" "${encoded_path}")"
  fi
  if [ "${network}" = "kcp" ]; then
    extra="$(printf '&headerType=%s&seed=%s' "${header_type}" "${encoded_seed}")"
  fi

  printf 'vless://%s@%s:%s?encryption=none&security=%s&type=%s%s#%s\n' \
    "${uuid}" "${host}" "${port}" "${tls}" "${network}" "${extra}" "${encoded_name}"
}

render_vless_mkcp_config() {
  local port="$1"
  local uuid="$2"
  local header_type="$3"
  local seed="$4"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-mkcp",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "kcp",
        "security": "none",
        "kcpSettings": {
          "mtu": 1350,
          "tti": 50,
          "uplinkCapacity": 5,
          "downlinkCapacity": 20
        },
        "finalmask": {
          "udp": [
$(render_kcp_finalmask_udp "${header_type}" "${seed}")
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vless_mkcp_dynamic_config() {
  local port_range="$1"
  local uuid="$2"
  local header_type="$3"
  local seed="$4"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-mkcp-dynamic",
      "listen": "0.0.0.0",
      "port": "${port_range}",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "kcp",
        "security": "none",
        "kcpSettings": {
          "mtu": 1350,
          "tti": 50,
          "uplinkCapacity": 5,
          "downlinkCapacity": 20
        },
        "finalmask": {
          "udp": [
$(render_kcp_finalmask_udp "${header_type}" "${seed}")
          ]
        }
      },
      "allocate": {
        "strategy": "random",
        "refresh": 5,
        "concurrency": 3
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vmess_tcp_config() {
  local port="$1"
  local uuid="$2"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vmess-tcp",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vmess_ws_config() {
  local port="$1"
  local uuid="$2"
  local ws_path="$3"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vmess-ws",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${ws_path}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vmess_httpupgrade_config() {
  local port="$1"
  local uuid="$2"
  local http_path="$3"
  local host_header="$4"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vmess-httpupgrade",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "httpupgrade",
        "security": "none",
        "httpupgradeSettings": {
          "path": "${http_path}",
          "host": "${host_header}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vmess_grpc_config() {
  local port="$1"
  local uuid="$2"
  local service_name="$3"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vmess-grpc",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "grpc",
        "security": "none",
        "grpcSettings": {
          "serviceName": "${service_name}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vmess_xhttp_config() {
  local port="$1"
  local uuid="$2"
  local xhttp_path="$3"
  local xhttp_mode="$4"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vmess-xhttp",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "${xhttp_path}",
          "mode": "${xhttp_mode}"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vmess_tcp_dynamic_config() {
  local port_range="$1"
  local uuid="$2"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vmess-tcp-dynamic",
      "listen": "0.0.0.0",
      "port": "${port_range}",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      },
      "allocate": {
        "strategy": "random",
        "refresh": 5,
        "concurrency": 3
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vmess_ws_dynamic_config() {
  local port_range="$1"
  local uuid="$2"
  local ws_path="$3"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vmess-ws-dynamic",
      "listen": "0.0.0.0",
      "port": "${port_range}",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${ws_path}"
        }
      },
      "allocate": {
        "strategy": "random",
        "refresh": 5,
        "concurrency": 3
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

build_vmess_link() {
  local name="$1"
  local host="$2"
  local port="$3"
  local uuid="$4"
  local network="$5"
  local ws_path="$6"
  local host_header="$7"
  local tls="${8:-}"
  local type="none"
  local link_host="${host_header}"
  local json

  if [ "${network}" = "grpc" ]; then
    type="gun"
  fi
  if [ "${network}" = "xhttp" ]; then
    type="${host_header:-auto}"
    link_host=""
  fi
  if [ "${network}" = "kcp" ]; then
    type="${host_header:-none}"
    link_host=""
  fi

  if [ "${network}" = "ws" ] || [ "${network}" = "grpc" ] || [ "${network}" = "kcp" ] || [ "${network}" = "httpupgrade" ] || [ "${network}" = "xhttp" ]; then
    json="{\"v\":\"2\",\"ps\":\"${name}\",\"add\":\"${host}\",\"port\":\"${port}\",\"id\":\"${uuid}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"${network}\",\"type\":\"${type}\",\"host\":\"${link_host}\",\"path\":\"${ws_path}\",\"tls\":\"${tls}\"}"
  else
    json="{\"v\":\"2\",\"ps\":\"${name}\",\"add\":\"${host}\",\"port\":\"${port}\",\"id\":\"${uuid}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"tcp\",\"type\":\"none\",\"host\":\"\",\"path\":\"\",\"tls\":\"\"}"
  fi

  printf 'vmess://%s\n' "$(printf '%s' "${json}" | base64_no_wrap)"
}

render_vmess_mkcp_config() {
  local port="$1"
  local uuid="$2"
  local header_type="$3"
  local seed="$4"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vmess-mkcp",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "kcp",
        "security": "none",
        "kcpSettings": {
          "mtu": 1350,
          "tti": 50,
          "uplinkCapacity": 5,
          "downlinkCapacity": 20
        },
        "finalmask": {
          "udp": [
$(render_kcp_finalmask_udp "${header_type}" "${seed}")
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_vmess_mkcp_dynamic_config() {
  local port_range="$1"
  local uuid="$2"
  local header_type="$3"
  local seed="$4"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vmess-mkcp-dynamic",
      "listen": "0.0.0.0",
      "port": "${port_range}",
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "kcp",
        "security": "none",
        "kcpSettings": {
          "mtu": 1350,
          "tti": 50,
          "uplinkCapacity": 5,
          "downlinkCapacity": 20
        },
        "finalmask": {
          "udp": [
$(render_kcp_finalmask_udp "${header_type}" "${seed}")
          ]
        }
      },
      "allocate": {
        "strategy": "random",
        "refresh": 5,
        "concurrency": 3
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

render_shadowsocks_config() {
  local port="$1"
  local method="$2"
  local password="$3"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "shadowsocks",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "shadowsocks",
      "settings": {
        "method": "${method}",
        "password": "${password}",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
}

build_shadowsocks_uri() {
  local host="$1"
  local port="$2"
  local method="$3"
  local password="$4"
  local encoded_userinfo
  local encoded_name

  encoded_userinfo="$(printf '%s' "${method}:${password}" | base64_no_wrap | tr '+/' '-_' | tr -d '=')"
  encoded_name="$(urlencode "SS-${host}")"
  printf 'ss://%s@%s:%s#%s\n' "${encoded_userinfo}" "${host}" "${port}" "${encoded_name}"
}

normalize_ws_path() {
  local path="$1"
  if [[ "${path}" != /* ]]; then
    path="/${path}"
  fi
  printf '%s\n' "${path}"
}

vless_tcp_install() {
  local detected_ip
  local server_host
  local port
  local uuid
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port="$(prompt_port '请输入 VLESS TCP 端口，必须在 NAT 面板转发 TCP' '10090')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"

  yellow "VLESS TCP 不带 TLS，适合临时测试；公网长期使用建议优先 Reality/HY2/TLS。"
  if ! prompt_yes_no '确认继续安装 VLESS TCP' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vless_tcp_config "${port}" "${uuid}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vless-tcp
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_uri "VLESS-TCP-${server_host}" "${server_host}" "${port}" "${uuid}" 'tcp' '' '' 'none')"

  echo
  green "VLESS TCP 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lntp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
}

vless_ws_install() {
  local detected_ip
  local server_host
  local port
  local uuid
  local ws_path
  local host_header
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port="$(prompt_port '请输入 VLESS WS TCP 端口，必须在 NAT 面板转发 TCP' '10091')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"
  ws_path="$(normalize_ws_path "$(prompt_value '请输入 WebSocket 路径' "/$(random_hex 8)")")"
  host_header="$(prompt_value '请输入 WebSocket Host 伪装域名，留空使用连接地址' "${server_host}")"

  yellow "VLESS WS 当前不带 TLS；如需 TLS 请用 VLESS WS TLS。"
  if ! prompt_yes_no '确认继续安装 VLESS WS' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vless_ws_config "${port}" "${uuid}" "${ws_path}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vless-ws
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
WS_PATH=${ws_path}
WS_HOST=${host_header}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_uri "VLESS-WS-${server_host}" "${server_host}" "${port}" "${uuid}" 'ws' "${ws_path}" "${host_header}" 'none')"

  echo
  green "VLESS WS 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lntp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
}

vless_httpupgrade_install() {
  local detected_ip
  local server_host
  local port
  local uuid
  local http_path
  local host_header
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port="$(prompt_port '请输入 VLESS HTTPUpgrade TCP 端口，必须在 NAT 面板转发 TCP' '10093')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"
  http_path="$(normalize_ws_path "$(prompt_value '请输入 HTTPUpgrade 路径' "/$(random_hex 8)")")"
  host_header="$(prompt_value '请输入 HTTPUpgrade Host 伪装域名，留空使用连接地址' "${server_host}")"

  yellow "VLESS HTTPUpgrade 当前不带 TLS；如需证书保护，后续使用 TLS 类协议。"
  if ! prompt_yes_no '确认继续安装 VLESS HTTPUpgrade' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vless_httpupgrade_config "${port}" "${uuid}" "${http_path}" "${host_header}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vless-httpupgrade
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
HTTP_PATH=${http_path}
HTTP_HOST=${host_header}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_uri "VLESS-HTTPUpgrade-${server_host}" "${server_host}" "${port}" "${uuid}" 'httpupgrade' "${http_path}" "${host_header}" 'none')"

  echo
  green "VLESS HTTPUpgrade 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lntp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
}

vless_grpc_install() {
  local detected_ip
  local server_host
  local port
  local uuid
  local service_name
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port="$(prompt_port '请输入 VLESS gRPC TCP 端口，必须在 NAT 面板转发 TCP' '10095')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"
  service_name="$(prompt_value '请输入 gRPC serviceName' "$(random_hex 8)")"

  yellow "VLESS gRPC 当前不带 TLS；如需证书保护，请使用 VLESS gRPC TLS。"
  if ! prompt_yes_no '确认继续安装 VLESS gRPC' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vless_grpc_config "${port}" "${uuid}" "${service_name}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vless-grpc
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
GRPC_SERVICE_NAME=${service_name}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_grpc_uri "${server_host}" "${port}" "${uuid}" "${service_name}")"

  echo
  green "VLESS gRPC 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lntp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
}

vless_xhttp_install() {
  local detected_ip
  local server_host
  local port
  local uuid
  local xhttp_path
  local xhttp_mode
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port="$(prompt_port '请输入 VLESS XHTTP TCP 端口，必须在 NAT 面板转发 TCP' '10097')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"
  xhttp_path="$(normalize_ws_path "$(prompt_value '请输入 XHTTP 路径' "/$(random_hex 8)")")"
  xhttp_mode="$(prompt_value '请输入 XHTTP mode' 'auto')"

  yellow "VLESS XHTTP 当前不带 TLS；如需证书保护，后续可增加 XHTTP TLS。"
  if ! prompt_yes_no '确认继续安装 VLESS XHTTP' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vless_xhttp_config "${port}" "${uuid}" "${xhttp_path}" "${xhttp_mode}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vless-xhttp
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
XHTTP_PATH=${xhttp_path}
XHTTP_MODE=${xhttp_mode}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_xhttp_uri "${server_host}" "${port}" "${uuid}" "${xhttp_path}" "${xhttp_mode}")"

  echo
  green "VLESS XHTTP 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lntp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
}

vless_tcp_dynamic_install() {
  local detected_ip
  local server_host
  local port_range
  local uuid
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port_range="$(prompt_port_range '请输入 VLESS TCP dynamic port 端口范围，必须在 NAT 面板转发整个 TCP 端口范围' '20400-20410')"
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"

  yellow "VLESS TCP dynamic port 会在 TCP 端口范围 ${port_range} 中随机监听。NAT 面板必须转发整个 TCP 端口范围。"
  if ! prompt_yes_no '确认继续安装 VLESS TCP dynamic port' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vless_tcp_dynamic_config "${port_range}" "${uuid}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vless-tcp-dynamic
XRAY_HOST=${server_host}
XRAY_PORT_RANGE=${port_range}
XRAY_UUID=${uuid}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_uri "VLESS-TCP-dynamic-${server_host}" "${server_host}" "${port_range}" "${uuid}" 'tcp' '' '' 'none')"

  echo
  green "VLESS TCP dynamic port 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否转发整个 TCP 端口范围 ${port_range}。"
}

vless_ws_dynamic_install() {
  local detected_ip
  local server_host
  local port_range
  local uuid
  local ws_path
  local host_header
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port_range="$(prompt_port_range '请输入 VLESS WS dynamic port 端口范围，必须在 NAT 面板转发整个 TCP 端口范围' '20500-20510')"
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"
  ws_path="$(normalize_ws_path "$(prompt_value '请输入 WebSocket 路径' "/$(random_hex 8)")")"
  host_header="$(prompt_value '请输入 WebSocket Host 伪装域名，留空使用连接地址' "${server_host}")"

  yellow "VLESS WS dynamic port 会在 TCP 端口范围 ${port_range} 中随机监听。NAT 面板必须转发整个 TCP 端口范围。"
  if ! prompt_yes_no '确认继续安装 VLESS WS dynamic port' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vless_ws_dynamic_config "${port_range}" "${uuid}" "${ws_path}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vless-ws-dynamic
XRAY_HOST=${server_host}
XRAY_PORT_RANGE=${port_range}
XRAY_UUID=${uuid}
WS_PATH=${ws_path}
WS_HOST=${host_header}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_uri "VLESS-WS-dynamic-${server_host}" "${server_host}" "${port_range}" "${uuid}" 'ws' "${ws_path}" "${host_header}" 'none')"

  echo
  green "VLESS WS dynamic port 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否转发整个 TCP 端口范围 ${port_range}。"
}

vless_mkcp_install() {
  local detected_ip
  local server_host
  local port
  local uuid
  local header_type
  local seed
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port="$(prompt_port '请输入 VLESS mKCP UDP 端口，必须在 NAT 面板转发 UDP' '10092')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"
  header_type="$(prompt_kcp_header_type '请输入 mKCP header type' 'none')"
  seed="$(prompt_value '请输入 mKCP seed，留空使用随机值' "$(random_hex 8)")"

  yellow "VLESS mKCP 走 UDP。请确认 NAT 面板已转发 UDP ${port} 到本机，不是 TCP。"
  if ! prompt_yes_no '确认继续安装 VLESS mKCP' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vless_mkcp_config "${port}" "${uuid}" "${header_type}" "${seed}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vless-mkcp
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
KCP_HEADER_TYPE=${header_type}
KCP_SEED=${seed}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_uri "VLESS-mKCP-${server_host}" "${server_host}" "${port}" "${uuid}" 'kcp' '' '' 'none' "${seed}" "${header_type}")"

  echo
  green "VLESS mKCP 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lunp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否转发 UDP ${port}。"
}

vless_mkcp_dynamic_install() {
  local detected_ip
  local server_host
  local port_range
  local uuid
  local header_type
  local seed
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port_range="$(prompt_port_range '请输入 VLESS mKCP UDP 端口范围，必须在 NAT 面板转发整个 UDP 端口范围' '20100-20110')"
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"
  header_type="$(prompt_kcp_header_type '请输入 mKCP header type' 'none')"
  seed="$(prompt_value '请输入 mKCP seed，留空使用随机值' "$(random_hex 8)")"

  yellow "VLESS mKCP dynamic port 会在 UDP 端口范围 ${port_range} 中随机监听。NAT 面板必须转发整个 UDP 端口范围。"
  if ! prompt_yes_no '确认继续安装 VLESS mKCP dynamic port' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vless_mkcp_dynamic_config "${port_range}" "${uuid}" "${header_type}" "${seed}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vless-mkcp-dynamic
XRAY_HOST=${server_host}
XRAY_PORT_RANGE=${port_range}
XRAY_UUID=${uuid}
KCP_HEADER_TYPE=${header_type}
KCP_SEED=${seed}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_uri "VLESS-mKCP-dynamic-${server_host}" "${server_host}" "${port_range}" "${uuid}" 'kcp' '' '' 'none' "${seed}" "${header_type}")"

  echo
  green "VLESS mKCP dynamic port 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否转发整个 UDP 端口范围 ${port_range}。"
}

vless_tcp_tls_install() {
  local detected_ip
  local server_host
  local domain
  local port
  local uuid
  local cert_dir
  local cert_file
  local key_file
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  domain="$(prompt_value '请输入用于 TLS 证书和 SNI 的域名' "${server_host}")"
  port="$(prompt_port '请输入 VLESS TCP TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"

  yellow "接下来会使用 DNS-01 手动 TXT 验证申请证书，不测试 80/443。"
  if ! prompt_yes_no '确认继续安装 VLESS TCP TLS' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  request_tls_cert_manual_dns "${domain}"
  cert_dir="$(cert_dir_for_domain "${domain}")"
  cert_file="${cert_dir}/fullchain.cer"
  key_file="${cert_dir}/private.key"

  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vless_tcp_tls_config "${port}" "${uuid}" "${cert_file}" "${key_file}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vless-tcp-tls
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
TLS_DOMAIN=${domain}
TLS_CERT=${cert_file}
TLS_KEY=${key_file}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_tcp_tls_uri "${server_host}" "${port}" "${uuid}" "${domain}")"

  echo
  green "VLESS TCP TLS 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
}

vless_ws_tls_install() {
  local detected_ip
  local server_host
  local domain
  local port
  local uuid
  local ws_path
  local cert_dir
  local cert_file
  local key_file
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  domain="$(prompt_value '请输入用于 TLS 证书的域名' "${server_host}")"
  port="$(prompt_port '请输入 VLESS WS TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"
  ws_path="$(normalize_ws_path "$(prompt_value '请输入 WebSocket 路径' "/$(random_hex 8)")")"

  yellow "接下来会使用 DNS-01 手动 TXT 验证申请证书，不测试 80/443。"
  if ! prompt_yes_no '确认继续安装 VLESS WS TLS' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  request_tls_cert_manual_dns "${domain}"
  cert_dir="$(cert_dir_for_domain "${domain}")"
  cert_file="${cert_dir}/fullchain.cer"
  key_file="${cert_dir}/private.key"

  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vless_ws_tls_config "${port}" "${uuid}" "${ws_path}" "${cert_file}" "${key_file}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vless-ws-tls
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
TLS_DOMAIN=${domain}
WS_PATH=${ws_path}
TLS_CERT=${cert_file}
TLS_KEY=${key_file}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_ws_tls_uri "${server_host}" "${port}" "${uuid}" "${domain}" "${ws_path}")"

  echo
  green "VLESS WS TLS 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
}

trojan_tls_install() {
  local detected_ip
  local server_host
  local domain
  local port
  local password
  local cert_dir
  local cert_file
  local key_file
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  domain="$(prompt_value '请输入用于 TLS 证书的域名' "${server_host}")"
  port="$(prompt_port '请输入 Trojan TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')"
  ensure_port_available port
  password="$(prompt_value '请输入 Trojan 密码，留空使用随机值' "$(random_hex 16)")"

  yellow "接下来会使用 DNS-01 手动 TXT 验证申请证书，不测试 80/443。"
  if ! prompt_yes_no '确认继续安装 Trojan TLS' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  request_tls_cert_manual_dns "${domain}"
  cert_dir="$(cert_dir_for_domain "${domain}")"
  cert_file="${cert_dir}/fullchain.cer"
  key_file="${cert_dir}/private.key"

  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_trojan_tls_config "${port}" "${password}" "${cert_file}" "${key_file}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=trojan-tls
XRAY_HOST=${server_host}
XRAY_PORT=${port}
TROJAN_PASSWORD=${password}
TLS_DOMAIN=${domain}
TLS_CERT=${cert_file}
TLS_KEY=${key_file}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_trojan_tls_uri "${server_host}" "${port}" "${password}" "${domain}")"

  echo
  green "Trojan TLS 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
}

vmess_tcp_install() {
  local detected_ip
  local server_host
  local port
  local uuid
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port="$(prompt_port '请输入 VMess TCP 端口，必须在 NAT 面板转发 TCP' '10086')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"

  yellow "VMess TCP 不带 TLS，适合临时或内测使用；公网长期使用建议优先 Reality/HY2/TLS。"
  if ! prompt_yes_no '确认继续安装 VMess TCP' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vmess_tcp_config "${port}" "${uuid}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vmess-tcp
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-TCP-${server_host}" "${server_host}" "${port}" "${uuid}" 'tcp' '' '')"

  echo
  green "VMess TCP 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
}

vmess_ws_install() {
  local detected_ip
  local server_host
  local port
  local uuid
  local ws_path
  local host_header
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port="$(prompt_port '请输入 VMess WS TCP 端口，必须在 NAT 面板转发 TCP' '10087')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"
  ws_path="$(normalize_ws_path "$(prompt_value '请输入 WebSocket 路径' "/$(random_hex 8)")")"
  host_header="$(prompt_value '请输入 WebSocket Host 伪装域名，留空使用连接地址' "${server_host}")"

  yellow "VMess WS 当前不带 TLS；如需 TLS 请用 VLESS WS TLS。"
  if ! prompt_yes_no '确认继续安装 VMess WS' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vmess_ws_config "${port}" "${uuid}" "${ws_path}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vmess-ws
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
WS_PATH=${ws_path}
WS_HOST=${host_header}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-WS-${server_host}" "${server_host}" "${port}" "${uuid}" 'ws' "${ws_path}" "${host_header}")"

  echo
  green "VMess WS 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
}

vmess_httpupgrade_install() {
  local detected_ip
  local server_host
  local port
  local uuid
  local http_path
  local host_header
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port="$(prompt_port '请输入 VMess HTTPUpgrade TCP 端口，必须在 NAT 面板转发 TCP' '10094')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"
  http_path="$(normalize_ws_path "$(prompt_value '请输入 HTTPUpgrade 路径' "/$(random_hex 8)")")"
  host_header="$(prompt_value '请输入 HTTPUpgrade Host 伪装域名，留空使用连接地址' "${server_host}")"

  yellow "VMess HTTPUpgrade 当前不带 TLS；公网长期使用建议优先 VLESS/Reality/HY2/TLS。"
  if ! prompt_yes_no '确认继续安装 VMess HTTPUpgrade' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vmess_httpupgrade_config "${port}" "${uuid}" "${http_path}" "${host_header}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vmess-httpupgrade
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
HTTP_PATH=${http_path}
HTTP_HOST=${host_header}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-HTTPUpgrade-${server_host}" "${server_host}" "${port}" "${uuid}" 'httpupgrade' "${http_path}" "${host_header}")"

  echo
  green "VMess HTTPUpgrade 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lntp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
}

vmess_grpc_install() {
  local detected_ip
  local server_host
  local port
  local uuid
  local service_name
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port="$(prompt_port '请输入 VMess gRPC TCP 端口，必须在 NAT 面板转发 TCP' '10096')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"
  service_name="$(prompt_value '请输入 gRPC serviceName' "$(random_hex 8)")"

  yellow "VMess gRPC 当前不带 TLS；如需证书保护，请使用 VMess gRPC TLS。"
  if ! prompt_yes_no '确认继续安装 VMess gRPC' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vmess_grpc_config "${port}" "${uuid}" "${service_name}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vmess-grpc
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
GRPC_SERVICE_NAME=${service_name}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-gRPC-${server_host}" "${server_host}" "${port}" "${uuid}" 'grpc' "${service_name}" '')"

  echo
  green "VMess gRPC 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lntp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
}

vmess_xhttp_install() {
  local detected_ip
  local server_host
  local port
  local uuid
  local xhttp_path
  local xhttp_mode
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port="$(prompt_port '请输入 VMess XHTTP TCP 端口，必须在 NAT 面板转发 TCP' '10098')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"
  xhttp_path="$(normalize_ws_path "$(prompt_value '请输入 XHTTP 路径' "/$(random_hex 8)")")"
  xhttp_mode="$(prompt_value '请输入 XHTTP mode' 'auto')"

  yellow "VMess XHTTP 当前不带 TLS；公网长期使用建议优先 VLESS/Reality/HY2/TLS。"
  if ! prompt_yes_no '确认继续安装 VMess XHTTP' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vmess_xhttp_config "${port}" "${uuid}" "${xhttp_path}" "${xhttp_mode}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vmess-xhttp
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
XHTTP_PATH=${xhttp_path}
XHTTP_MODE=${xhttp_mode}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-XHTTP-${server_host}" "${server_host}" "${port}" "${uuid}" 'xhttp' "${xhttp_path}" "${xhttp_mode}")"

  echo
  green "VMess XHTTP 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lntp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
}

vmess_tcp_dynamic_install() {
  local detected_ip
  local server_host
  local port_range
  local uuid
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port_range="$(prompt_port_range '请输入 VMess TCP dynamic port 端口范围，必须在 NAT 面板转发整个 TCP 端口范围' '20200-20210')"
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"

  yellow "VMess TCP dynamic port 会在 TCP 端口范围 ${port_range} 中随机监听。NAT 面板必须转发整个 TCP 端口范围。"
  if ! prompt_yes_no '确认继续安装 VMess TCP dynamic port' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vmess_tcp_dynamic_config "${port_range}" "${uuid}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vmess-tcp-dynamic
XRAY_HOST=${server_host}
XRAY_PORT_RANGE=${port_range}
XRAY_UUID=${uuid}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-TCP-dynamic-${server_host}" "${server_host}" "${port_range}" "${uuid}" 'tcp' '' '')"

  echo
  green "VMess TCP dynamic port 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否转发整个 TCP 端口范围 ${port_range}。"
}

vmess_ws_dynamic_install() {
  local detected_ip
  local server_host
  local port_range
  local uuid
  local ws_path
  local host_header
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port_range="$(prompt_port_range '请输入 VMess WS dynamic port 端口范围，必须在 NAT 面板转发整个 TCP 端口范围' '20300-20310')"
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"
  ws_path="$(normalize_ws_path "$(prompt_value '请输入 WebSocket 路径' "/$(random_hex 8)")")"
  host_header="$(prompt_value '请输入 WebSocket Host 伪装域名，留空使用连接地址' "${server_host}")"

  yellow "VMess WS dynamic port 会在 TCP 端口范围 ${port_range} 中随机监听。NAT 面板必须转发整个 TCP 端口范围。"
  if ! prompt_yes_no '确认继续安装 VMess WS dynamic port' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vmess_ws_dynamic_config "${port_range}" "${uuid}" "${ws_path}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vmess-ws-dynamic
XRAY_HOST=${server_host}
XRAY_PORT_RANGE=${port_range}
XRAY_UUID=${uuid}
WS_PATH=${ws_path}
WS_HOST=${host_header}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-WS-dynamic-${server_host}" "${server_host}" "${port_range}" "${uuid}" 'ws' "${ws_path}" "${host_header}")"

  echo
  green "VMess WS dynamic port 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否转发整个 TCP 端口范围 ${port_range}。"
}

vmess_mkcp_install() {
  local detected_ip
  local server_host
  local port
  local uuid
  local header_type
  local seed
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port="$(prompt_port '请输入 VMess mKCP UDP 端口，必须在 NAT 面板转发 UDP' '10089')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"
  header_type="$(prompt_kcp_header_type '请输入 mKCP header type' 'none')"
  seed="$(prompt_value '请输入 mKCP seed，留空使用随机值' "$(random_hex 8)")"

  yellow "VMess mKCP 走 UDP。请确认 NAT 面板已转发 UDP ${port} 到本机，不是 TCP。"
  if ! prompt_yes_no '确认继续安装 VMess mKCP' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vmess_mkcp_config "${port}" "${uuid}" "${header_type}" "${seed}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vmess-mkcp
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
KCP_HEADER_TYPE=${header_type}
KCP_SEED=${seed}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-mKCP-${server_host}" "${server_host}" "${port}" "${uuid}" 'kcp' "${seed}" "${header_type}")"

  echo
  green "VMess mKCP 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lunp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否转发 UDP ${port}。"
}

vmess_mkcp_dynamic_install() {
  local detected_ip
  local server_host
  local port_range
  local uuid
  local header_type
  local seed
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port_range="$(prompt_port_range '请输入 VMess mKCP UDP 端口范围，必须在 NAT 面板转发整个 UDP 端口范围' '20000-20010')"
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"
  header_type="$(prompt_kcp_header_type '请输入 mKCP header type' 'none')"
  seed="$(prompt_value '请输入 mKCP seed，留空使用随机值' "$(random_hex 8)")"

  yellow "VMess mKCP dynamic port 会在 UDP 端口范围 ${port_range} 中随机监听。NAT 面板必须转发整个 UDP 端口范围。"
  if ! prompt_yes_no '确认继续安装 VMess mKCP dynamic port' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vmess_mkcp_dynamic_config "${port_range}" "${uuid}" "${header_type}" "${seed}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vmess-mkcp-dynamic
XRAY_HOST=${server_host}
XRAY_PORT_RANGE=${port_range}
XRAY_UUID=${uuid}
KCP_HEADER_TYPE=${header_type}
KCP_SEED=${seed}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-mKCP-dynamic-${server_host}" "${server_host}" "${port_range}" "${uuid}" 'kcp' "${seed}" "${header_type}")"

  echo
  green "VMess mKCP dynamic port 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否转发整个 UDP 端口范围 ${port_range}。"
}

shadowsocks_install() {
  local detected_ip
  local server_host
  local port
  local method
  local password
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  port="$(prompt_port '请输入 Shadowsocks 端口，TCP/UDP 都建议在 NAT 面板转发' '10088')"
  ensure_port_available port
  method="$(prompt_value '请输入加密方法' 'chacha20-ietf-poly1305')"
  password="$(prompt_value '请输入 Shadowsocks 密码，留空使用随机值' "$(random_hex 16)")"

  yellow "Shadowsocks 配置为 tcp,udp；如果 NAT 面板只转发 TCP，UDP 功能不可用但 TCP 仍可用。"
  if ! prompt_yes_no '确认继续安装 Shadowsocks' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_shadowsocks_config "${port}" "${method}" "${password}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=shadowsocks
XRAY_HOST=${server_host}
XRAY_PORT=${port}
SS_METHOD=${method}
SS_PASSWORD=${password}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_shadowsocks_uri "${server_host}" "${port}" "${method}" "${password}")"

  echo
  green "Shadowsocks 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
}

vmess_tcp_tls_install() {
  local detected_ip
  local server_host
  local domain
  local port
  local uuid
  local cert_dir
  local cert_file
  local key_file
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  domain="$(prompt_value '请输入用于 TLS 证书和 SNI 的域名' "${server_host}")"
  port="$(prompt_port '请输入 VMess TCP TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"

  yellow "接下来会使用 DNS-01 手动 TXT 验证申请证书，不测试 80/443。"
  if ! prompt_yes_no '确认继续安装 VMess TCP TLS' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  request_tls_cert_manual_dns "${domain}"
  cert_dir="$(cert_dir_for_domain "${domain}")"
  cert_file="${cert_dir}/fullchain.cer"
  key_file="${cert_dir}/private.key"

  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vmess_tcp_tls_config "${port}" "${uuid}" "${cert_file}" "${key_file}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vmess-tcp-tls
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
TLS_DOMAIN=${domain}
TLS_CERT=${cert_file}
TLS_KEY=${key_file}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_tcp_tls_link "VMess-TCP-TLS-${server_host}" "${server_host}" "${port}" "${uuid}" "${domain}")"

  echo
  green "VMess TCP TLS 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
}

vmess_ws_tls_install() {
  local detected_ip
  local server_host
  local domain
  local port
  local uuid
  local ws_path
  local cert_dir
  local cert_file
  local key_file
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  domain="$(prompt_value '请输入用于 TLS 证书和 SNI 的域名' "${server_host}")"
  port="$(prompt_port '请输入 VMess WS TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"
  ws_path="$(normalize_ws_path "$(prompt_value '请输入 WebSocket 路径' "/$(random_hex 8)")")"

  yellow "接下来会使用 DNS-01 手动 TXT 验证申请证书，不测试 80/443。"
  if ! prompt_yes_no '确认继续安装 VMess WS TLS' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  request_tls_cert_manual_dns "${domain}"
  cert_dir="$(cert_dir_for_domain "${domain}")"
  cert_file="${cert_dir}/fullchain.cer"
  key_file="${cert_dir}/private.key"

  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vmess_ws_tls_config "${port}" "${uuid}" "${ws_path}" "${cert_file}" "${key_file}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vmess-ws-tls
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
TLS_DOMAIN=${domain}
WS_PATH=${ws_path}
TLS_CERT=${cert_file}
TLS_KEY=${key_file}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-WS-TLS-${server_host}" "${server_host}" "${port}" "${uuid}" 'ws' "${ws_path}" "${domain}" 'tls')"

  echo
  green "VMess WS TLS 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
}

vmess_grpc_tls_install() {
  local detected_ip
  local server_host
  local domain
  local port
  local uuid
  local service_name
  local cert_dir
  local cert_file
  local key_file
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  domain="$(prompt_value '请输入用于 TLS 证书和 SNI 的域名' "${server_host}")"
  port="$(prompt_port '请输入 VMess gRPC TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"
  service_name="$(prompt_value '请输入 gRPC serviceName' "$(random_hex 8)")"

  yellow "接下来会使用 DNS-01 手动 TXT 验证申请证书，不测试 80/443。"
  if ! prompt_yes_no '确认继续安装 VMess gRPC TLS' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  request_tls_cert_manual_dns "${domain}"
  cert_dir="$(cert_dir_for_domain "${domain}")"
  cert_file="${cert_dir}/fullchain.cer"
  key_file="${cert_dir}/private.key"

  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vmess_grpc_tls_config "${port}" "${uuid}" "${service_name}" "${cert_file}" "${key_file}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vmess-grpc-tls
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
TLS_DOMAIN=${domain}
GRPC_SERVICE_NAME=${service_name}
TLS_CERT=${cert_file}
TLS_KEY=${key_file}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-gRPC-TLS-${server_host}" "${server_host}" "${port}" "${uuid}" 'grpc' "${service_name}" "${domain}" 'tls')"

  echo
  green "VMess gRPC TLS 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
}

vless_grpc_tls_install() {
  local detected_ip
  local server_host
  local domain
  local port
  local uuid
  local service_name
  local cert_dir
  local cert_file
  local key_file
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  domain="$(prompt_value '请输入用于 TLS 证书和 SNI 的域名' "${server_host}")"
  port="$(prompt_port '请输入 VLESS gRPC TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')"
  ensure_port_available port
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"
  service_name="$(prompt_value '请输入 gRPC serviceName' "$(random_hex 8)")"

  yellow "接下来会使用 DNS-01 手动 TXT 验证申请证书，不测试 80/443。"
  if ! prompt_yes_no '确认继续安装 VLESS gRPC TLS' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  request_tls_cert_manual_dns "${domain}"
  cert_dir="$(cert_dir_for_domain "${domain}")"
  cert_file="${cert_dir}/fullchain.cer"
  key_file="${cert_dir}/private.key"

  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_vless_grpc_tls_config "${port}" "${uuid}" "${service_name}" "${cert_file}" "${key_file}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vless-grpc-tls
XRAY_HOST=${server_host}
XRAY_PORT=${port}
XRAY_UUID=${uuid}
TLS_DOMAIN=${domain}
GRPC_SERVICE_NAME=${service_name}
TLS_CERT=${cert_file}
TLS_KEY=${key_file}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_grpc_tls_uri "${server_host}" "${port}" "${uuid}" "${domain}" "${service_name}")"

  echo
  green "VLESS gRPC TLS 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
}

trojan_ws_tls_install() {
  local detected_ip
  local server_host
  local domain
  local port
  local password
  local ws_path
  local cert_dir
  local cert_file
  local key_file
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  domain="$(prompt_value '请输入用于 TLS 证书和 SNI 的域名' "${server_host}")"
  port="$(prompt_port '请输入 Trojan WS TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')"
  ensure_port_available port
  password="$(prompt_value '请输入 Trojan 密码，留空使用随机值' "$(random_hex 16)")"
  ws_path="$(normalize_ws_path "$(prompt_value '请输入 WebSocket 路径' "/$(random_hex 8)")")"

  yellow "接下来会使用 DNS-01 手动 TXT 验证申请证书，不测试 80/443。"
  if ! prompt_yes_no '确认继续安装 Trojan WS TLS' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  request_tls_cert_manual_dns "${domain}"
  cert_dir="$(cert_dir_for_domain "${domain}")"
  cert_file="${cert_dir}/fullchain.cer"
  key_file="${cert_dir}/private.key"

  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_trojan_ws_tls_config "${port}" "${password}" "${ws_path}" "${cert_file}" "${key_file}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=trojan-ws-tls
XRAY_HOST=${server_host}
XRAY_PORT=${port}
TROJAN_PASSWORD=${password}
TLS_DOMAIN=${domain}
WS_PATH=${ws_path}
TLS_CERT=${cert_file}
TLS_KEY=${key_file}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_trojan_ws_tls_uri "${server_host}" "${port}" "${password}" "${domain}" "${ws_path}")"

  echo
  green "Trojan WS TLS 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
}

trojan_grpc_tls_install() {
  local detected_ip
  local server_host
  local domain
  local port
  local password
  local service_name
  local cert_dir
  local cert_file
  local key_file
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  domain="$(prompt_value '请输入用于 TLS 证书和 SNI 的域名' "${server_host}")"
  port="$(prompt_port '请输入 Trojan gRPC TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')"
  ensure_port_available port
  password="$(prompt_value '请输入 Trojan 密码，留空使用随机值' "$(random_hex 16)")"
  service_name="$(prompt_value '请输入 gRPC serviceName' "$(random_hex 8)")"

  yellow "接下来会使用 DNS-01 手动 TXT 验证申请证书，不测试 80/443。"
  if ! prompt_yes_no '确认继续安装 Trojan gRPC TLS' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  request_tls_cert_manual_dns "${domain}"
  cert_dir="$(cert_dir_for_domain "${domain}")"
  cert_file="${cert_dir}/fullchain.cer"
  key_file="${cert_dir}/private.key"

  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_trojan_grpc_tls_config "${port}" "${password}" "${service_name}" "${cert_file}" "${key_file}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=trojan-grpc-tls
XRAY_HOST=${server_host}
XRAY_PORT=${port}
TROJAN_PASSWORD=${password}
TLS_DOMAIN=${domain}
GRPC_SERVICE_NAME=${service_name}
TLS_CERT=${cert_file}
TLS_KEY=${key_file}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_trojan_grpc_tls_uri "${server_host}" "${port}" "${password}" "${domain}" "${service_name}")"

  echo
  green "Trojan gRPC TLS 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
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

show_menu() {
  cat <<EOF

请选择要安装或配置的协议：
  1) Hysteria2 (HY2) - 推荐 NAT 机优先使用，UDP
  2) VLESS Reality - TCP，不需要 TLS 证书
  3) VLESS WS TLS - TCP，TLS 使用 TXT 检测
  4) Trojan TLS - TCP，TLS 使用 TXT 检测
  5) VMess TCP - TCP，不带 TLS
  6) VMess WS - TCP，不带 TLS
  7) Shadowsocks - TCP/UDP
  8) VMess WS TLS - TCP，TLS 使用 TXT 检测
  9) VMess gRPC TLS - TCP，TLS 使用 TXT 检测
  10) VLESS gRPC TLS - TCP，TLS 使用 TXT 检测
  11) Trojan WS TLS - TCP，TLS 使用 TXT 检测
  12) Trojan gRPC TLS - TCP，TLS 使用 TXT 检测
  13) VMess mKCP - UDP，不带 TLS
  14) VMess mKCP dynamic port - UDP 端口范围
  15) VLESS TCP - TCP，不带 TLS
  16) VLESS WS - TCP，不带 TLS
  17) VLESS mKCP - UDP，不带 TLS
  18) VLESS mKCP dynamic port - UDP 端口范围
  19) VMess TCP dynamic port - TCP 端口范围
  20) VMess WS dynamic port - TCP 端口范围
  21) VLESS TCP dynamic port - TCP 端口范围
  22) VLESS WS dynamic port - TCP 端口范围
  23) VLESS TCP TLS - TCP，TLS 使用 TXT 检测
  24) VMess TCP TLS - TCP，TLS 使用 TXT 检测
  25) VLESS HTTPUpgrade - TCP，不带 TLS
  26) VMess HTTPUpgrade - TCP，不带 TLS
  27) VLESS gRPC - TCP，不带 TLS
  28) VMess gRPC - TCP，不带 TLS
  29) VLESS XHTTP - TCP，不带 TLS
  30) VMess XHTTP - TCP，不带 TLS
  31) TLS TXT 检测工具
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
      2) reality_install ;;
      3) vless_ws_tls_install ;;
      4) trojan_tls_install ;;
      5) vmess_tcp_install ;;
      6) vmess_ws_install ;;
      7) shadowsocks_install ;;
      8) vmess_ws_tls_install ;;
      9) vmess_grpc_tls_install ;;
      10) vless_grpc_tls_install ;;
      11) trojan_ws_tls_install ;;
      12) trojan_grpc_tls_install ;;
      13) vmess_mkcp_install ;;
      14) vmess_mkcp_dynamic_install ;;
      15) vless_tcp_install ;;
      16) vless_ws_install ;;
      17) vless_mkcp_install ;;
      18) vless_mkcp_dynamic_install ;;
      19) vmess_tcp_dynamic_install ;;
      20) vmess_ws_dynamic_install ;;
      21) vless_tcp_dynamic_install ;;
      22) vless_ws_dynamic_install ;;
      23) vless_tcp_tls_install ;;
      24) vmess_tcp_tls_install ;;
      25) vless_httpupgrade_install ;;
      26) vmess_httpupgrade_install ;;
      27) vless_grpc_install ;;
      28) vmess_grpc_install ;;
      29) vless_xhttp_install ;;
      30) vmess_xhttp_install ;;
      31) txt_check_tool ;;
      0) exit 0 ;;
      *) yellow "无效选项" ;;
    esac
  done
}

if [ "${NAT_V2RAY_LIB_ONLY:-0}" != "1" ]; then
  main "$@"
fi
