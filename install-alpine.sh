#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
  if ! command -v bash >/dev/null 2>&1; then
    if [ "$(id -u)" -ne 0 ]; then
      echo "错误：Alpine 默认可能没有 bash，请使用 root 先安装 bash：apk add --no-cache bash" >&2
      exit 1
    fi
    apk add --no-cache bash
  fi
  exec bash "$0" "$@"
fi

set -Eeuo pipefail

ALPINE_SOURCE="${BASH_SOURCE[0]}"
ALPINE_DIR="$(cd "$(dirname "${ALPINE_SOURCE}")" && pwd)"
ALPINE_LIB_DIR="/usr/local/lib/nat-v2ray"
MAIN_SCRIPT="${ALPINE_DIR}/install.sh"
if [ ! -f "${MAIN_SCRIPT}" ] && [ -f "${ALPINE_LIB_DIR}/install.sh" ]; then
  MAIN_SCRIPT="${ALPINE_LIB_DIR}/install.sh"
fi

if [ ! -f "${MAIN_SCRIPT}" ]; then
  MAIN_SCRIPT="/tmp/nat-v2ray-alpine-main/install.sh"
  mkdir -p "$(dirname "${MAIN_SCRIPT}")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/dagve11/nat-v2ray/main/install.sh -o "${MAIN_SCRIPT}"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${MAIN_SCRIPT}" https://raw.githubusercontent.com/dagve11/nat-v2ray/main/install.sh
  else
    echo "错误：未找到 install.sh，且系统缺少 curl/wget，无法自动下载主脚本" >&2
    exit 1
  fi
fi

NAT_V2RAY_LIB_ONLY=1 source "${MAIN_SCRIPT}"

SCRIPT_URL="https://raw.githubusercontent.com/dagve11/nat-v2ray/main/install-alpine.sh"
XRAY_SERVICE_FILE="/etc/init.d/xray"
HY2_SERVICE_FILE="/etc/init.d/hysteria-server"

require_alpine() {
  require_linux
  if [ ! -f /etc/alpine-release ]; then
    die "当前脚本仅支持 Alpine Linux"
  fi
}

require_linux() {
  if [ "$(uname -s)" != "Linux" ]; then
    die "当前脚本只支持 Linux 服务器"
  fi
}

alpine_package_for_dependency() {
  local package="$1"

  case "${package}" in
    dnsutils) printf 'bind-tools\n' ;;
    *) printf '%s\n' "${package}" ;;
  esac
}

base_dependency_present() {
  local package="$1"

  case "${package}" in
    curl) command -v curl >/dev/null 2>&1 ;;
    openssl) command -v openssl >/dev/null 2>&1 ;;
    ca-certificates) [ -f /etc/ssl/certs/ca-certificates.crt ] ;;
    iproute2) command -v ip >/dev/null 2>&1 && command -v ss >/dev/null 2>&1 ;;
    dnsutils) command -v dig >/dev/null 2>&1 ;;
    unzip) command -v unzip >/dev/null 2>&1 ;;
    jq) command -v jq >/dev/null 2>&1 ;;
    *) apk info -e "$(alpine_package_for_dependency "${package}")" >/dev/null 2>&1 ;;
  esac
}

install_base_package() {
  local package="$1"
  local apk_package

  require_root
  require_alpine
  apk_package="$(alpine_package_for_dependency "${package}")"
  if base_dependency_present "${package}"; then
    green "依赖已安装：${package}"
    return 0
  fi

  yellow "安装依赖：${package}"
  apk add --no-cache "${apk_package}"
}

install_base_packages() {
  local required_packages=()
  local missing_packages=()
  local package
  local apk_packages=()

  require_alpine
  mapfile -t required_packages < <(required_base_packages)
  for package in "${required_packages[@]}"; do
    if ! base_dependency_present "${package}"; then
      missing_packages+=("${package}")
      apk_packages+=("$(alpine_package_for_dependency "${package}")")
    fi
  done

  if [ "${#missing_packages[@]}" -eq 0 ]; then
    return 0
  fi

  yellow "安装缺失基础依赖：${missing_packages[*]}"
  apk add --no-cache "${apk_packages[@]}"
}

