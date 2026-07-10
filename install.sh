#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.17.1"
PROJECT_NAME="nat-v2ray"
REPO_URL="https://github.com/dagve11/nat-v2ray"
SCRIPT_URL="https://raw.githubusercontent.com/dagve11/nat-v2ray/main/install.sh"
NV_BIN="/usr/local/bin/nv"
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
XRAY_PROFILE_DIR="${XRAY_CONFIG_DIR}/profiles"
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

configure_readline_keys() {
  if [ ! -t 0 ] || [ "${READLINE_KEYS_CONFIGURED:-0}" = "1" ]; then
    return 0
  fi

  bind '"\C-h": backward-delete-char' 2>/dev/null || true
  bind '"\C-?": backward-delete-char' 2>/dev/null || true
  bind '"\e[3~": delete-char' 2>/dev/null || true
  READLINE_KEYS_CONFIGURED=1
}

read_input() {
  local target="$1"

  if [ -t 0 ]; then
    configure_readline_keys
    IFS= read -r -e "${target}"
    printf '\n' >&2
  else
    IFS= read -r "${target}"
  fi
}

prompt_menu_choice() {
  local message="$1"
  local range_label="$2"
  local default_value="$3"
  local value

  printf '%s [%s]: ' "${message}" "${range_label}" >&2
  read_input value
  printf '%s\n' "${value:-${default_value}}"
}

prompt_value() {
  local message="$1"
  local default_value="$2"
  local value
  printf '%s [%s]: ' "${message}" "${default_value}" >&2
  read_input value
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
    read_input value
    value="${value:-${default_value}}"
    case "${value}" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) yellow "请输入 y 或 n" >&2 ;;
    esac
  done
}

prompt_required_yes() {
  local message="$1"
  local value
  while true; do
    printf '%s ' "${message}" >&2
    read_input value
    case "${value}" in
      y|Y|yes|YES) return 0 ;;
      *) yellow "请输入 (y)" >&2 ;;
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

port_range_span() {
  local port_range="$1"
  local start_port="${port_range%-*}"
  local end_port="${port_range#*-}"

  printf '%s\n' "$((end_port - start_port))"
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

prompt_optional_port() {
  local message="$1"
  local port
  while true; do
    printf '%s: ' "${message}" >&2
    read_input port
    if [ -z "${port}" ]; then
      printf '\n'
      return 0
    fi
    if validate_port "${port}"; then
      printf '%s\n' "${port}"
      return 0
    fi
    yellow "端口必须是 1-65535 的数字，或直接回车跳过" >&2
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

prompt_nat_port_pair() {
  local message="$1"
  local default_port="$2"
  local listen_port
  local public_port

  listen_port="$(prompt_port "${message}（本机监听端口）" "${default_port}")"
  public_port="$(prompt_port '请输入外网连接端口（生成分享链接使用，留空默认同本机监听端口）' "${listen_port}")"
  printf '%s %s\n' "${listen_port}" "${public_port}"
}

prompt_nat_port_range_pair() {
  local message="$1"
  local default_range="$2"
  local listen_range
  local public_range

  listen_range="$(prompt_port_range "${message}（本机监听端口范围）" "${default_range}")"
  while true; do
    public_range="$(prompt_port_range '请输入外网连接端口范围（生成分享链接使用，留空默认同本机监听端口范围）' "${listen_range}")"
    if [ "$(port_range_span "${listen_range}")" = "$(port_range_span "${public_range}")" ]; then
      printf '%s %s\n' "${listen_range}" "${public_range}"
      return 0
    fi
    yellow "内网端口范围和外网端口范围数量必须一致" >&2
  done
}

show_nat_port_mapping() {
  local listen_value="$1"
  local public_value="$2"
  local transport="$3"

  yellow "NAT 映射：外网 ${transport} ${public_value} -> 本机 ${transport} ${listen_value}。分享链接使用外网端口。"
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

version_ge() {
  local current="$1"
  local required="$2"

  [ "$(printf '%s\n%s\n' "${required}" "${current}" | sort -V | head -n1)" = "${required}" ]
}

xray_core_version_number() {
  if [ -x "${XRAY_BIN}" ]; then
    "${XRAY_BIN}" version 2>/dev/null | awk 'NR == 1 { print $2; exit }'
  else
    printf '0.0.0\n'
  fi
}

is_xray_finalmask_supported() {
  version_ge "$(xray_core_version_number)" '26.1.24'
}

render_legacy_kcp_settings() {
  local header_type="$1"
  local seed="$2"
  local legacy_header
  legacy_header="$(normalise_kcp_header_type "${header_type}")"
  legacy_header="${legacy_header:-none}"

  cat <<EOF
        "kcpSettings": {
          "mtu": 1350,
          "tti": 50,
          "uplinkCapacity": 5,
          "downlinkCapacity": 20,
          "seed": "${seed}",
          "header": {
            "type": "${legacy_header}"
          }
        }
EOF
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

render_kcp_transport_settings() {
  local header_type="$1"
  local seed="$2"

  if is_xray_finalmask_supported; then
    cat <<EOF
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
EOF
  else
    render_legacy_kcp_settings "${header_type}" "${seed}"
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

required_base_packages() {
  printf '%s\n' curl openssl ca-certificates iproute2 dnsutils unzip jq
}

required_core_components() {
  printf '%s\n' xray-core hysteria2-core
}

base_dependency_present() {
  local package="$1"

  case "${package}" in
    curl) command -v curl >/dev/null 2>&1 ;;
    openssl) command -v openssl >/dev/null 2>&1 ;;
    ca-certificates) [ -s /etc/ssl/certs/ca-certificates.crt ] ;;
    iproute2) command -v ss >/dev/null 2>&1 ;;
    dnsutils) command -v dig >/dev/null 2>&1 ;;
    unzip) command -v unzip >/dev/null 2>&1 ;;
    jq) command -v jq >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

install_base_package() {
  local package="$1"

  if ! command -v apt-get >/dev/null 2>&1; then
    die "第一版只支持 Debian/Ubuntu 系统"
  fi
  if base_dependency_present "${package}"; then
    green "依赖已安装：${package}"
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  yellow "安装依赖：${package}"
  if apt-get install -y "${package}"; then
    return 0
  fi

  yellow "安装失败，更新 apt 索引后重试"
  apt-get update
  apt-get install -y "${package}"
}

