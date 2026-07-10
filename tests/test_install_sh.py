import os
import unittest


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
INSTALL_SH = os.path.join(ROOT, "install.sh")


def read_install_script() -> str:
    with open(INSTALL_SH, "r", encoding="utf-8", newline="") as handle:
        return handle.read()


class InstallScriptTests(unittest.TestCase):
    def test_hy2_config_contains_nat_safe_defaults(self) -> None:
        script = read_install_script()

        self.assertIn("render_hy2_config()", script)
        self.assertIn("listen: :${port}", script)
        self.assertIn("type: password", script)
        self.assertIn("password: ${auth_password}", script)
        self.assertIn("type: salamander", script)
        self.assertIn("password: ${obfs_password}", script)
        self.assertIn("rewriteHost: true", script)

    def test_hy2_uri_encodes_query_values(self) -> None:
        script = read_install_script()

        self.assertIn("build_hy2_uri()", script)
        self.assertIn("urlencode()", script)
        self.assertIn("obfs=salamander", script)
        self.assertIn("obfs-password=${encoded_obfs}", script)
        self.assertIn("sni=${encoded_sni}", script)

    def test_tls_txt_record_name_is_predictable(self) -> None:
        script = read_install_script()

        self.assertIn("tls_txt_record_name()", script)
        self.assertIn("_acme-challenge.%s", script)
        self.assertIn('"${domain}"', script)

    def test_menu_advertises_current_and_planned_protocols(self) -> None:
        script = read_install_script()

        self.assertIn("1) HY2-UDP", script)
        self.assertIn("2) VLESS-Reality-TCP", script)
        self.assertIn("3) VLESS-WS-TLS", script)
        self.assertIn("4) Trojan-TCP-TLS", script)
        self.assertIn("5) VMess-TCP", script)
        self.assertIn("6) VMess-WS", script)
        self.assertIn("7) Shadowsocks-TCP/UDP", script)
        self.assertIn("8) VMess-WS-TLS", script)
        self.assertIn("9) VMess-gRPC-TLS", script)
        self.assertIn("10) VLESS-gRPC-TLS", script)
        self.assertIn("11) Trojan-WS-TLS", script)
        self.assertIn("12) Trojan-gRPC-TLS", script)
        self.assertIn("13) VMess-mKCP-UDP", script)
        self.assertIn("14) VMess-mKCP-Dynamic-UDP", script)
        self.assertIn("15) VLESS-TCP", script)
        self.assertIn("16) VLESS-WS", script)
        self.assertIn("17) VLESS-mKCP-UDP", script)
        self.assertIn("18) VLESS-mKCP-Dynamic-UDP", script)
        self.assertIn("19) VMess-TCP-Dynamic", script)
        self.assertIn("20) VMess-WS-Dynamic", script)
        self.assertIn("21) VLESS-TCP-Dynamic", script)
        self.assertIn("22) VLESS-WS-Dynamic", script)
        self.assertIn("23) VLESS-TCP-TLS", script)
        self.assertIn("24) VMess-TCP-TLS", script)
        self.assertIn("25) VLESS-HTTPUpgrade", script)
        self.assertIn("26) VMess-HTTPUpgrade", script)
        self.assertIn("27) VLESS-gRPC", script)
        self.assertIn("28) VMess-gRPC", script)
        self.assertIn("29) VLESS-XHTTP", script)
        self.assertIn("30) VMess-XHTTP", script)
        self.assertIn("31) TLS-TXT-Check", script)
        self.assertIn("32) Trojan-TCP", script)
        self.assertIn("33) Trojan-WS", script)
        self.assertIn("34) Trojan-HTTPUpgrade", script)
        self.assertIn("35) Trojan-gRPC", script)
        self.assertIn("36) Trojan-XHTTP", script)
        self.assertIn("37) VLESS-XHTTP-TLS", script)
        self.assertIn("38) VMess-XHTTP-TLS", script)
        self.assertIn("39) Trojan-XHTTP-TLS", script)
        self.assertNotIn("2) VLESS Reality - TCP，不需要 TLS 证书", script)

    def test_nv_control_panel_is_available(self) -> None:
        script = read_install_script()

        self.assertIn('NV_BIN="/usr/local/bin/nv"', script)
        self.assertIn("install_nv_command()", script)
        self.assertIn("show_control_panel()", script)
        self.assertIn("control_panel()", script)
        self.assertIn("protocol_menu()", script)
        self.assertIn("------------- nat-v2ray ${VERSION} -------------", script)
        self.assertIn("命令: nv", script)
        self.assertIn("1) 添加配置", script)
        self.assertIn("2) 更改配置", script)
        self.assertIn("3) 查看配置", script)
        self.assertIn("4) 删除配置", script)
        self.assertIn("5) 运行管理", script)
        self.assertIn("6) 更新", script)
        self.assertIn("7) 卸载", script)
        self.assertIn("8) 帮助", script)
        self.assertIn("9) 其他", script)
        self.assertIn("10) 关于", script)
        self.assertIn("请选择 [1-10]:", script)
        self.assertIn("add|install|protocol)", script)
        self.assertIn("install -m 0755", script)

    def test_nv_command_is_ensured_before_subcommand_dispatch(self) -> None:
        script = read_install_script()
        main_start = script.rindex("\nmain() {") + 1
        main_end = script.index('if [ "${NAT_V2RAY_LIB_ONLY:-0}" != "1" ]; then', main_start)
        main_body = script[main_start:main_end]

        self.assertIn('ensure_nv_command\n\n  case "${command}" in', main_body)

    def test_nat_install_prompts_for_listen_and_public_ports(self) -> None:
        script = read_install_script()
        install_section = script[script.index("hy2_install()"):script.index("txt_check_tool()")]

        self.assertIn("prompt_nat_port_pair()", script)
        self.assertIn("prompt_nat_port_range_pair()", script)
        self.assertIn("port_range_span()", script)
        self.assertIn("内网端口范围和外网端口范围数量必须一致", script)
        self.assertIn("本机监听端口", script)
        self.assertIn("外网连接端口", script)
        self.assertIn('read -r port public_port < <(prompt_nat_port_pair', install_section)
        self.assertIn('read -r port_range public_port_range < <(prompt_nat_port_range_pair', install_section)
        self.assertNotIn('port="$(prompt_port', install_section)
        self.assertNotIn('port_range="$(prompt_port_range', install_section)

    def test_share_links_use_public_nat_ports(self) -> None:
        script = read_install_script()
        install_section = script[script.index("hy2_install()"):script.index("txt_check_tool()")]

        self.assertIn('normal_uri="$(build_hy2_uri "${server_host}" "${public_port}"', install_section)
        self.assertIn('uri="$(build_reality_uri "${server_host}" "${public_port}"', install_section)
        self.assertIn('uri="$(build_vless_uri "VLESS-TCP-${server_host}" "${server_host}" "${public_port}"', install_section)
        self.assertIn('uri="$(build_vless_uri "VLESS-TCP-dynamic-${server_host}" "${server_host}" "${public_port_range}"', install_section)
        self.assertIn('XRAY_LISTEN_PORT=${port}', install_section)
        self.assertIn('XRAY_PUBLIC_PORT=${public_port}', install_section)
        self.assertIn('HY2_LISTEN_PORT=${port}', install_section)
        self.assertIn('HY2_PUBLIC_PORT=${public_port}', install_section)
        self.assertNotRegex(install_section, r'uri=.*"\$\{port\}"')
        self.assertNotRegex(install_section, r'uri=.*"\$\{port_range\}"')

    def test_reality_supports_xray_config_and_share_uri(self) -> None:
        script = read_install_script()

        self.assertIn("install_xray_binary()", script)
        self.assertIn("render_reality_config()", script)
        self.assertIn('"security": "reality"', script)
        self.assertIn('"flow": "xtls-rprx-vision"', script)
        self.assertIn("build_reality_uri()", script)
        self.assertIn("pbk=%s", script)
        self.assertIn("sid=%s", script)
        self.assertIn('"${encoded_public_key}"', script)
        self.assertIn('"${encoded_short_id}"', script)
        self.assertIn("/PrivateKey:/", script)
        self.assertIn("/Password \\(PublicKey\\):/", script)

    def test_tls_protocols_use_manual_txt_certificate_flow(self) -> None:
        script = read_install_script()

        self.assertIn("install_acme_sh()", script)
        self.assertIn("request_tls_cert_manual_dns()", script)
        self.assertIn("--yes-I-know-dns-manual-mode-enough-go-ahead-please", script)
        self.assertIn("wait_for_txt_record", script)
        self.assertIn("render_vless_tcp_tls_config()", script)
        self.assertIn("render_vless_ws_tls_config()", script)
        self.assertIn("render_vmess_tcp_tls_config()", script)
        self.assertIn("render_trojan_tls_config()", script)
        self.assertIn("render_vmess_ws_tls_config()", script)
        self.assertIn("render_vmess_grpc_tls_config()", script)
        self.assertIn("render_vless_grpc_tls_config()", script)
        self.assertIn("render_trojan_ws_tls_config()", script)
        self.assertIn("render_trojan_grpc_tls_config()", script)
        self.assertIn("build_vless_tcp_tls_uri()", script)
        self.assertIn("build_vmess_tcp_tls_link()", script)
        self.assertIn("build_vless_ws_tls_uri()", script)
        self.assertIn("build_trojan_tls_uri()", script)

    def test_vless_plain_protocols_render_xray_configs_and_links(self) -> None:
        script = read_install_script()

        self.assertIn("render_vless_tcp_config()", script)
        self.assertIn("render_vless_ws_config()", script)
        self.assertIn("render_vless_tcp_dynamic_config()", script)
        self.assertIn("render_vless_ws_dynamic_config()", script)
        self.assertIn("render_vless_mkcp_config()", script)
        self.assertIn("render_vless_mkcp_dynamic_config()", script)
        self.assertIn('"protocol": "vless"', script)
        self.assertIn('"decryption": "none"', script)
        self.assertIn('"network": "tcp"', script)
        self.assertIn('"network": "ws"', script)
        self.assertIn('"network": "kcp"', script)
        self.assertIn('"finalmask"', script)
        self.assertIn('"allocate"', script)
        self.assertIn("build_vless_uri()", script)
        self.assertIn("vless://%s@%s:%s", script)
        self.assertIn("encryption=none", script)
        self.assertIn("type=%s", script)
        self.assertIn("seed=%s", script)
        self.assertIn("TCP 端口范围", script)

    def test_vmess_protocols_render_xray_configs_and_links(self) -> None:
        script = read_install_script()

        self.assertIn("render_vmess_tcp_config()", script)
        self.assertIn("render_vmess_ws_config()", script)
        self.assertIn("render_vmess_tcp_dynamic_config()", script)
        self.assertIn("render_vmess_ws_dynamic_config()", script)
        self.assertIn('"protocol": "vmess"', script)
        self.assertIn('"network": "ws"', script)
        self.assertIn("build_vmess_link()", script)
        self.assertIn("base64_no_wrap", script)
        self.assertIn('\\"net\\":\\"tcp\\"', script)
        self.assertIn('\\"net\\":\\"${network}\\"', script)
        self.assertIn("'ws'", script)
        self.assertIn('"allocate"', script)
        self.assertIn('"strategy": "random"', script)
        self.assertIn("TCP 端口范围", script)

    def test_httpupgrade_protocols_render_configs_and_links(self) -> None:
        script = read_install_script()

        self.assertIn("render_vless_httpupgrade_config()", script)
        self.assertIn("render_vmess_httpupgrade_config()", script)
        self.assertIn("vless_httpupgrade_install()", script)
        self.assertIn("vmess_httpupgrade_install()", script)
        self.assertIn('"network": "httpupgrade"', script)
        self.assertIn('"httpupgradeSettings"', script)
        self.assertIn('"path": "${http_path}"', script)
        self.assertIn('"host": "${host_header}"', script)
        self.assertIn("VLESS-HTTPUpgrade", script)
        self.assertIn("type=%s", script)
        self.assertIn('\\"net\\":\\"${network}\\"', script)
        self.assertIn("'httpupgrade'", script)

    def test_vmess_mkcp_protocols_render_configs_and_links(self) -> None:
        script = read_install_script()

        self.assertIn("validate_port_range()", script)
        self.assertIn("prompt_port_range()", script)
        self.assertIn("render_vmess_mkcp_config()", script)
        self.assertIn("render_vmess_mkcp_dynamic_config()", script)
        self.assertIn("normalise_kcp_header_type()", script)
        self.assertIn("render_kcp_finalmask_udp()", script)
        self.assertIn('"network": "kcp"', script)
        self.assertIn('"kcpSettings"', script)
        self.assertIn('"finalmask"', script)
        self.assertIn('"type": "header-${finalmask_header}"', script)
        self.assertIn('"type": "mkcp-aes128gcm"', script)
        self.assertIn('"password": "${seed}"', script)
        self.assertIn('"type": "mkcp-original"', script)
        self.assertIn("render_legacy_kcp_settings()", script)
        self.assertNotIn("mkcp-legacy", script)
        self.assertIn('"allocate"', script)
        self.assertIn('"strategy": "random"', script)
        self.assertIn("'kcp'", script)
        self.assertIn("UDP 端口范围", script)

    def test_shadowsocks_renders_xray_config_and_ss_uri(self) -> None:
        script = read_install_script()

        self.assertIn("render_shadowsocks_config()", script)
        self.assertIn('"protocol": "shadowsocks"', script)
        self.assertIn('"method": "${method}"', script)
        self.assertIn('"password": "${password}"', script)
        self.assertIn("build_shadowsocks_uri()", script)
        self.assertIn("ss://", script)

    def test_tls_ws_grpc_protocols_render_configs_and_links(self) -> None:
        script = read_install_script()

        self.assertIn("render_vmess_ws_tls_config()", script)
        self.assertIn("render_vmess_grpc_tls_config()", script)
        self.assertIn("render_vless_grpc_tls_config()", script)
        self.assertIn("render_trojan_ws_tls_config()", script)
        self.assertIn("render_trojan_grpc_tls_config()", script)
        self.assertIn('"network": "grpc"', script)
        self.assertIn('"grpcSettings"', script)
        self.assertIn('"serviceName": "${service_name}"', script)
        self.assertIn('"security": "tls"', script)
        self.assertIn("build_vless_grpc_tls_uri()", script)
        self.assertIn("build_trojan_ws_tls_uri()", script)
        self.assertIn("build_trojan_grpc_tls_uri()", script)
        self.assertIn("serviceName=%s", script)
        self.assertIn('\\"tls\\":\\"${tls}\\"', script)
        self.assertIn("'grpc'", script)
        self.assertIn("'tls'", script)

    def test_plain_grpc_protocols_render_configs_and_links(self) -> None:
        script = read_install_script()

        self.assertIn("render_vless_grpc_config()", script)
        self.assertIn("render_vmess_grpc_config()", script)
        self.assertIn("vless_grpc_install()", script)
        self.assertIn("vmess_grpc_install()", script)
        self.assertIn('"network": "grpc"', script)
        self.assertIn('"security": "none"', script)
        self.assertIn('"grpcSettings"', script)
        self.assertIn('"serviceName": "${service_name}"', script)
        self.assertIn("build_vless_grpc_uri()", script)
        self.assertIn("security=none&type=grpc", script)
        self.assertIn("build_vmess_link", script)
        self.assertIn("'grpc'", script)

    def test_xhttp_protocols_render_configs_and_links(self) -> None:
        script = read_install_script()

        self.assertIn("render_vless_xhttp_config()", script)
        self.assertIn("render_vmess_xhttp_config()", script)
        self.assertIn("vless_xhttp_install()", script)
        self.assertIn("vmess_xhttp_install()", script)
        self.assertIn('"network": "xhttp"', script)
        self.assertIn('"xhttpSettings"', script)
        self.assertIn('"path": "${xhttp_path}"', script)
        self.assertIn('"mode": "${xhttp_mode}"', script)
        self.assertIn("build_vless_xhttp_uri()", script)
        self.assertIn("security=none&type=xhttp", script)
        self.assertIn("'xhttp'", script)

    def test_trojan_plain_protocols_render_configs_and_links(self) -> None:
        script = read_install_script()

        self.assertIn("render_trojan_tcp_config()", script)
        self.assertIn("render_trojan_ws_config()", script)
        self.assertIn("render_trojan_httpupgrade_config()", script)
        self.assertIn("render_trojan_grpc_config()", script)
        self.assertIn("render_trojan_xhttp_config()", script)
        self.assertIn("trojan_tcp_install()", script)
        self.assertIn("trojan_ws_install()", script)
        self.assertIn("trojan_httpupgrade_install()", script)
        self.assertIn("trojan_grpc_install()", script)
        self.assertIn("trojan_xhttp_install()", script)
        self.assertIn('"protocol": "trojan"', script)
        self.assertIn('"security": "none"', script)
        self.assertIn('"httpupgradeSettings"', script)
        self.assertIn('"grpcSettings"', script)
        self.assertIn('"xhttpSettings"', script)
        self.assertIn("build_trojan_uri()", script)
        self.assertIn("trojan://%s@%s:%s?security=none&type=%s", script)
        self.assertIn("Trojan-XHTTP", script)

    def test_xhttp_tls_protocols_use_txt_certificate_flow(self) -> None:
        script = read_install_script()

        self.assertIn("render_vless_xhttp_tls_config()", script)
        self.assertIn("render_vmess_xhttp_tls_config()", script)
        self.assertIn("render_trojan_xhttp_tls_config()", script)
        self.assertIn("vless_xhttp_tls_install()", script)
        self.assertIn("vmess_xhttp_tls_install()", script)
        self.assertIn("trojan_xhttp_tls_install()", script)
        self.assertIn('"network": "xhttp"', script)
        self.assertIn('"security": "tls"', script)
        self.assertIn('"xhttpSettings"', script)
        self.assertIn('"mode": "${xhttp_mode}"', script)
        self.assertIn("request_tls_cert_manual_dns", script)
        self.assertIn("build_vless_xhttp_tls_uri()", script)
        self.assertIn("build_trojan_xhttp_tls_uri()", script)
        self.assertIn("security=tls&type=xhttp", script)
        self.assertIn("XHTTP-TLS", script)

    def test_port_conflict_prompt_is_not_caddy_specific(self) -> None:
        script = read_install_script()

        self.assertIn("show_port_usage", script)
        self.assertIn("我确认要停用占用端口的 systemd 服务", script)
        self.assertIn("请输入要停用的 systemd 服务名", script)
        self.assertNotIn("caddy", script.lower())

    def test_xray_profiles_enable_multiple_configs_without_caddy(self) -> None:
        script = read_install_script()

        self.assertIn('XRAY_PROFILE_DIR="${XRAY_CONFIG_DIR}/profiles"', script)
        self.assertIn("xray_profile_name()", script)
        self.assertIn("register_xray_profile()", script)
        self.assertIn("rebuild_xray_config()", script)
        self.assertIn("append_xray_uri_and_register()", script)
        self.assertIn("XRAY_PROFILE_NAME=", script)
        self.assertIn("XRAY_URI=", script)
        self.assertIn('(.inbounds[]?.tag) = $tag', script)
        self.assertIn("jq -s", script)
        self.assertIn("每个 Xray 节点会保存为独立 profile", script)
        self.assertNotIn("caddy", script.lower())

    def test_nv_shortcuts_manage_profiles_and_links(self) -> None:
        script = read_install_script()

        self.assertIn("profile_info()", script)
        self.assertIn("profile_url()", script)
        self.assertIn("profile_qr()", script)
        self.assertIn("delete_xray_profile()", script)
        self.assertIn("select_xray_profile()", script)
        self.assertIn("nv info [name]", script)
        self.assertIn("nv url [name]", script)
        self.assertIn("nv qr [name]", script)
        self.assertIn("nv del [name]", script)
        self.assertIn("info)", script)
        self.assertIn("url)", script)
        self.assertIn("qr)", script)
        self.assertIn("del|delete|rm)", script)

    def test_nv_install_does_not_copy_process_substitution_fd(self) -> None:
        script = read_install_script()
        install_start = script.index("install_nv_command()")
        install_end = script.index("\nensure_nv_command()", install_start)
        install_body = script[install_start:install_end]

        self.assertIn('[ -f "${source_path}" ] && [ -r "${source_path}" ]', install_body)
        self.assertIn('curl -fsSL -o "${NV_BIN}" "${SCRIPT_URL}"', install_body)

    def test_base_packages_are_detected_before_installing_missing_packages(self) -> None:
        script = read_install_script()
        install_start = script.index("base_dependency_present()")
        install_end = script.index("\nhysteria_asset_name()", install_start)
        install_body = script[install_start:install_end]

        self.assertIn("local required_packages=(curl openssl ca-certificates iproute2 dnsutils unzip jq)", install_body)
        self.assertIn('base_dependency_present "${package}"', install_body)
        self.assertIn('missing_packages+=("${package}")', install_body)
        self.assertIn('if [ "${#missing_packages[@]}" -eq 0 ]; then', install_body)
        self.assertIn('apt-get install -y "${missing_packages[@]}"', install_body)
        self.assertIn("apt-get update", install_body)
        self.assertLess(
            install_body.index('apt-get install -y "${missing_packages[@]}"'),
            install_body.index("apt-get update"),
        )
        self.assertNotIn("apt-get install -y curl openssl ca-certificates iproute2 dnsutils unzip jq", install_body)

    def test_no_arg_bash_checks_dependencies_and_opens_panel_without_default_node_install(self) -> None:
        script = read_install_script()
        main_start = script.index("\nmain()") + 1
        main_end = script.index('\nif [ "${NAT_V2RAY_LIB_ONLY:-0}"', main_start)
        main_body = script[main_start:main_end]

        self.assertIn('    "")', main_body)
        self.assertIn("if ! running_from_nv_command; then", main_body)
        self.assertIn("install_base_packages", main_body)
        self.assertIn("control_panel", main_body)
        self.assertIn("panel|menu)", main_body)
        self.assertNotIn("first_install_wizard()", script)
        self.assertNotIn("prompt_first_install_hy2_ports()", script)
        self.assertNotIn("首次安装默认优先 HY2-UDP", script)
        self.assertNotIn("未填写 HY2 UDP 端口，改用 VLESS-Reality-TCP", script)

    def test_hy2_install_accepts_first_run_nat_ports(self) -> None:
        script = read_install_script()
        hy2_start = script.index("hy2_install()")
        hy2_end = script.index("\nreality_install()", hy2_start)
        hy2_body = script[hy2_start:hy2_end]

        self.assertIn('local port="${1:-}"', hy2_body)
        self.assertIn('local public_port="${2:-}"', hy2_body)
        self.assertIn('if [ -z "${port}" ] || [ -z "${public_port}" ]; then', hy2_body)
        self.assertIn("prompt_nat_port_pair '请输入 HY2 UDP 端口，必须在 NAT 面板转发 UDP'", hy2_body)

    def test_view_config_shows_node_summary_and_urls_like_233boy(self) -> None:
        script = read_install_script()
        view_start = script.index("view_config()")
        view_end = script.index("\nchange_config()", view_start)
        view_body = script[view_start:view_end]

        self.assertIn("hy2_info()", script)
        self.assertIn("HY2-UDP", script)
        self.assertIn("------------- URL -------------", script)
        self.assertIn("带 pinSHA256", script)
        self.assertIn('profile_info "${profile}"', view_body)
        self.assertIn("hy2_info", view_body)
        self.assertNotIn('print_file_if_exists "Xray 环境"', view_body)
        self.assertNotIn('print_file_if_exists "HY2 配置"', view_body)

    def test_hy2_outputs_pinned_link_before_insecure_compat_link(self) -> None:
        script = read_install_script()
        hy2_info_start = script.index("hy2_info()")
        hy2_info_end = script.index("\ndelete_xray_profile()", hy2_info_start)
        hy2_info_body = script[hy2_info_start:hy2_info_end]
        hy2_install_start = script.index("hy2_install()")
        hy2_install_end = script.index("\nreality_install()", hy2_install_start)
        hy2_install_body = script[hy2_install_start:hy2_install_end]

        self.assertIn("推荐链接（v2rayN 7.23+，带 pinSHA256）", hy2_info_body)
        self.assertIn("兼容链接（旧客户端，insecure=1）", hy2_info_body)
        self.assertLess(
            hy2_info_body.index("推荐链接（v2rayN 7.23+，带 pinSHA256）"),
            hy2_info_body.index("兼容链接（旧客户端，insecure=1）"),
        )
        self.assertIn("推荐链接（v2rayN 7.23+，带 pinSHA256）", hy2_install_body)
        self.assertIn("兼容链接（旧客户端，insecure=1）", hy2_install_body)
        self.assertLess(
            hy2_install_body.index("推荐链接（v2rayN 7.23+，带 pinSHA256）"),
            hy2_install_body.index("兼容链接（旧客户端，insecure=1）"),
        )

    def test_interactive_reads_use_readline_backspace_compatibility(self) -> None:
        script = read_install_script()

        self.assertIn("configure_readline_keys()", script)
        self.assertIn("read_input()", script)
        self.assertIn('"\\C-h": backward-delete-char', script)
        self.assertIn('"\\C-?": backward-delete-char', script)
        self.assertIn("read -r -e", script)
        self.assertIn("read_input value", script)
        self.assertIn("read_input port", script)
        self.assertIn("read_input choice", script)
        self.assertIn("read_input service_name", script)
        self.assertNotIn("read -r value", script)
        self.assertNotIn("read -r port\n", script)
        self.assertNotIn("read -r choice", script)
        self.assertNotIn("read -r service_name", script)

    def test_nv_test_and_update_core_geo_are_available(self) -> None:
        script = read_install_script()

        self.assertIn("xray_test_run()", script)
        self.assertIn('"${XRAY_BIN}" run -test -config "${XRAY_CONFIG_FILE}"', script)
        self.assertIn("journalctl -u xray", script)
        self.assertIn("update_xray_core()", script)
        self.assertIn("update_hysteria_core()", script)
        self.assertIn("update_geo_assets()", script)
        self.assertIn("nv update core", script)
        self.assertIn("nv update geo", script)
        self.assertIn("test|check)", script)

    def test_xray_version_compatibility_helpers_exist(self) -> None:
        script = read_install_script()

        self.assertIn("version_ge()", script)
        self.assertIn("xray_core_version_number()", script)
        self.assertIn("is_xray_finalmask_supported()", script)
        self.assertIn("render_kcp_finalmask_udp()", script)
        self.assertIn("render_legacy_kcp_settings()", script)
        self.assertIn("26.1.24", script)

    def test_uninstall_removes_all_owned_files_like_233boy(self) -> None:
        script = read_install_script()
        uninstall_start = script.index("uninstall_nat_v2ray()")
        uninstall_end = script.index("\nshow_help()", uninstall_start)
        uninstall_body = script[uninstall_start:uninstall_end]

        self.assertIn("prompt_required_yes()", script)
        self.assertIn("是否卸载 nat-v2ray? [y]:", uninstall_body)
        self.assertIn("请输入 (y)", script)
        self.assertIn('systemctl disable --now xray', uninstall_body)
        self.assertIn('systemctl disable --now hysteria-server', uninstall_body)
        self.assertIn('rm -rf "${XRAY_CONFIG_DIR}"', uninstall_body)
        self.assertIn('rm -rf "${HY2_CONFIG_DIR}"', uninstall_body)
        self.assertIn('rm -rf /usr/local/share/xray', uninstall_body)
        self.assertIn('rm -rf /var/log/xray', uninstall_body)
        self.assertIn('rm -rf /var/log/hysteria', uninstall_body)
        self.assertIn('rm -f "${XRAY_BIN}" "${HYSTERIA_BIN}" "${NV_BIN}"', uninstall_body)
        self.assertIn('rm -f "${XRAY_SERVICE_FILE}" "${HY2_SERVICE_FILE}"', uninstall_body)
        self.assertIn('rm -f /lib/systemd/system/xray.service', uninstall_body)
        self.assertIn('rm -f /etc/init.d/xray', uninstall_body)
        self.assertIn('sed -i', uninstall_body)
        self.assertIn('/root/.bashrc', uninstall_body)
        self.assertIn('systemctl daemon-reload', uninstall_body)
        self.assertIn("卸载完成", uninstall_body)
        self.assertIn("反馈问题", uninstall_body)

    def test_control_panel_exits_after_uninstall(self) -> None:
        script = read_install_script()
        panel_start = script.index("\ncontrol_panel()") + 1
        panel_end = script.index("\nprotocol_menu()", panel_start)
        panel_body = script[panel_start:panel_end]

        self.assertIn("7) uninstall_nat_v2ray; exit 0 ;;", panel_body)

    def test_control_panel_does_not_print_top_banner(self) -> None:
        script = read_install_script()
        panel_start = script.index("\ncontrol_panel()") + 1
        panel_end = script.index("\nprotocol_menu()", panel_start)
        panel_body = script[panel_start:panel_end]
        protocol_start = script.index("\nprotocol_menu()") + 1
        protocol_end = script.index("\nmain()", protocol_start)
        protocol_body = script[protocol_start:protocol_end]

        self.assertNotIn("\n  banner\n", panel_body)
        self.assertIn("show_control_panel", panel_body)
        self.assertIn("\n  banner\n", protocol_body)


if __name__ == "__main__":
    unittest.main()