write_xray_service() {
  mkdir -p "${XRAY_CONFIG_DIR}" /run /var/log/xray
  cat > "${XRAY_SERVICE_FILE}" <<EOF
#!/sbin/openrc-run
name="xray"
description="Xray Service"
command="${XRAY_BIN}"
command_args="run -config ${XRAY_CONFIG_FILE}"
command_background="yes"
pidfile="/run/xray.pid"
output_log="/var/log/xray/xray.log"
error_log="/var/log/xray/xray.log"

depend() {
  need net
}
EOF
  chmod +x "${XRAY_SERVICE_FILE}"
}

write_hy2_service() {
  mkdir -p "${HY2_CONFIG_DIR}" /run /var/log/hysteria
  cat > "${HY2_SERVICE_FILE}" <<EOF
#!/sbin/openrc-run
name="hysteria-server"
description="Hysteria2 Server"
command="${HYSTERIA_BIN}"
command_args="server -c ${HY2_CONFIG_FILE}"
command_background="yes"
pidfile="/run/hysteria-server.pid"
output_log="/var/log/hysteria/hysteria-server.log"
error_log="/var/log/hysteria/hysteria-server.log"

depend() {
  need net
}
EOF
  chmod +x "${HY2_SERVICE_FILE}"
}

systemctl() {
  local action="${1:-}"
  local service_name

  case "${action}" in
    daemon-reload|reset-failed)
      return 0
      ;;
    is-active)
      service_name="${2:-}"
      if rc-service "${service_name}" status >/dev/null 2>&1; then
        printf 'active\n'
      else
        printf 'inactive\n'
      fi
      ;;
    enable)
      if [ "${2:-}" = "--now" ]; then
        service_name="${3:-}"
        rc-update add "${service_name}" default >/dev/null 2>&1 || true
        rc-service "${service_name}" start
      else
        service_name="${2:-}"
        rc-update add "${service_name}" default
      fi
      ;;
    disable)
      if [ "${2:-}" = "--now" ]; then
        service_name="${3:-}"
        rc-service "${service_name}" stop >/dev/null 2>&1 || true
        rc-update del "${service_name}" default >/dev/null 2>&1 || true
      else
        service_name="${2:-}"
        rc-update del "${service_name}" default
      fi
      ;;
    start|stop|restart)
      service_name="${2:-}"
      rc-service "${service_name}" "${action}"
      ;;
    *)
      die "未知 OpenRC 操作：systemctl ${*}"
      ;;
  esac
}

journalctl() {
  local unit=""
  local line

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -u) unit="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done

  case "${unit}" in
    xray) line="/var/log/xray/xray.log" ;;
    hysteria-server) line="/var/log/hysteria/hysteria-server.log" ;;
    *) return 0 ;;
  esac
  [ -f "${line}" ] && tail -n 80 "${line}"
}

ensure_nv_command() {
  local source_path="${ALPINE_SOURCE}"

  require_root
  mkdir -p "${ALPINE_LIB_DIR}"
  install -m 0644 "${MAIN_SCRIPT}" "${ALPINE_LIB_DIR}/install.sh"
  install -m 0755 "${source_path}" "${NV_BIN}"
}

update_nv_command() {
  local temp_file
  local temp_main

  require_root
  require_alpine

  temp_file="${NV_BIN}.tmp.$$"
  temp_main="${ALPINE_LIB_DIR}/install.sh.tmp.$$"
  mkdir -p "${ALPINE_LIB_DIR}"
  curl -fsSL -o "${temp_file}" "${SCRIPT_URL}" || die "下载 Alpine 脚本更新失败"
  curl -fsSL -o "${temp_main}" "https://raw.githubusercontent.com/dagve11/nat-v2ray/main/install.sh" || die "下载主脚本更新失败"
  install -m 0755 "${temp_file}" "${NV_BIN}"
  install -m 0644 "${temp_main}" "${ALPINE_LIB_DIR}/install.sh"
  rm -f "${temp_file}" "${temp_main}"
  green "nv 已更新：${NV_BIN}"
}

running_from_nv_command() {
  local source_real
  local nv_real

  source_real="$(readlink -f "${ALPINE_SOURCE}" 2>/dev/null || printf '%s' "${ALPINE_SOURCE}")"
  nv_real="$(readlink -f "${NV_BIN}" 2>/dev/null || printf '%s' "${NV_BIN}")"
  [ "${source_real}" = "${nv_real}" ]
}

banner() {
  cat <<EOF
============================================================
 ${PROJECT_NAME} ${VERSION}
 NAT VPS 多协议一键脚本 - Alpine/OpenRC
============================================================
EOF
}

main "$@"