install_base_packages() {
  local required_packages=()
  local missing_packages=()
  local package

  if ! command -v apt-get >/dev/null 2>&1; then
    die "第一版只支持 Debian/Ubuntu 系统"
  fi

  mapfile -t required_packages < <(required_base_packages)
  for package in "${required_packages[@]}"; do
    if ! base_dependency_present "${package}"; then
      missing_packages+=("${package}")
    fi
  done

  if [ "${#missing_packages[@]}" -eq 0 ]; then
    return 0
  fi

  export DEBIAN_FRONTEND=noninteractive
  yellow "安装缺失基础依赖：${missing_packages[*]}"
  if apt-get install -y "${missing_packages[@]}"; then
    return 0
  fi

  yellow "安装失败，更新 apt 索引后重试"
  apt-get update
  apt-get install -y "${missing_packages[@]}"
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

  if [ -x "${HYSTERIA_BIN}" ]; then
    green "Hysteria2 core 已安装，跳过下载"
    return 0
  fi

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

  if [ -x "${XRAY_BIN}" ]; then
    green "Xray core 已安装，跳过下载"
    migrate_legacy_xray_profile
    return 0
  fi

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

  migrate_legacy_xray_profile
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

ensure_xray_profile_dirs() {
  mkdir -p "${XRAY_CONFIG_DIR}" "${XRAY_PROFILE_DIR}"
  chmod 700 "${XRAY_CONFIG_DIR}" "${XRAY_PROFILE_DIR}" 2>/dev/null || true
}

xray_env_value() {
  local key="$1"
  local env_file="${2:-${XRAY_ENV_FILE}}"

  [ -f "${env_file}" ] || return 0
  awk -v key="${key}" '
    index($0, key "=") == 1 {
      value = substr($0, length(key) + 2)
    }
    END {
      if (value != "") print value
    }
  ' "${env_file}"
}

sanitize_profile_name() {
  tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

xray_profile_name() {
  local protocol
  local public_port
  local public_range
  local host
  local base

  protocol="$(xray_env_value PROTOCOL)"
  public_port="$(xray_env_value XRAY_PUBLIC_PORT)"
  public_range="$(xray_env_value XRAY_PUBLIC_PORT_RANGE)"
  host="$(xray_env_value XRAY_HOST)"
  base="${protocol:-xray}-${public_port:-${public_range:-unknown}}-${host:-server}"
  base="$(printf '%s' "${base}" | sanitize_profile_name)"
  printf '%s\n' "${base:-xray-profile}"
}

xray_profile_names() {
  local env_file

  [ -d "${XRAY_PROFILE_DIR}" ] || return 0
  for env_file in "${XRAY_PROFILE_DIR}"/*.env; do
    [ -f "${env_file}" ] || continue
    basename "${env_file}" .env
  done | sort
}

xray_profile_count() {
  xray_profile_names | wc -l | tr -d ' '
}

rebuild_xray_config() {
  local profile_jsons=()
  local profile_json
  local temp_file

  ensure_xray_profile_dirs
  command -v jq >/dev/null 2>&1 || die "缺少 jq，无法重建 Xray 多配置"

  for profile_json in "${XRAY_PROFILE_DIR}"/*.json; do
    [ -f "${profile_json}" ] || continue
    profile_jsons+=("${profile_json}")
  done

  temp_file="${XRAY_CONFIG_FILE}.tmp.$$"
  if [ "${#profile_jsons[@]}" -eq 0 ]; then
    jq -n '{
      log: {loglevel: "warning"},
      inbounds: [],
      outbounds: [
        {protocol: "freedom", tag: "direct"},
        {protocol: "blackhole", tag: "blocked"}
      ]
    }' > "${temp_file}"
  else
    jq -s '{
      log: {loglevel: "warning"},
      inbounds: ([.[].inbounds[]?]),
      outbounds: [
        {protocol: "freedom", tag: "direct"},
        {protocol: "blackhole", tag: "blocked"}
      ]
    }' "${profile_jsons[@]}" > "${temp_file}"
  fi

  install -m 600 "${temp_file}" "${XRAY_CONFIG_FILE}"
  rm -f "${temp_file}"
}

sync_latest_xray_env() {
  local latest_env

  [ -d "${XRAY_PROFILE_DIR}" ] || return 0
  latest_env="$(ls -t "${XRAY_PROFILE_DIR}"/*.env 2>/dev/null | head -n1 || true)"
  if [ -n "${latest_env}" ]; then
    install -m 600 "${latest_env}" "${XRAY_ENV_FILE}"
  else
    rm -f "${XRAY_ENV_FILE}"
  fi
}

register_xray_profile() {
  local profile_name
  local profile_config
  local profile_env
  local temp_config
  local temp_env

  ensure_xray_profile_dirs
  command -v jq >/dev/null 2>&1 || die "缺少 jq，无法注册 Xray profile"
  [ -f "${XRAY_CONFIG_FILE}" ] || die "缺少 Xray 配置，无法注册 profile"
  [ -f "${XRAY_ENV_FILE}" ] || die "缺少 Xray 环境文件，无法注册 profile"

  profile_name="$(xray_profile_name)"
  profile_config="${XRAY_PROFILE_DIR}/${profile_name}.json"
  profile_env="${XRAY_PROFILE_DIR}/${profile_name}.env"
  temp_config="${profile_config}.tmp.$$"
  temp_env="${XRAY_ENV_FILE}.tmp.$$"

  jq --arg tag "${profile_name}" '(.inbounds[]?.tag) = $tag' "${XRAY_CONFIG_FILE}" > "${temp_config}"
  install -m 600 "${temp_config}" "${profile_config}"
  rm -f "${temp_config}"
  grep -v '^XRAY_PROFILE_NAME=' "${XRAY_ENV_FILE}" > "${temp_env}" || true
  printf 'XRAY_PROFILE_NAME=%s\n' "${profile_name}" >> "${temp_env}"
  install -m 600 "${temp_env}" "${XRAY_ENV_FILE}"
  rm -f "${temp_env}"
  install -m 600 "${XRAY_ENV_FILE}" "${profile_env}"

  rebuild_xray_config
}

append_xray_uri_and_register() {
  local uri="$1"
  local temp_env

  [ -f "${XRAY_ENV_FILE}" ] || die "缺少 Xray 环境文件，无法保存分享链接"
  temp_env="${XRAY_ENV_FILE}.tmp.$$"
  grep -v '^XRAY_URI=' "${XRAY_ENV_FILE}" > "${temp_env}" || true
  printf 'XRAY_URI=%s\n' "${uri}" >> "${temp_env}"
  install -m 600 "${temp_env}" "${XRAY_ENV_FILE}"
  rm -f "${temp_env}"
  register_xray_profile
  systemctl restart xray
}

migrate_legacy_xray_profile() {
  if [ "$(xray_profile_count)" -gt 0 ]; then
    return 0
  fi
  if [ ! -f "${XRAY_CONFIG_FILE}" ] || [ ! -f "${XRAY_ENV_FILE}" ]; then
    return 0
  fi
  if grep -q '^XRAY_PROFILE_NAME=' "${XRAY_ENV_FILE}" 2>/dev/null; then
    return 0
  fi

  yellow "检测到旧版单 Xray 配置，先迁移为 profile 以保留现有节点。"
  register_xray_profile
}

select_xray_profile() {
  local requested="${1:-}"
  local profiles=()
  local index=1
  local profile
  local choice

  if [ -n "${requested}" ]; then
    requested="${requested%.env}"
    requested="${requested%.json}"
    if [ -f "${XRAY_PROFILE_DIR}/${requested}.env" ]; then
      printf '%s\n' "${requested}"
      return 0
    fi
    die "未找到 Xray profile：${requested}"
  fi

  mapfile -t profiles < <(xray_profile_names)
  if [ "${#profiles[@]}" -eq 0 ]; then
    die "当前没有 Xray profile"
  fi
  if [ "${#profiles[@]}" -eq 1 ]; then
    printf '%s\n' "${profiles[0]}"
    return 0
  fi

  echo "请选择 Xray profile：" >&2
  for profile in "${profiles[@]}"; do
    printf '  %s) %s\n' "${index}" "${profile}" >&2
    index=$((index + 1))
  done
  printf '请选择 [1]: ' >&2
  read_input choice
  choice="${choice:-1}"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || [ "${choice}" -lt 1 ] || [ "${choice}" -gt "${#profiles[@]}" ]; then
    die "无效 profile 选项"
  fi
  printf '%s\n' "${profiles[$((choice - 1))]}"
}

profile_info() {
  local profile_name
  local env_file
  local uri

  require_linux
  profile_name="$(select_xray_profile "${1:-}")"
  env_file="${XRAY_PROFILE_DIR}/${profile_name}.env"
  uri="$(xray_env_value XRAY_URI "${env_file}")"

  echo
  echo "------------- ${profile_name} -------------"
  echo "协议: $(xray_env_value PROTOCOL "${env_file}")"
  echo "地址: $(xray_env_value XRAY_HOST "${env_file}")"
  echo "本机监听端口: $(xray_env_value XRAY_LISTEN_PORT "${env_file}")$(xray_env_value XRAY_LISTEN_PORT_RANGE "${env_file}")"
  echo "外网连接端口: $(xray_env_value XRAY_PUBLIC_PORT "${env_file}")$(xray_env_value XRAY_PUBLIC_PORT_RANGE "${env_file}")"
  echo "profile: ${env_file}"
  if [ -n "${uri}" ]; then
    echo "------------- URL -------------"
    echo "${uri}"
  else
    yellow "链接未记录，请重新安装或使用 nv url 查看新配置"
  fi
}

profile_url() {
  local profile_name
  local env_file
  local uri

  require_linux
  profile_name="$(select_xray_profile "${1:-}")"
  env_file="${XRAY_PROFILE_DIR}/${profile_name}.env"
  uri="$(xray_env_value XRAY_URI "${env_file}")"
  [ -n "${uri}" ] || die "profile ${profile_name} 没有记录分享链接"
  printf '%s\n' "${uri}"
}

profile_qr() {
  local uri

  uri="$(profile_url "${1:-}")"
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "${uri}"
  else
    yellow "未安装 qrencode，直接输出链接："
    printf '%s\n' "${uri}"
  fi
}

hy2_info() {
  local host
  local listen_port
  local public_port
  local auth_password
  local obfs_password
  local masquerade_url
  local normal_uri
  local pinned_uri
  local pin_sha256

  require_linux
  if [ ! -f "${HY2_ENV_FILE}" ]; then
    yellow "未找到 HY2 配置"
    return 0
  fi

  host="$(xray_env_value HY2_HOST "${HY2_ENV_FILE}")"
  listen_port="$(xray_env_value HY2_LISTEN_PORT "${HY2_ENV_FILE}")"
  public_port="$(xray_env_value HY2_PUBLIC_PORT "${HY2_ENV_FILE}")"
  auth_password="$(xray_env_value HY2_AUTH "${HY2_ENV_FILE}")"
  obfs_password="$(xray_env_value HY2_OBFS "${HY2_ENV_FILE}")"
  masquerade_url="$(xray_env_value HY2_MASQUERADE "${HY2_ENV_FILE}")"
  public_port="${public_port:-$(xray_env_value HY2_PORT "${HY2_ENV_FILE}")}"

  echo
  echo "------------- HY2-UDP -------------"
  echo "协议: HY2-UDP"
  echo "地址: ${host}"
  echo "本机监听端口: ${listen_port}"
  echo "外网连接端口: ${public_port}"
  echo "认证密码: ${auth_password}"
  echo "混淆: salamander"
  echo "混淆密码: ${obfs_password}"
  echo "伪装站点: ${masquerade_url}"
  echo "服务状态: $(service_status_word hysteria-server)"

  if [ -z "${host}" ] || [ -z "${public_port}" ] || [ -z "${auth_password}" ] || [ -z "${obfs_password}" ]; then
    yellow "HY2 环境文件缺少必要字段，无法生成分享链接"
    return 0
  fi

  echo "------------- URL -------------"

  if [ -f "${HY2_CERT_FILE}" ]; then
    pin_sha256="$(openssl x509 -in "${HY2_CERT_FILE}" -noout -fingerprint -sha256 2>/dev/null | sed 's/^.*=//' | tr -d ':')"
    if [ -n "${pin_sha256}" ]; then
      pinned_uri="$(build_hy2_uri "${host}" "${public_port}" "${auth_password}" "${obfs_password}" "${host}" "${pin_sha256}")"
      echo "推荐链接（v2rayN 7.23+，带 pinSHA256）:"
      echo "${pinned_uri}"
      echo
    fi
  fi

  normal_uri="$(build_hy2_uri "${host}" "${public_port}" "${auth_password}" "${obfs_password}" "${host}" '')"
  echo "兼容链接（旧客户端，insecure=1）:"
  echo "${normal_uri}"
}

delete_xray_profile() {
  local profile_name

  require_root
  require_linux
  profile_name="$(select_xray_profile "${1:-}")"
  rm -f "${XRAY_PROFILE_DIR}/${profile_name}.json" "${XRAY_PROFILE_DIR}/${profile_name}.env"
  rebuild_xray_config
  sync_latest_xray_env
  if [ "$(xray_profile_count)" -gt 0 ]; then
    systemctl restart xray || true
  else
    systemctl stop xray >/dev/null 2>&1 || true
  fi
  green "已删除 Xray profile：${profile_name}"
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
    read_input choice
    choice="${choice:-1}"
    case "${choice}" in
      1)
        port_ref="$(prompt_port '请输入新的端口' "${port_ref}")"
        ;;
      2)
        printf '请输入要停用的 systemd 服务名，留空返回: ' >&2
        read_input service_name
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
  local port="${1:-}"
  local public_port="${2:-}"
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
  if [ -z "${port}" ] || [ -z "${public_port}" ]; then
    read -r port public_port < <(prompt_nat_port_pair '请输入 HY2 UDP 端口，必须在 NAT 面板转发 UDP' '63272')
  elif ! validate_port "${port}" || ! validate_port "${public_port}"; then
    die "HY2 端口必须是 1-65535 的数字"
  fi
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
  masquerade_url="$(prompt_value '请输入伪装站点 URL' 'https://www.bing.com/')"
  auth_password="$(prompt_value '请输入 HY2 认证密码，留空使用随机值' "$(random_hex 16)")"
  obfs_password="$(prompt_value '请输入 salamander 混淆密码，留空使用随机值' "$(random_hex 16)")"

  yellow "请按上面的 NAT 映射转发 UDP。HY2 不走 TCP，只有 TCP 转发会连不上。"
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
HY2_LISTEN_PORT=${port}
HY2_PUBLIC_PORT=${public_port}
HY2_PORT=${public_port}
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
  normal_uri="$(build_hy2_uri "${server_host}" "${public_port}" "${auth_password}" "${obfs_password}" "${server_host}" '')"
  pinned_uri="$(build_hy2_uri "${server_host}" "${public_port}" "${auth_password}" "${obfs_password}" "${server_host}" "${pin_sha256}")"

  echo
  green "HY2 安装完成"
  echo "服务状态：$(systemctl is-active hysteria-server || true)"
  echo
  echo "监听检查："
  ss -lunp | grep "${port}" || true
  echo
  echo "推荐链接（v2rayN 7.23+，带 pinSHA256）："
  echo "${pinned_uri}"
  echo
  echo "兼容链接（旧客户端，insecure=1）："
  echo "${normal_uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否把外网 UDP ${public_port} 转发到本机 UDP ${port}，不是 TCP。"
}

reality_install() {
  local detected_ip
  local server_host
  local port
  local public_port
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
  read -r port public_port < <(prompt_nat_port_pair '请输入 Reality TCP 端口，必须在 NAT 面板转发 TCP' '443')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
  server_name="$(prompt_value '请输入 Reality 伪装 SNI' 'www.cloudflare.com')"
  dest="$(prompt_value '请输入 Reality 伪装目标 host:port' "${server_name}:443")"
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"
  short_id="$(prompt_value '请输入 Reality shortId，留空使用随机值' "$(random_hex 4)")"

  yellow "请按上面的 NAT 映射转发 TCP。Reality 不需要申请 TLS 证书。"
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
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

  uri="$(build_reality_uri "${server_host}" "${public_port}" "${uuid}" "${server_name}" "${public_key}" "${short_id}")"
  append_xray_uri_and_register "${uri}"

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
  if [ ! -x "${ACME_SH}" ]; then
    blue "安装 acme.sh"
    curl -fsSL https://get.acme.sh | sh -s email="$(prompt_value '请输入证书通知邮箱' 'admin@example.com')" --force
  fi
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
  issue_output="$("${ACME_SH}" --server letsencrypt --issue --dns -d "${domain}" --yes-I-know-dns-manual-mode-enough-go-ahead-please 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "${issue_output}"

  txt_value="$(printf '%s\n' "${issue_output}" | extract_acme_txt_value)"
  if [ -z "${txt_value}" ] && [ "${rc}" -ne 0 ]; then
    die "acme.sh 未生成 TXT 值，证书申请尚未进入 DNS 验证阶段。请检查 CA 账号注册、网络和内存后重试。"
  fi
  if [ -z "${txt_value}" ]; then
    yellow "未能自动解析 acme.sh 输出里的 TXT 值。"
    txt_value="$(prompt_value '请手动粘贴 acme.sh 要求的 TXT 值' '')"
  fi
  if [ -z "${txt_value}" ]; then
    die "没有 TXT 值，无法继续申请证书"
  fi

  wait_for_txt_record "${domain}" "${txt_value}" || die "TXT 验证未通过"

  set +e
  renew_output="$("${ACME_SH}" --server letsencrypt --renew -d "${domain}" --yes-I-know-dns-manual-mode-enough-go-ahead-please --force 2>&1)"
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

render_trojan_tcp_config() {
  local port="$1"
  local password="$2"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "trojan-tcp",
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

render_trojan_ws_config() {
  local port="$1"
  local password="$2"
  local ws_path="$3"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "trojan-ws",
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

render_trojan_httpupgrade_config() {
  local port="$1"
  local password="$2"
  local http_path="$3"
  local host_header="$4"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "trojan-httpupgrade",
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

render_trojan_grpc_config() {
  local port="$1"
  local password="$2"
  local service_name="$3"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "trojan-grpc",
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

render_trojan_xhttp_config() {
  local port="$1"
  local password="$2"
  local xhttp_path="$3"
  local xhttp_mode="$4"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "trojan-xhttp",
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

render_trojan_xhttp_tls_config() {
  local port="$1"
  local password="$2"
  local xhttp_path="$3"
  local xhttp_mode="$4"
  local cert_file="$5"
  local key_file="$6"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "trojan-xhttp-tls",
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
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${cert_file}",
              "keyFile": "${key_file}"
            }
          ]
        },
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

build_vless_xhttp_tls_uri() {
  local host="$1"
  local port="$2"
  local uuid="$3"
  local domain="$4"
  local xhttp_path="$5"
  local xhttp_mode="$6"
  local encoded_domain
  local encoded_path
  local encoded_mode
  encoded_domain="$(urlencode "${domain}")"
  encoded_path="$(urlencode "${xhttp_path}")"
  encoded_mode="$(urlencode "${xhttp_mode}")"
  printf 'vless://%s@%s:%s?encryption=none&security=tls&type=xhttp&path=%s&mode=%s&sni=%s#VLESS-XHTTP-TLS-%s\n' \
    "${uuid}" "${host}" "${port}" "${encoded_path}" "${encoded_mode}" "${encoded_domain}" "${host}"
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

build_trojan_uri() {
  local name="$1"
  local host="$2"
  local port="$3"
  local password="$4"
  local network="$5"
  local path="${6:-}"
  local host_header="${7:-}"
  local service_name="${8:-}"
  local xhttp_mode="${9:-}"
  local encoded_name
  local encoded_password
  local encoded_path
  local encoded_host
  local encoded_service_name
  local encoded_xhttp_mode
  local extra=""

  encoded_name="$(urlencode "${name}")"
  encoded_password="$(urlencode "${password}")"
  encoded_path="$(urlencode "${path}")"
  encoded_host="$(urlencode "${host_header}")"
  encoded_service_name="$(urlencode "${service_name}")"
  encoded_xhttp_mode="$(urlencode "${xhttp_mode}")"

  if [ "${network}" = "ws" ] || [ "${network}" = "httpupgrade" ]; then
    extra="$(printf '&host=%s&path=%s' "${encoded_host}" "${encoded_path}")"
  fi
  if [ "${network}" = "grpc" ]; then
    extra="$(printf '&serviceName=%s&mode=gun' "${encoded_service_name}")"
  fi
  if [ "${network}" = "xhttp" ]; then
    extra="$(printf '&path=%s&mode=%s' "${encoded_path}" "${encoded_xhttp_mode}")"
  fi

  printf 'trojan://%s@%s:%s?security=none&type=%s%s#%s\n' \
    "${encoded_password}" "${host}" "${port}" "${network}" "${extra}" "${encoded_name}"
}

build_trojan_xhttp_tls_uri() {
  local host="$1"
  local port="$2"
  local password="$3"
  local domain="$4"
  local xhttp_path="$5"
  local xhttp_mode="$6"
  local encoded_password
  local encoded_domain
  local encoded_path
  local encoded_mode
  encoded_password="$(urlencode "${password}")"
  encoded_domain="$(urlencode "${domain}")"
  encoded_path="$(urlencode "${xhttp_path}")"
  encoded_mode="$(urlencode "${xhttp_mode}")"
  printf 'trojan://%s@%s:%s?security=tls&type=xhttp&path=%s&mode=%s&sni=%s#Trojan-XHTTP-TLS-%s\n' \
    "${encoded_password}" "${host}" "${port}" "${encoded_path}" "${encoded_mode}" "${encoded_domain}" "${host}"
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

render_vless_xhttp_tls_config() {
  local port="$1"
  local uuid="$2"
  local xhttp_path="$3"
  local xhttp_mode="$4"
  local cert_file="$5"
  local key_file="$6"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-xhttp-tls",
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
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${cert_file}",
              "keyFile": "${key_file}"
            }
          ]
        },
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
$(render_kcp_transport_settings "${header_type}" "${seed}")
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
$(render_kcp_transport_settings "${header_type}" "${seed}")
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

render_vmess_xhttp_tls_config() {
  local port="$1"
  local uuid="$2"
  local xhttp_path="$3"
  local xhttp_mode="$4"
  local cert_file="$5"
  local key_file="$6"

  cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vmess-xhttp-tls",
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
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${cert_file}",
              "keyFile": "${key_file}"
            }
          ]
        },
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
$(render_kcp_transport_settings "${header_type}" "${seed}")
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
$(render_kcp_transport_settings "${header_type}" "${seed}")
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
  local public_port
  local uuid
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 VLESS TCP 端口，必须在 NAT 面板转发 TCP' '10090')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
XRAY_UUID=${uuid}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_uri "VLESS-TCP-${server_host}" "${server_host}" "${public_port}" "${uuid}" 'tcp' '' '' 'none')"
  append_xray_uri_and_register "${uri}"

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
  local public_port
  local uuid
  local ws_path
  local host_header
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 VLESS WS TCP 端口，必须在 NAT 面板转发 TCP' '10091')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
XRAY_UUID=${uuid}
WS_PATH=${ws_path}
WS_HOST=${host_header}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_uri "VLESS-WS-${server_host}" "${server_host}" "${public_port}" "${uuid}" 'ws' "${ws_path}" "${host_header}" 'none')"
  append_xray_uri_and_register "${uri}"

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
  local public_port
  local uuid
  local http_path
  local host_header
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 VLESS HTTPUpgrade TCP 端口，必须在 NAT 面板转发 TCP' '10093')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
XRAY_UUID=${uuid}
HTTP_PATH=${http_path}
HTTP_HOST=${host_header}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_uri "VLESS-HTTPUpgrade-${server_host}" "${server_host}" "${public_port}" "${uuid}" 'httpupgrade' "${http_path}" "${host_header}" 'none')"
  append_xray_uri_and_register "${uri}"

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
  local public_port
  local uuid
  local service_name
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 VLESS gRPC TCP 端口，必须在 NAT 面板转发 TCP' '10095')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
XRAY_UUID=${uuid}
GRPC_SERVICE_NAME=${service_name}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_grpc_uri "${server_host}" "${public_port}" "${uuid}" "${service_name}")"
  append_xray_uri_and_register "${uri}"

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
  local public_port
  local uuid
  local xhttp_path
  local xhttp_mode
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 VLESS XHTTP TCP 端口，必须在 NAT 面板转发 TCP' '10097')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
XRAY_UUID=${uuid}
XHTTP_PATH=${xhttp_path}
XHTTP_MODE=${xhttp_mode}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_xhttp_uri "${server_host}" "${public_port}" "${uuid}" "${xhttp_path}" "${xhttp_mode}")"
  append_xray_uri_and_register "${uri}"

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

vless_xhttp_tls_install() {
  local detected_ip
  local server_host
  local domain
  local port
  local public_port
  local uuid
  local xhttp_path
  local xhttp_mode
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
  read -r port public_port < <(prompt_nat_port_pair '请输入 VLESS XHTTP TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"
  xhttp_path="$(normalize_ws_path "$(prompt_value '请输入 XHTTP 路径' "/$(random_hex 8)")")"
  xhttp_mode="$(prompt_value '请输入 XHTTP mode' 'auto')"

  yellow "接下来会使用 DNS-01 手动 TXT 验证申请证书，不测试 80/443。"
  if ! prompt_yes_no '确认继续安装 VLESS XHTTP TLS' 'y'; then
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
  render_vless_xhttp_tls_config "${port}" "${uuid}" "${xhttp_path}" "${xhttp_mode}" "${cert_file}" "${key_file}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vless-xhttp-tls
XRAY_HOST=${server_host}
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
XRAY_UUID=${uuid}
TLS_DOMAIN=${domain}
XHTTP_PATH=${xhttp_path}
XHTTP_MODE=${xhttp_mode}
TLS_CERT=${cert_file}
TLS_KEY=${key_file}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_xhttp_tls_uri "${server_host}" "${public_port}" "${uuid}" "${domain}" "${xhttp_path}" "${xhttp_mode}")"
  append_xray_uri_and_register "${uri}"

  echo
  green "VLESS XHTTP TLS 安装完成"
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
  local public_port_range
  local uuid
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port_range public_port_range < <(prompt_nat_port_range_pair '请输入 VLESS TCP dynamic port 端口范围，必须在 NAT 面板转发整个 TCP 端口范围' '20400-20410')
  show_nat_port_mapping "${port_range}" "${public_port_range}" '端口范围'
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"

  yellow "VLESS TCP dynamic port 会在本机 TCP 端口范围 ${port_range} 中随机监听，分享链接使用外网范围 ${public_port_range}。NAT 面板必须转发整个 TCP 端口范围。"
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
XRAY_LISTEN_PORT_RANGE=${port_range}
XRAY_PUBLIC_PORT_RANGE=${public_port_range}
XRAY_PORT_RANGE=${public_port_range}
XRAY_UUID=${uuid}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_uri "VLESS-TCP-dynamic-${server_host}" "${server_host}" "${public_port_range}" "${uuid}" 'tcp' '' '' 'none')"
  append_xray_uri_and_register "${uri}"

  echo
  green "VLESS TCP dynamic port 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否把外网 TCP 范围 ${public_port_range} 转发到本机范围 ${port_range}。"
}

vless_ws_dynamic_install() {
  local detected_ip
  local server_host
  local port_range
  local public_port_range
  local uuid
  local ws_path
  local host_header
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port_range public_port_range < <(prompt_nat_port_range_pair '请输入 VLESS WS dynamic port 端口范围，必须在 NAT 面板转发整个 TCP 端口范围' '20500-20510')
  show_nat_port_mapping "${port_range}" "${public_port_range}" '端口范围'
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"
  ws_path="$(normalize_ws_path "$(prompt_value '请输入 WebSocket 路径' "/$(random_hex 8)")")"
  host_header="$(prompt_value '请输入 WebSocket Host 伪装域名，留空使用连接地址' "${server_host}")"

  yellow "VLESS WS dynamic port 会在本机 TCP 端口范围 ${port_range} 中随机监听，分享链接使用外网范围 ${public_port_range}。NAT 面板必须转发整个 TCP 端口范围。"
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
XRAY_LISTEN_PORT_RANGE=${port_range}
XRAY_PUBLIC_PORT_RANGE=${public_port_range}
XRAY_PORT_RANGE=${public_port_range}
XRAY_UUID=${uuid}
WS_PATH=${ws_path}
WS_HOST=${host_header}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_uri "VLESS-WS-dynamic-${server_host}" "${server_host}" "${public_port_range}" "${uuid}" 'ws' "${ws_path}" "${host_header}" 'none')"
  append_xray_uri_and_register "${uri}"

  echo
  green "VLESS WS dynamic port 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否把外网 TCP 范围 ${public_port_range} 转发到本机范围 ${port_range}。"
}

vless_mkcp_install() {
  local detected_ip
  local server_host
  local port
  local public_port
  local uuid
  local header_type
  local seed
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 VLESS mKCP UDP 端口，必须在 NAT 面板转发 UDP' '10092')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"
  header_type="$(prompt_kcp_header_type '请输入 mKCP header type' 'none')"
  seed="$(prompt_value '请输入 mKCP seed，留空使用随机值' "$(random_hex 8)")"

  yellow "VLESS mKCP 走 UDP。请按上面的 NAT 映射转发 UDP，不是 TCP。"
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
XRAY_UUID=${uuid}
KCP_HEADER_TYPE=${header_type}
KCP_SEED=${seed}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_uri "VLESS-mKCP-${server_host}" "${server_host}" "${public_port}" "${uuid}" 'kcp' '' '' 'none' "${seed}" "${header_type}")"
  append_xray_uri_and_register "${uri}"

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
  yellow "如果客户端连不上，优先检查 NAT 面板是否把外网 UDP ${public_port} 转发到本机 UDP ${port}。"
}

vless_mkcp_dynamic_install() {
  local detected_ip
  local server_host
  local port_range
  local public_port_range
  local uuid
  local header_type
  local seed
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port_range public_port_range < <(prompt_nat_port_range_pair '请输入 VLESS mKCP UDP 端口范围，必须在 NAT 面板转发整个 UDP 端口范围' '20100-20110')
  show_nat_port_mapping "${port_range}" "${public_port_range}" '端口范围'
  uuid="$(prompt_value '请输入 VLESS UUID，留空使用随机值' "$(random_uuid)")"
  header_type="$(prompt_kcp_header_type '请输入 mKCP header type' 'none')"
  seed="$(prompt_value '请输入 mKCP seed，留空使用随机值' "$(random_hex 8)")"

  yellow "VLESS mKCP dynamic port 会在本机 UDP 端口范围 ${port_range} 中随机监听，分享链接使用外网范围 ${public_port_range}。NAT 面板必须转发整个 UDP 端口范围。"
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
XRAY_LISTEN_PORT_RANGE=${port_range}
XRAY_PUBLIC_PORT_RANGE=${public_port_range}
XRAY_PORT_RANGE=${public_port_range}
XRAY_UUID=${uuid}
KCP_HEADER_TYPE=${header_type}
KCP_SEED=${seed}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vless_uri "VLESS-mKCP-dynamic-${server_host}" "${server_host}" "${public_port_range}" "${uuid}" 'kcp' '' '' 'none' "${seed}" "${header_type}")"
  append_xray_uri_and_register "${uri}"

  echo
  green "VLESS mKCP dynamic port 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否把外网 UDP 范围 ${public_port_range} 转发到本机范围 ${port_range}。"
}

vless_tcp_tls_install() {
  local detected_ip
  local server_host
  local domain
  local port
  local public_port
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
  read -r port public_port < <(prompt_nat_port_pair '请输入 VLESS TCP TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
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

  uri="$(build_vless_tcp_tls_uri "${server_host}" "${public_port}" "${uuid}" "${domain}")"
  append_xray_uri_and_register "${uri}"

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
  local public_port
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
  read -r port public_port < <(prompt_nat_port_pair '请输入 VLESS WS TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
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

  uri="$(build_vless_ws_tls_uri "${server_host}" "${public_port}" "${uuid}" "${domain}" "${ws_path}")"
  append_xray_uri_and_register "${uri}"

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
  local public_port
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
  read -r port public_port < <(prompt_nat_port_pair '请输入 Trojan TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
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

  uri="$(build_trojan_tls_uri "${server_host}" "${public_port}" "${password}" "${domain}")"
  append_xray_uri_and_register "${uri}"

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
  local public_port
  local uuid
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 VMess TCP 端口，必须在 NAT 面板转发 TCP' '10086')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
XRAY_UUID=${uuid}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-TCP-${server_host}" "${server_host}" "${public_port}" "${uuid}" 'tcp' '' '')"
  append_xray_uri_and_register "${uri}"

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
  local public_port
  local uuid
  local ws_path
  local host_header
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 VMess WS TCP 端口，必须在 NAT 面板转发 TCP' '10087')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
XRAY_UUID=${uuid}
WS_PATH=${ws_path}
WS_HOST=${host_header}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-WS-${server_host}" "${server_host}" "${public_port}" "${uuid}" 'ws' "${ws_path}" "${host_header}")"
  append_xray_uri_and_register "${uri}"

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
  local public_port
  local uuid
  local http_path
  local host_header
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 VMess HTTPUpgrade TCP 端口，必须在 NAT 面板转发 TCP' '10094')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
XRAY_UUID=${uuid}
HTTP_PATH=${http_path}
HTTP_HOST=${host_header}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-HTTPUpgrade-${server_host}" "${server_host}" "${public_port}" "${uuid}" 'httpupgrade' "${http_path}" "${host_header}")"
  append_xray_uri_and_register "${uri}"

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
  local public_port
  local uuid
  local service_name
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 VMess gRPC TCP 端口，必须在 NAT 面板转发 TCP' '10096')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
XRAY_UUID=${uuid}
GRPC_SERVICE_NAME=${service_name}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-gRPC-${server_host}" "${server_host}" "${public_port}" "${uuid}" 'grpc' "${service_name}" '')"
  append_xray_uri_and_register "${uri}"

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
  local public_port
  local uuid
  local xhttp_path
  local xhttp_mode
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 VMess XHTTP TCP 端口，必须在 NAT 面板转发 TCP' '10098')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
XRAY_UUID=${uuid}
XHTTP_PATH=${xhttp_path}
XHTTP_MODE=${xhttp_mode}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-XHTTP-${server_host}" "${server_host}" "${public_port}" "${uuid}" 'xhttp' "${xhttp_path}" "${xhttp_mode}")"
  append_xray_uri_and_register "${uri}"

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

vmess_xhttp_tls_install() {
  local detected_ip
  local server_host
  local domain
  local port
  local public_port
  local uuid
  local xhttp_path
  local xhttp_mode
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
  read -r port public_port < <(prompt_nat_port_pair '请输入 VMess XHTTP TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"
  xhttp_path="$(normalize_ws_path "$(prompt_value '请输入 XHTTP 路径' "/$(random_hex 8)")")"
  xhttp_mode="$(prompt_value '请输入 XHTTP mode' 'auto')"

  yellow "接下来会使用 DNS-01 手动 TXT 验证申请证书，不测试 80/443。"
  if ! prompt_yes_no '确认继续安装 VMess XHTTP TLS' 'y'; then
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
  render_vmess_xhttp_tls_config "${port}" "${uuid}" "${xhttp_path}" "${xhttp_mode}" "${cert_file}" "${key_file}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=vmess-xhttp-tls
XRAY_HOST=${server_host}
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
XRAY_UUID=${uuid}
TLS_DOMAIN=${domain}
XHTTP_PATH=${xhttp_path}
XHTTP_MODE=${xhttp_mode}
TLS_CERT=${cert_file}
TLS_KEY=${key_file}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-XHTTP-TLS-${server_host}" "${server_host}" "${public_port}" "${uuid}" 'xhttp' "${xhttp_path}" "${xhttp_mode}" 'tls')"
  append_xray_uri_and_register "${uri}"

  echo
  green "VMess XHTTP TLS 安装完成"
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
  local public_port_range
  local uuid
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port_range public_port_range < <(prompt_nat_port_range_pair '请输入 VMess TCP dynamic port 端口范围，必须在 NAT 面板转发整个 TCP 端口范围' '20200-20210')
  show_nat_port_mapping "${port_range}" "${public_port_range}" '端口范围'
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"

  yellow "VMess TCP dynamic port 会在本机 TCP 端口范围 ${port_range} 中随机监听，分享链接使用外网范围 ${public_port_range}。NAT 面板必须转发整个 TCP 端口范围。"
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
XRAY_LISTEN_PORT_RANGE=${port_range}
XRAY_PUBLIC_PORT_RANGE=${public_port_range}
XRAY_PORT_RANGE=${public_port_range}
XRAY_UUID=${uuid}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-TCP-dynamic-${server_host}" "${server_host}" "${public_port_range}" "${uuid}" 'tcp' '' '')"
  append_xray_uri_and_register "${uri}"

  echo
  green "VMess TCP dynamic port 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否把外网 TCP 范围 ${public_port_range} 转发到本机范围 ${port_range}。"
}

vmess_ws_dynamic_install() {
  local detected_ip
  local server_host
  local port_range
  local public_port_range
  local uuid
  local ws_path
  local host_header
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port_range public_port_range < <(prompt_nat_port_range_pair '请输入 VMess WS dynamic port 端口范围，必须在 NAT 面板转发整个 TCP 端口范围' '20300-20310')
  show_nat_port_mapping "${port_range}" "${public_port_range}" '端口范围'
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"
  ws_path="$(normalize_ws_path "$(prompt_value '请输入 WebSocket 路径' "/$(random_hex 8)")")"
  host_header="$(prompt_value '请输入 WebSocket Host 伪装域名，留空使用连接地址' "${server_host}")"

  yellow "VMess WS dynamic port 会在本机 TCP 端口范围 ${port_range} 中随机监听，分享链接使用外网范围 ${public_port_range}。NAT 面板必须转发整个 TCP 端口范围。"
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
XRAY_LISTEN_PORT_RANGE=${port_range}
XRAY_PUBLIC_PORT_RANGE=${public_port_range}
XRAY_PORT_RANGE=${public_port_range}
XRAY_UUID=${uuid}
WS_PATH=${ws_path}
WS_HOST=${host_header}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-WS-dynamic-${server_host}" "${server_host}" "${public_port_range}" "${uuid}" 'ws' "${ws_path}" "${host_header}")"
  append_xray_uri_and_register "${uri}"

  echo
  green "VMess WS dynamic port 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否把外网 TCP 范围 ${public_port_range} 转发到本机范围 ${port_range}。"
}

vmess_mkcp_install() {
  local detected_ip
  local server_host
  local port
  local public_port
  local uuid
  local header_type
  local seed
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 VMess mKCP UDP 端口，必须在 NAT 面板转发 UDP' '10089')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"
  header_type="$(prompt_kcp_header_type '请输入 mKCP header type' 'none')"
  seed="$(prompt_value '请输入 mKCP seed，留空使用随机值' "$(random_hex 8)")"

  yellow "VMess mKCP 走 UDP。请按上面的 NAT 映射转发 UDP，不是 TCP。"
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
XRAY_UUID=${uuid}
KCP_HEADER_TYPE=${header_type}
KCP_SEED=${seed}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-mKCP-${server_host}" "${server_host}" "${public_port}" "${uuid}" 'kcp' "${seed}" "${header_type}")"
  append_xray_uri_and_register "${uri}"

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
  yellow "如果客户端连不上，优先检查 NAT 面板是否把外网 UDP ${public_port} 转发到本机 UDP ${port}。"
}

vmess_mkcp_dynamic_install() {
  local detected_ip
  local server_host
  local port_range
  local public_port_range
  local uuid
  local header_type
  local seed
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port_range public_port_range < <(prompt_nat_port_range_pair '请输入 VMess mKCP UDP 端口范围，必须在 NAT 面板转发整个 UDP 端口范围' '20000-20010')
  show_nat_port_mapping "${port_range}" "${public_port_range}" '端口范围'
  uuid="$(prompt_value '请输入 VMess UUID，留空使用随机值' "$(random_uuid)")"
  header_type="$(prompt_kcp_header_type '请输入 mKCP header type' 'none')"
  seed="$(prompt_value '请输入 mKCP seed，留空使用随机值' "$(random_hex 8)")"

  yellow "VMess mKCP dynamic port 会在本机 UDP 端口范围 ${port_range} 中随机监听，分享链接使用外网范围 ${public_port_range}。NAT 面板必须转发整个 UDP 端口范围。"
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
XRAY_LISTEN_PORT_RANGE=${port_range}
XRAY_PUBLIC_PORT_RANGE=${public_port_range}
XRAY_PORT_RANGE=${public_port_range}
XRAY_UUID=${uuid}
KCP_HEADER_TYPE=${header_type}
KCP_SEED=${seed}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_vmess_link "VMess-mKCP-dynamic-${server_host}" "${server_host}" "${public_port_range}" "${uuid}" 'kcp' "${seed}" "${header_type}")"
  append_xray_uri_and_register "${uri}"

  echo
  green "VMess mKCP dynamic port 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "分享链接："
  echo "${uri}"
  echo
  yellow "如果客户端连不上，优先检查 NAT 面板是否把外网 UDP 范围 ${public_port_range} 转发到本机范围 ${port_range}。"
}

trojan_tcp_install() {
  local detected_ip
  local server_host
  local port
  local public_port
  local password
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 Trojan TCP 端口，必须在 NAT 面板转发 TCP' '10100')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
  password="$(prompt_value '请输入 Trojan 密码，留空使用随机值' "$(random_hex 16)")"

  yellow "Trojan TCP 当前不带 TLS；公网长期使用建议优先 Trojan TLS、Reality 或 HY2。"
  if ! prompt_yes_no '确认继续安装 Trojan TCP' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_trojan_tcp_config "${port}" "${password}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=trojan-tcp
XRAY_HOST=${server_host}
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
TROJAN_PASSWORD=${password}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_trojan_uri "Trojan-TCP-${server_host}" "${server_host}" "${public_port}" "${password}" 'tcp')"
  append_xray_uri_and_register "${uri}"

  echo
  green "Trojan TCP 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lntp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
}

trojan_ws_install() {
  local detected_ip
  local server_host
  local port
  local public_port
  local password
  local ws_path
  local host_header
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 Trojan WS TCP 端口，必须在 NAT 面板转发 TCP' '10101')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
  password="$(prompt_value '请输入 Trojan 密码，留空使用随机值' "$(random_hex 16)")"
  ws_path="$(normalize_ws_path "$(prompt_value '请输入 WebSocket 路径' "/$(random_hex 8)")")"
  host_header="$(prompt_value '请输入 WebSocket Host 伪装域名，留空使用连接地址' "${server_host}")"

  yellow "Trojan WS 当前不带 TLS；如需证书保护，请使用 Trojan WS TLS。"
  if ! prompt_yes_no '确认继续安装 Trojan WS' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_trojan_ws_config "${port}" "${password}" "${ws_path}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=trojan-ws
XRAY_HOST=${server_host}
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
TROJAN_PASSWORD=${password}
WS_PATH=${ws_path}
WS_HOST=${host_header}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_trojan_uri "Trojan-WS-${server_host}" "${server_host}" "${public_port}" "${password}" 'ws' "${ws_path}" "${host_header}")"
  append_xray_uri_and_register "${uri}"

  echo
  green "Trojan WS 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lntp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
}

trojan_httpupgrade_install() {
  local detected_ip
  local server_host
  local port
  local public_port
  local password
  local http_path
  local host_header
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 Trojan HTTPUpgrade TCP 端口，必须在 NAT 面板转发 TCP' '10102')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
  password="$(prompt_value '请输入 Trojan 密码，留空使用随机值' "$(random_hex 16)")"
  http_path="$(normalize_ws_path "$(prompt_value '请输入 HTTPUpgrade 路径' "/$(random_hex 8)")")"
  host_header="$(prompt_value '请输入 HTTPUpgrade Host 伪装域名，留空使用连接地址' "${server_host}")"

  yellow "Trojan HTTPUpgrade 当前不带 TLS；如需证书保护，后续使用 TLS 类协议。"
  if ! prompt_yes_no '确认继续安装 Trojan HTTPUpgrade' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_trojan_httpupgrade_config "${port}" "${password}" "${http_path}" "${host_header}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=trojan-httpupgrade
XRAY_HOST=${server_host}
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
TROJAN_PASSWORD=${password}
HTTP_PATH=${http_path}
HTTP_HOST=${host_header}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_trojan_uri "Trojan-HTTPUpgrade-${server_host}" "${server_host}" "${public_port}" "${password}" 'httpupgrade' "${http_path}" "${host_header}")"
  append_xray_uri_and_register "${uri}"

  echo
  green "Trojan HTTPUpgrade 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lntp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
}

trojan_grpc_install() {
  local detected_ip
  local server_host
  local port
  local public_port
  local password
  local service_name
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 Trojan gRPC TCP 端口，必须在 NAT 面板转发 TCP' '10103')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
  password="$(prompt_value '请输入 Trojan 密码，留空使用随机值' "$(random_hex 16)")"
  service_name="$(prompt_value '请输入 gRPC serviceName' "$(random_hex 8)")"

  yellow "Trojan gRPC 当前不带 TLS；如需证书保护，请使用 Trojan gRPC TLS。"
  if ! prompt_yes_no '确认继续安装 Trojan gRPC' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_trojan_grpc_config "${port}" "${password}" "${service_name}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=trojan-grpc
XRAY_HOST=${server_host}
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
TROJAN_PASSWORD=${password}
GRPC_SERVICE_NAME=${service_name}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_trojan_uri "Trojan-gRPC-${server_host}" "${server_host}" "${public_port}" "${password}" 'grpc' '' '' "${service_name}")"
  append_xray_uri_and_register "${uri}"

  echo
  green "Trojan gRPC 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lntp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
}

trojan_xhttp_install() {
  local detected_ip
  local server_host
  local port
  local public_port
  local password
  local xhttp_path
  local xhttp_mode
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 Trojan XHTTP TCP 端口，必须在 NAT 面板转发 TCP' '10104')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
  password="$(prompt_value '请输入 Trojan 密码，留空使用随机值' "$(random_hex 16)")"
  xhttp_path="$(normalize_ws_path "$(prompt_value '请输入 XHTTP 路径' "/$(random_hex 8)")")"
  xhttp_mode="$(prompt_value '请输入 XHTTP mode' 'auto')"

  yellow "Trojan XHTTP 当前不带 TLS；如需证书保护，后续可增加 XHTTP TLS。"
  if ! prompt_yes_no '确认继续安装 Trojan XHTTP' 'y'; then
    die "用户取消"
  fi

  install_xray_binary
  mkdir -p "${XRAY_CONFIG_DIR}"
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    cp -a "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi
  render_trojan_xhttp_config "${port}" "${password}" "${xhttp_path}" "${xhttp_mode}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=trojan-xhttp
XRAY_HOST=${server_host}
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
TROJAN_PASSWORD=${password}
XHTTP_PATH=${xhttp_path}
XHTTP_MODE=${xhttp_mode}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_trojan_uri "Trojan-XHTTP-${server_host}" "${server_host}" "${public_port}" "${password}" 'xhttp' "${xhttp_path}" '' '' "${xhttp_mode}")"
  append_xray_uri_and_register "${uri}"

  echo
  green "Trojan XHTTP 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lntp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
}

trojan_xhttp_tls_install() {
  local detected_ip
  local server_host
  local domain
  local port
  local public_port
  local password
  local xhttp_path
  local xhttp_mode
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
  read -r port public_port < <(prompt_nat_port_pair '请输入 Trojan XHTTP TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
  password="$(prompt_value '请输入 Trojan 密码，留空使用随机值' "$(random_hex 16)")"
  xhttp_path="$(normalize_ws_path "$(prompt_value '请输入 XHTTP 路径' "/$(random_hex 8)")")"
  xhttp_mode="$(prompt_value '请输入 XHTTP mode' 'auto')"

  yellow "接下来会使用 DNS-01 手动 TXT 验证申请证书，不测试 80/443。"
  if ! prompt_yes_no '确认继续安装 Trojan XHTTP TLS' 'y'; then
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
  render_trojan_xhttp_tls_config "${port}" "${password}" "${xhttp_path}" "${xhttp_mode}" "${cert_file}" "${key_file}" > "${XRAY_CONFIG_FILE}"
  chmod 600 "${XRAY_CONFIG_FILE}"

  cat > "${XRAY_ENV_FILE}" <<EOF
PROTOCOL=trojan-xhttp-tls
XRAY_HOST=${server_host}
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
TROJAN_PASSWORD=${password}
TLS_DOMAIN=${domain}
XHTTP_PATH=${xhttp_path}
XHTTP_MODE=${xhttp_mode}
TLS_CERT=${cert_file}
TLS_KEY=${key_file}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_trojan_xhttp_tls_uri "${server_host}" "${public_port}" "${password}" "${domain}" "${xhttp_path}" "${xhttp_mode}")"
  append_xray_uri_and_register "${uri}"

  echo
  green "Trojan XHTTP TLS 安装完成"
  echo "服务状态：$(systemctl is-active xray || true)"
  echo
  echo "监听检查："
  ss -lntp | grep "${port}" || true
  echo
  echo "分享链接："
  echo "${uri}"
}

shadowsocks_install() {
  local detected_ip
  local server_host
  local port
  local public_port
  local method
  local password
  local uri

  require_root
  require_linux
  install_base_packages

  detected_ip="$(public_ipv4)"
  server_host="$(prompt_value '请输入连接地址，域名或公网 IP' "${detected_ip:-example.com}")"
  read -r port public_port < <(prompt_nat_port_pair '请输入 Shadowsocks 端口，TCP/UDP 都建议在 NAT 面板转发' '10088')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
SS_METHOD=${method}
SS_PASSWORD=${password}
EOF
  chmod 600 "${XRAY_ENV_FILE}"

  write_xray_service
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray

  uri="$(build_shadowsocks_uri "${server_host}" "${public_port}" "${method}" "${password}")"
  append_xray_uri_and_register "${uri}"

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
  local public_port
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
  read -r port public_port < <(prompt_nat_port_pair '请输入 VMess TCP TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
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

  uri="$(build_vmess_tcp_tls_link "VMess-TCP-TLS-${server_host}" "${server_host}" "${public_port}" "${uuid}" "${domain}")"
  append_xray_uri_and_register "${uri}"

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
  local public_port
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
  read -r port public_port < <(prompt_nat_port_pair '请输入 VMess WS TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
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

  uri="$(build_vmess_link "VMess-WS-TLS-${server_host}" "${server_host}" "${public_port}" "${uuid}" 'ws' "${ws_path}" "${domain}" 'tls')"
  append_xray_uri_and_register "${uri}"

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
  local public_port
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
  read -r port public_port < <(prompt_nat_port_pair '请输入 VMess gRPC TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
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

  uri="$(build_vmess_link "VMess-gRPC-TLS-${server_host}" "${server_host}" "${public_port}" "${uuid}" 'grpc' "${service_name}" "${domain}" 'tls')"
  append_xray_uri_and_register "${uri}"

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
  local public_port
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
  read -r port public_port < <(prompt_nat_port_pair '请输入 VLESS gRPC TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
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

  uri="$(build_vless_grpc_tls_uri "${server_host}" "${public_port}" "${uuid}" "${domain}" "${service_name}")"
  append_xray_uri_and_register "${uri}"

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
  local public_port
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
  read -r port public_port < <(prompt_nat_port_pair '请输入 Trojan WS TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
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

  uri="$(build_trojan_ws_tls_uri "${server_host}" "${public_port}" "${password}" "${domain}" "${ws_path}")"
  append_xray_uri_and_register "${uri}"

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
  local public_port
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
  read -r port public_port < <(prompt_nat_port_pair '请输入 Trojan gRPC TLS TCP 端口，必须在 NAT 面板转发 TCP' '443')
  ensure_port_available port
  show_nat_port_mapping "${port}" "${public_port}" '端口'
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
XRAY_LISTEN_PORT=${port}
XRAY_PUBLIC_PORT=${public_port}
XRAY_PORT=${public_port}
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

  uri="$(build_trojan_grpc_tls_uri "${server_host}" "${public_port}" "${password}" "${domain}" "${service_name}")"
  append_xray_uri_and_register "${uri}"

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
  1) HY2-UDP
  2) VLESS-Reality-TCP
  3) VLESS-WS-TLS
  4) Trojan-TCP-TLS
  5) VMess-TCP
  6) VMess-WS
  7) Shadowsocks-TCP/UDP
  8) VMess-WS-TLS
  9) VMess-gRPC-TLS
  10) VLESS-gRPC-TLS
  11) Trojan-WS-TLS
  12) Trojan-gRPC-TLS
  13) VMess-mKCP-UDP
  14) VMess-mKCP-Dynamic-UDP
  15) VLESS-TCP
  16) VLESS-WS
  17) VLESS-mKCP-UDP
  18) VLESS-mKCP-Dynamic-UDP
  19) VMess-TCP-Dynamic
  20) VMess-WS-Dynamic
  21) VLESS-TCP-Dynamic
  22) VLESS-WS-Dynamic
  23) VLESS-TCP-TLS
  24) VMess-TCP-TLS
  25) VLESS-HTTPUpgrade
  26) VMess-HTTPUpgrade
  27) VLESS-gRPC
  28) VMess-gRPC
  29) VLESS-XHTTP
  30) VMess-XHTTP
  31) TLS-TXT-Check
  32) Trojan-TCP
  33) Trojan-WS
  34) Trojan-HTTPUpgrade
  35) Trojan-gRPC
  36) Trojan-XHTTP
  37) VLESS-XHTTP-TLS
  38) VMess-XHTTP-TLS
  39) Trojan-XHTTP-TLS
  0) 退出
EOF
}

install_nv_command() {
  local source_path
  local source_real
  local nv_real

  require_root
  require_linux

  source_path="${BASH_SOURCE[0]}"
  source_real="$(readlink -f "${source_path}" 2>/dev/null || printf '%s' "${source_path}")"
  nv_real="$(readlink -f "${NV_BIN}" 2>/dev/null || printf '%s' "${NV_BIN}")"
  mkdir -p "$(dirname "${NV_BIN}")"

  if [ -f "${source_path}" ] && [ -r "${source_path}" ] && [ "${source_real}" != "${nv_real}" ]; then
    install -m 0755 "${source_path}" "${NV_BIN}"
  elif [ ! -x "${NV_BIN}" ]; then
    curl -fsSL -o "${NV_BIN}" "${SCRIPT_URL}"
    chmod 0755 "${NV_BIN}"
  else
    chmod 0755 "${NV_BIN}" || true
  fi
}

ensure_nv_command() {
  if [ "$(id -u)" -eq 0 ] && [ "$(uname -s)" = "Linux" ]; then
    install_nv_command >/dev/null 2>&1 || true
  fi
}

service_status_word() {
  local service_name="$1"
  local state

  if ! command -v systemctl >/dev/null 2>&1; then
    printf 'unknown\n'
    return 0
  fi

  state="$(systemctl is-active "${service_name}" 2>/dev/null || true)"
  case "${state}" in
    active) printf 'running\n' ;;
    inactive) printf 'stopped\n' ;;
    failed) printf 'failed\n' ;;
    *) printf 'not installed\n' ;;
  esac
}

service_file_for_name() {
  local service_name="$1"

  case "${service_name}" in
    xray) printf '%s\n' "${XRAY_SERVICE_FILE}" ;;
    hysteria-server) printf '%s\n' "${HY2_SERVICE_FILE}" ;;
    *) return 1 ;;
  esac
}

manage_service() {
  local service_name="$1"
  local action="$2"
  local service_file

  service_file="$(service_file_for_name "${service_name}")" || die "未知服务：${service_name}"
  if [ ! -f "${service_file}" ]; then
    yellow "${service_name} 服务不存在，请先添加对应配置。"
    return 0
  fi

  case "${action}" in
    start) systemctl enable --now "${service_name}" ;;
    stop) systemctl stop "${service_name}" ;;
    restart) systemctl restart "${service_name}" ;;
    *) die "未知服务操作：${action}" ;;
  esac
}

color_service_status_word() {
  local status="$1"

  case "${status}" in
    running) printf '\033[32m%s\033[0m\n' "${status}" ;;
    failed) printf '\033[31m%s\033[0m\n' "${status}" ;;
    stopped) printf '\033[33m%s\033[0m\n' "${status}" ;;
    *) printf '%s\n' "${status}" ;;
  esac
}

print_service_status_line() {
  local core_name="$1"
  local version="$2"
  local service_name="$3"
  local status

  status="$(service_status_word "${service_name}")"
  [ "${status}" = "not installed" ] && return 0
  printf '%s %s: %s\n' "${core_name}" "${version}" "$(color_service_status_word "${status}")"
}

xray_version_label() {
  if [ -x "${XRAY_BIN}" ]; then
    "${XRAY_BIN}" version 2>/dev/null | awk 'NR == 1 { print $2; exit }'
  else
    printf 'not installed\n'
  fi
}

hysteria_version_label() {
  if [ -x "${HYSTERIA_BIN}" ]; then
    "${HYSTERIA_BIN}" version 2>/dev/null | awk 'NR == 1 { print $NF; exit }'
  else
    printf 'not installed\n'
  fi
}

show_service_status() {
  if [ -x "${XRAY_BIN}" ]; then
    print_service_status_line "Xray" "$(xray_version_label)" "xray"
  fi

  if [ -x "${HYSTERIA_BIN}" ]; then
    print_service_status_line "Hysteria2" "$(hysteria_version_label)" "hysteria-server"
  fi
}

show_control_panel() {
  cat <<EOF

------------- nat-v2ray ${VERSION} by AG666 -------------
$(show_service_status)
命令: nv
仓库: ${REPO_URL}

 1) 添加配置
 2) 更改配置
 3) 查看配置
 4) 删除配置
 5) 运行管理
 6) 更新
 7) 卸载
 8) 帮助
 9) 其他
10) 依赖
 0) 退出
EOF
}

print_file_if_exists() {
  local title="$1"
  local file_path="$2"

  echo
  blue "${title}: ${file_path}"
  if [ -f "${file_path}" ]; then
    sed 's/^/  /' "${file_path}"
  else
    yellow "  未找到"
  fi
}

view_config() {
  local profile

  require_linux

  show_service_status
  if [ "$(xray_profile_count)" -gt 0 ]; then
    while IFS= read -r profile; do
      [ -n "${profile}" ] || continue
      profile_info "${profile}"
    done < <(xray_profile_names)
  else
    echo
    yellow "未找到 Xray 配置"
  fi
  hy2_info
}

change_config() {
  yellow "Xray 支持多 profile 并存；添加新协议会追加 profile。HY2 当前仍按单实例管理。"
  protocol_menu
}

delete_config() {
  local choice

  require_root
  require_linux

  cat <<EOF

删除配置：
  1) 删除一个 Xray profile
  2) 删除 HY2 配置
  3) 删除全部配置
  0) 返回
EOF
  printf '请选择 [0-3]: ' >&2
  read_input choice
  choice="${choice:-0}"
  case "${choice}" in
    1) delete_xray_profile ;;
    2)
      systemctl disable --now hysteria-server >/dev/null 2>&1 || true
      rm -f "${HY2_CONFIG_FILE}" "${HY2_ENV_FILE}" "${HY2_CERT_FILE}" "${HY2_KEY_FILE}"
      green "HY2 配置已删除"
      ;;
    3)
      if ! prompt_yes_no '确认删除全部配置' 'n'; then
        yellow "已取消"
        return 0
      fi
      systemctl disable --now xray >/dev/null 2>&1 || true
      systemctl disable --now hysteria-server >/dev/null 2>&1 || true
      rm -f "${XRAY_CONFIG_FILE}" "${XRAY_ENV_FILE}"
      rm -f "${XRAY_PROFILE_DIR}"/*.json "${XRAY_PROFILE_DIR}"/*.env 2>/dev/null || true
      rm -f "${HY2_CONFIG_FILE}" "${HY2_ENV_FILE}" "${HY2_CERT_FILE}" "${HY2_KEY_FILE}"
      green "全部配置已删除"
      ;;
    0) return 0 ;;
    *) yellow "无效选项" ;;
  esac
}

runtime_management() {
  local choice

  require_root
  require_linux

  while true; do
    cat <<EOF

运行管理：
  1) 启动 Xray
  2) 停止 Xray
  3) 重启 Xray
  4) 启动 Hysteria2
  5) 停止 Hysteria2
  6) 重启 Hysteria2
  7) 查看状态
  8) 测试运行
  0) 返回
EOF
    printf '请选择 [0-8]: ' >&2
    read_input choice
    choice="${choice:-7}"
    case "${choice}" in
      1) manage_service xray start ;;
      2) manage_service xray stop ;;
      3) manage_service xray restart ;;
      4) manage_service hysteria-server start ;;
      5) manage_service hysteria-server stop ;;
      6) manage_service hysteria-server restart ;;
      7) show_service_status ;;
      8) xray_test_run ;;
      0) return 0 ;;
      *) yellow "无效选项" ;;
    esac
  done
}

update_nv_command() {
  local temp_file

  require_root
  require_linux

  temp_file="${NV_BIN}.tmp.$$"
  curl -fsSL -o "${temp_file}" "${SCRIPT_URL}" || die "下载更新失败"
  install -m 0755 "${temp_file}" "${NV_BIN}"
  rm -f "${temp_file}"
  green "nv 已更新：${NV_BIN}"
}

update_xray_core() {
  require_root
  require_linux
  install_base_packages
  install_xray_binary
  if [ -f "${XRAY_CONFIG_FILE}" ]; then
    systemctl restart xray || true
  fi
  green "Xray core 已更新"
}

update_hysteria_core() {
  require_root
  require_linux
  install_base_packages
  install_hysteria_binary
  if [ -f "${HY2_CONFIG_FILE}" ]; then
    systemctl restart hysteria-server || true
  fi
  green "Hysteria2 core 已更新"
}

update_geo_assets() {
  require_root
  require_linux

  mkdir -p /usr/local/share/xray
  curl -fL --retry 3 --connect-timeout 20 \
    -o /usr/local/share/xray/geoip.dat \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
  curl -fL --retry 3 --connect-timeout 20 \
    -o /usr/local/share/xray/geosite.dat \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
  systemctl restart xray >/dev/null 2>&1 || true
  green "geoip.dat / geosite.dat 已更新"
}

update_nat_v2ray() {
  local target="${1:-script}"

  case "${target}" in
    script|sh|nv) update_nv_command ;;
    core|xray) update_xray_core ;;
    hy2|hysteria|hysteria2) update_hysteria_core ;;
    geo|dat) update_geo_assets ;;
    *)
      die "未知更新目标：${target}，可用：script/core/hy2/geo"
      ;;
  esac
}

xray_test_run() {
  require_linux
  if [ ! -x "${XRAY_BIN}" ]; then
    die "Xray 未安装"
  fi
  if [ ! -f "${XRAY_CONFIG_FILE}" ]; then
    die "Xray 配置不存在"
  fi

  if "${XRAY_BIN}" run -test -config "${XRAY_CONFIG_FILE}"; then
    green "Xray 配置测试通过"
    return 0
  fi

  red "Xray 配置测试失败，最近日志如下："
  journalctl -u xray -n 80 --no-pager || true
  return 1
}

uninstall_nat_v2ray() {
  require_root
  require_linux

  red "将卸载 nat-v2ray，并删除脚本安装的服务、二进制、配置、证书、日志和命令。"
  prompt_required_yes '是否卸载 nat-v2ray? [y]:'

  systemctl disable --now xray >/dev/null 2>&1 || true
  systemctl disable --now hysteria-server >/dev/null 2>&1 || true
  systemctl reset-failed xray hysteria-server >/dev/null 2>&1 || true

  rm -f "${XRAY_BIN}" "${HYSTERIA_BIN}" "${NV_BIN}"
  rm -f "${XRAY_SERVICE_FILE}" "${HY2_SERVICE_FILE}"
  rm -f /lib/systemd/system/xray.service /lib/systemd/system/hysteria-server.service
  rm -f /etc/init.d/xray /etc/init.d/hysteria-server
  rm -rf "${XRAY_CONFIG_DIR}"
  rm -rf "${HY2_CONFIG_DIR}"
  rm -rf "${CERT_BASE_DIR}"
  rm -rf /usr/local/share/xray
  rm -rf /var/log/xray
  rm -rf /var/log/hysteria
  rm -rf /var/log/hysteria-server
  rm -rf /tmp/nat-v2ray-* /tmp/Xray-linux-*.zip /tmp/hysteria-linux-*

  if [ -f /root/.bashrc ]; then
    sed -i '/nat-v2ray/d;/alias nv=/d;/\/usr\/local\/bin\/nv/d' /root/.bashrc || true
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  green "卸载完成!"
  echo "脚本哪里需要完善? 请反馈"
  echo "反馈问题: ${REPO_URL}/issues"
}

show_help() {
  cat <<EOF

常用命令：
  nv              打开总控台
  nv add          添加配置，进入协议菜单
  nv info [name]  查看 Xray profile 摘要
  nv url [name]   输出 Xray profile 分享链接
  nv qr [name]    输出 Xray profile 二维码
  nv del [name]   删除 Xray profile
  nv status       查看当前配置和服务状态
  nv run          运行管理
  nv test         测试 Xray 配置
  nv update       更新 nv 命令，等同 nv update script
  nv update core  更新 Xray core
  nv update hy2   更新 Hysteria2 core
  nv update geo   更新 geoip.dat / geosite.dat
  nv deps         检查并安装脚本依赖和核心组件
  nv uninstall    卸载 nat-v2ray

说明：
  每个 Xray 节点会保存为独立 profile，并自动重建总配置以便多节点同时运行。
  TLS 类协议使用 DNS-01 手动 TXT 验证，不依赖 80/443 入站端口。
  安装时会分别询问本机监听端口和外网连接端口。
  服务端配置监听本机端口，分享链接使用外网连接端口。
  NAT 面板必须按协议类型把外网 TCP、UDP 或端口范围转发到本机。
EOF
}

other_tools() {
  local choice

  while true; do
    cat <<EOF

其他：
  1) TLS-TXT-Check
  2) 查看监听端口
  3) 安装/修复 nv 命令
  4) 测试 Xray 配置
  0) 返回
EOF
    printf '请选择 [0-4]: ' >&2
    read_input choice
    choice="${choice:-0}"
    case "${choice}" in
      1) txt_check_tool ;;
      2) ss -lntup 2>/dev/null || true ;;
      3) install_nv_command && green "nv 已安装：${NV_BIN}" ;;
      4) xray_test_run ;;
      0) return 0 ;;
      *) yellow "无效选项" ;;
    esac
  done
}

dependency_present() {
  local name="$1"

  case "${name}" in
    acme.sh) [ -x "${ACME_SH}" ] ;;
    xray-core) [ -x "${XRAY_BIN}" ] ;;
    hysteria2-core) [ -x "${HYSTERIA_BIN}" ] ;;
    *) base_dependency_present "${name}" ;;
  esac
}

dependency_display_name() {
  local name="$1"

  case "${name}" in
    xray-core) printf 'Xray-core\n' ;;
    hysteria2-core) printf 'Hysteria2-core\n' ;;
    *) printf '%s\n' "${name}" ;;
  esac
}

dependency_status_label() {
  local name="$1"

  case "${name}" in
    xray-core)
      if dependency_present "${name}"; then
        printf '\033[32m%s\033[0m\n' "已安装 $(xray_version_label)"
      else
        printf '\033[33m%s\033[0m\n' "未安装"
      fi
      ;;
    hysteria2-core)
      if dependency_present "${name}"; then
        printf '\033[32m%s\033[0m\n' "已安装 $(hysteria_version_label)"
      else
        printf '\033[33m%s\033[0m\n' "未安装"
      fi
      ;;
    *)
      if dependency_present "${name}"; then
        printf '\033[32m%s\033[0m\n' "已安装"
      else
        printf '\033[33m%s\033[0m\n' "未安装"
      fi
      ;;
  esac
}

show_dependency_menu() {
  local dependencies=()
  local core_components=()
  local index
  local name

  mapfile -t dependencies < <(required_base_packages)
  dependencies+=("acme.sh")
  mapfile -t core_components < <(required_core_components)

  cat <<EOF

依赖检查：
EOF
  for index in "${!dependencies[@]}"; do
    name="${dependencies[${index}]}"
    printf ' %2d) %-16s %s\n' "$((index + 1))" "$(dependency_display_name "${name}")" "$(dependency_status_label "${name}")"
  done

  cat <<EOF

核心组件：
EOF
  for index in "${!core_components[@]}"; do
    name="${core_components[${index}]}"
    printf ' %2d) %-16s %s\n' "$((index + ${#dependencies[@]} + 1))" "$(dependency_display_name "${name}")" "$(dependency_status_label "${name}")"
  done
  cat <<EOF
  a) 安装全部缺失依赖
  0) 返回
EOF
}

install_core_component_by_name() {
  local name="$1"

  case "${name}" in
    xray-core) install_base_packages; install_xray_binary ;;
    hysteria2-core) install_base_packages; install_hysteria_binary ;;
    *) die "未知核心组件：${name}" ;;
  esac
}

install_dependency_by_name() {
  local name="$1"

  case "${name}" in
    acme.sh) install_acme_sh ;;
    xray-core|hysteria2-core) install_core_component_by_name "${name}" ;;
    curl|openssl|ca-certificates|iproute2|dnsutils|unzip|jq) install_base_package "${name}" ;;
    *) die "未知依赖：${name}" ;;
  esac
}

install_missing_dependencies() {
  local package

  while IFS= read -r package; do
    if ! dependency_present "${package}"; then
      install_dependency_by_name "${package}"
    fi
  done < <(required_base_packages)

  if ! dependency_present "acme.sh"; then
    install_dependency_by_name "acme.sh"
  fi
  green "依赖检查完成"
}

dependency_menu() {
  local choice
  local dependencies=()
  local core_components=()
  local selected

  require_linux
  mapfile -t dependencies < <(required_base_packages)
  dependencies+=("acme.sh")
  mapfile -t core_components < <(required_core_components)
  dependencies+=("${core_components[@]}")

  while true; do
    show_dependency_menu
    printf '请选择要安装的依赖编号 [0-%s/a]: ' "${#dependencies[@]}" >&2
    read_input choice
    choice="${choice:-0}"
    case "${choice}" in
      0) return 0 ;;
      a|A) require_root; install_missing_dependencies ;;
      *)
        if [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#dependencies[@]}" ]; then
          require_root
          selected="${dependencies[$((choice - 1))]}"
          install_dependency_by_name "${selected}"
        else
          yellow "无效选项"
        fi
        ;;
    esac
  done
}

show_about() {
  cat <<EOF

nat-v2ray ${VERSION}
仓库：${REPO_URL}
命令：nv

面向 NAT VPS 的多协议一键脚本，支持 HY2、Reality、VLESS、VMess、Trojan、Shadowsocks。
EOF
}

running_from_nv_command() {
  local source_path
  local source_real
  local nv_real

  source_path="${BASH_SOURCE[0]}"
  source_real="$(readlink -f "${source_path}" 2>/dev/null || printf '%s' "${source_path}")"
  nv_real="$(readlink -f "${NV_BIN}" 2>/dev/null || printf '%s' "${NV_BIN}")"
  [ "${source_real}" = "${nv_real}" ]
}

control_panel() {
  local choice

  ensure_nv_command
  while true; do
    show_control_panel
    choice="$(prompt_menu_choice '请选择' '1-10' '1')"
    case "${choice}" in
      1) protocol_menu ;;
      2) change_config ;;
      3) view_config ;;
      4) delete_config ;;
      5) runtime_management ;;
      6) update_nv_command ;;
      7) uninstall_nat_v2ray; exit 0 ;;
      8) show_help ;;
      9) other_tools ;;
      10) dependency_menu ;;
      0) exit 0 ;;
      *) yellow "无效选项" ;;
    esac
  done
}

protocol_menu() {
  local choice
  banner
  while true; do
    show_menu
    choice="$(prompt_menu_choice '请输入选项' '1' '1')"
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
      32) trojan_tcp_install ;;
      33) trojan_ws_install ;;
      34) trojan_httpupgrade_install ;;
      35) trojan_grpc_install ;;
      36) trojan_xhttp_install ;;
      37) vless_xhttp_tls_install ;;
      38) vmess_xhttp_tls_install ;;
      39) trojan_xhttp_tls_install ;;
      0) exit 0 ;;
      *) yellow "无效选项" ;;
    esac
  done
}

main() {
  local command="${1:-}"
  local target="${2:-}"

  ensure_nv_command

  case "${command}" in
    add|install|protocol)
      protocol_menu
      ;;
    status|view)
      view_config
      ;;
    i|info)
      profile_info "${target}"
      ;;
    url)
      profile_url "${target}"
      ;;
    qr)
      profile_qr "${target}"
      ;;
    del|delete|rm)
      delete_xray_profile "${target}"
      ;;
    run|runtime)
      runtime_management
      ;;
    test|check)
      xray_test_run
      ;;
    update)
      update_nat_v2ray "${target:-script}"
      ;;
    deps|dependency|dependencies)
      dependency_menu
      ;;
    uninstall)
      uninstall_nat_v2ray
      ;;
    help|-h|--help)
      show_help
      ;;
    "")
      if ! running_from_nv_command; then
        install_base_packages
      fi
      control_panel
      ;;
    panel|menu)
      control_panel
      ;;
    *)
      yellow "未知命令：${command}"
      show_help
      exit 1
      ;;
  esac
}

if [ "${NAT_V2RAY_LIB_ONLY:-0}" != "1" ]; then
  main "$@"
fi
