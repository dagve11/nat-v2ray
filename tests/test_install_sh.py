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

        self.assertIn("1) Hysteria2", script)
        self.assertIn("2) VLESS Reality", script)
        self.assertIn("3) VLESS WS TLS", script)
        self.assertIn("4) Trojan TLS", script)
        self.assertIn("5) VMess TCP", script)
        self.assertIn("6) VMess WS", script)
        self.assertIn("7) Shadowsocks", script)
        self.assertIn("TXT", script)

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
        self.assertIn("render_vless_ws_tls_config()", script)
        self.assertIn("render_trojan_tls_config()", script)
        self.assertIn("build_vless_ws_tls_uri()", script)
        self.assertIn("build_trojan_tls_uri()", script)

    def test_vmess_protocols_render_xray_configs_and_links(self) -> None:
        script = read_install_script()

        self.assertIn("render_vmess_tcp_config()", script)
        self.assertIn("render_vmess_ws_config()", script)
        self.assertIn('"protocol": "vmess"', script)
        self.assertIn('"network": "ws"', script)
        self.assertIn("build_vmess_link()", script)
        self.assertIn("base64_no_wrap", script)
        self.assertIn('\\"net\\":\\"tcp\\"', script)
        self.assertIn('\\"net\\":\\"ws\\"', script)

    def test_shadowsocks_renders_xray_config_and_ss_uri(self) -> None:
        script = read_install_script()

        self.assertIn("render_shadowsocks_config()", script)
        self.assertIn('"protocol": "shadowsocks"', script)
        self.assertIn('"method": "${method}"', script)
        self.assertIn('"password": "${password}"', script)
        self.assertIn("build_shadowsocks_uri()", script)
        self.assertIn("ss://", script)

    def test_port_conflict_prompt_is_not_caddy_specific(self) -> None:
        script = read_install_script()

        self.assertIn("show_port_usage", script)
        self.assertIn("我确认要停用占用端口的 systemd 服务", script)
        self.assertIn("请输入要停用的 systemd 服务名", script)
        self.assertNotIn("caddy", script.lower())


if __name__ == "__main__":
    unittest.main()
