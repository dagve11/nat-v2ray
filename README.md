# nat-v2ray

NAT VPS 多协议一键脚本，重点适配只有端口转发的小鸡。

## 当前功能

- 交互式菜单安装
- Hysteria2 服务端安装和 systemd 自启
- 自动生成认证密码、salamander 混淆密码、自签证书
- 自动生成 HY2 分享链接和带 `pinSHA256` 的链接
- Xray VLESS Reality 安装和分享链接生成
- Xray VLESS TCP / WS 安装和 `vless://` 分享链接生成
- Xray VLESS HTTPUpgrade 安装和 `vless://` 分享链接生成
- Xray VLESS TCP / WS dynamic port 安装和 `vless://` 分享链接生成
- Xray VLESS mKCP / mKCP dynamic port 安装和 `vless://` 分享链接生成
- Xray VLESS XHTTP 安装和分享链接生成
- Xray VLESS XHTTP TLS 安装和分享链接生成
- Xray VLESS TCP TLS 安装和分享链接生成
- Xray VLESS WS TLS 安装和分享链接生成
- Xray VLESS gRPC 安装和分享链接生成
- Xray VLESS gRPC TLS 安装和分享链接生成
- Xray Trojan TCP / WS / HTTPUpgrade / gRPC / XHTTP 安装和分享链接生成
- Xray Trojan XHTTP TLS 安装和分享链接生成
- Xray Trojan TLS 安装和分享链接生成
- Xray Trojan WS TLS / gRPC TLS 安装和分享链接生成
- Xray VMess TCP 安装和 `vmess://` 分享链接生成
- Xray VMess WS 安装和 `vmess://` 分享链接生成
- Xray VMess HTTPUpgrade 安装和 `vmess://` 分享链接生成
- Xray VMess XHTTP 安装和 `vmess://` 分享链接生成
- Xray VMess XHTTP TLS 安装和 `vmess://` 分享链接生成
- Xray VMess TCP / WS dynamic port 安装和 `vmess://` 分享链接生成
- Xray VMess mKCP / mKCP dynamic port 安装和 `vmess://` 分享链接生成
- Xray VMess TCP TLS 安装和 `vmess://` 分享链接生成
- Xray VMess gRPC 安装和 `vmess://` 分享链接生成
- Xray VMess WS TLS / gRPC TLS 安装和 `vmess://` 分享链接生成
- Xray Shadowsocks 安装和 `ss://` 分享链接生成
- 端口占用检测：端口被占用时只提示处理，不默认停用任何服务
- TLS DNS-01 手动 TXT 验证和检测工具

## 快速使用

在 Debian/Ubuntu NAT 机器上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dagve11/nat-v2ray/main/install.sh)
```

或者：

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/dagve11/nat-v2ray/main/install.sh
bash install.sh
```

如果服务器无法访问 `raw.githubusercontent.com`，可以用 GitHub SSH/HTTPS 克隆后执行：

```bash
git clone https://github.com/dagve11/nat-v2ray.git
cd nat-v2ray
bash install.sh
```

## HY2 注意事项

HY2、VMess mKCP 和 VLESS mKCP 使用 UDP。NAT 面板必须把外部端口的 `UDP` 转发到本机端口。

只转发 `TCP` 时，脚本会安装成功，服务也会监听成功，但客户端连接会超时。

VMess/VLESS mKCP dynamic port 需要在 NAT 面板转发整个 `UDP` 端口范围，例如 `20000-20010`。

## TCP 协议注意事项

VLESS Reality、VLESS TCP、VLESS WS、VLESS HTTPUpgrade、VLESS XHTTP、VLESS gRPC、VLESS TCP TLS、VLESS WS TLS、VLESS XHTTP TLS、VLESS gRPC TLS、Trojan TCP、Trojan WS、Trojan HTTPUpgrade、Trojan XHTTP、Trojan gRPC、Trojan TLS、Trojan WS TLS、Trojan XHTTP TLS、Trojan gRPC TLS、VMess TCP、VMess WS、VMess HTTPUpgrade、VMess XHTTP、VMess gRPC、VMess TCP TLS、VMess WS TLS、VMess XHTTP TLS、VMess gRPC TLS 使用 TCP。NAT 面板必须把外部端口的 `TCP` 转发到本机端口。

VLESS/VMess TCP/WS dynamic port 需要在 NAT 面板转发整个 `TCP` 端口范围，例如 `20200-20210`。

Reality 不需要申请证书，适合没有域名控制权或不想做 DNS TXT 的场景。

VLESS/VMess/Trojan 的 TLS 类协议会使用 DNS-01 手动 TXT 申请证书，不依赖 80/443 端口。

VLESS TCP / VLESS WS / VLESS HTTPUpgrade / VLESS XHTTP / VLESS gRPC / VMess TCP / VMess WS / VMess HTTPUpgrade / VMess XHTTP / VMess gRPC / Trojan TCP / Trojan WS / Trojan HTTPUpgrade / Trojan XHTTP / Trojan gRPC 默认不带 TLS，适合临时测试或兼容旧客户端；公网长期使用建议优先 HY2、Reality 或 TLS 类协议。

Xray 26.x 已移除旧 HTTP/2 `http` 传输；需要类似 H2/H3 的方向时优先使用 XHTTP / XHTTP TLS。

Shadowsocks 会配置为 `tcp,udp`。如果 NAT 面板只转发 TCP，则 TCP 可用，UDP 不可用。

## 菜单

```text
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
32) Trojan TCP - TCP，不带 TLS
33) Trojan WS - TCP，不带 TLS
34) Trojan HTTPUpgrade - TCP，不带 TLS
35) Trojan gRPC - TCP，不带 TLS
36) Trojan XHTTP - TCP，不带 TLS
37) VLESS XHTTP TLS - TCP，TLS 使用 TXT 检测
38) VMess XHTTP TLS - TCP，TLS 使用 TXT 检测
39) Trojan XHTTP TLS - TCP，TLS 使用 TXT 检测
0) 退出
```

## TLS TXT 检测

涉及证书签发的协议会走 DNS-01。脚本会显示需要添加的 TXT 记录：

```text
_acme-challenge.example.com
```

用户在 DNS 面板添加记录后，脚本会循环检测，检测到目标 TXT 值后继续后续配置。

## 本地测试

```bash
python -m unittest discover -s tests -p 'test_*.py'
```

在 Linux 上可以额外执行：

```bash
bash -n install.sh
```
