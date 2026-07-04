# nat-v2ray

面向 NAT VPS 的多协议一键脚本，适合只有端口转发、没有完整公网端口控制权的机器。

脚本重点解决三件事：

- 交互式安装 HY2、Reality、VLESS、VMess、Trojan、Shadowsocks 等协议
- 自动生成服务端配置、systemd 服务和分享链接
- TLS 协议使用 DNS-01 手动 TXT 验证，不依赖 80/443 入站端口

## 快速使用

在 Debian/Ubuntu NAT 机器上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dagve11/nat-v2ray/main/install.sh)
```

不想使用 `bash <(...)` 时，可以先下载再执行：

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/dagve11/nat-v2ray/main/install.sh
bash install.sh
```

首次运行后脚本会安装/修复 `nv` 命令。之后可以直接输入：

```bash
nv
```

如果服务器无法访问 `raw.githubusercontent.com`，可以克隆仓库后执行：

```bash
git clone https://github.com/dagve11/nat-v2ray.git
cd nat-v2ray
bash install.sh
```

## 怎么选

| 场景 | 推荐 |
| --- | --- |
| NAT 面板有 UDP 转发 | Hysteria2 |
| 只有 TCP 转发，不想管证书 | VLESS Reality |
| 有域名，能添加 DNS TXT | VLESS / VMess / Trojan 的 TLS 类协议 |
| 只想快速测试 TCP | VLESS / VMess / Trojan 的 TCP、WS、gRPC、HTTPUpgrade、XHTTP |
| 需要端口范围 | VLESS / VMess dynamic port 或 mKCP dynamic port |
| 兼容 Shadowsocks 客户端 | Shadowsocks |

公网长期使用优先选择 `HY2`、`Reality` 或 TLS 类协议。非 TLS 的 TCP/WS/gRPC/HTTPUpgrade/XHTTP 更适合临时测试或兼容旧客户端。

## nv 总控台

`nv` 会打开 233boy 风格的总控台：

```text
------------- nat-v2ray 0.15.0 -------------
Xray 26.3.27: running
Hysteria2: not installed
命令: nv
仓库: https://github.com/dagve11/nat-v2ray

 1) 添加配置
 2) 更改配置
 3) 查看配置
 4) 删除配置
 5) 运行管理
 6) 更新
 7) 卸载
 8) 帮助
 9) 其他
10) 关于
 0) 退出
```

常用子命令：

```bash
nv add        # 添加配置，进入协议菜单
nv status     # 查看当前配置和服务状态
nv run        # 启动、停止、重启服务
nv update     # 更新 nv 命令
nv uninstall  # 卸载 nat-v2ray
```

## 支持协议

| 类型 | 协议 |
| --- | --- |
| UDP | Hysteria2、VLESS mKCP、VMess mKCP |
| TCP 无 TLS | VLESS TCP / WS / gRPC / HTTPUpgrade / XHTTP |
| TCP 无 TLS | VMess TCP / WS / gRPC / HTTPUpgrade / XHTTP |
| TCP 无 TLS | Trojan TCP / WS / gRPC / HTTPUpgrade / XHTTP |
| TCP TLS | VLESS TCP TLS / WS TLS / gRPC TLS / XHTTP TLS |
| TCP TLS | VMess TCP TLS / WS TLS / gRPC TLS / XHTTP TLS |
| TCP TLS | Trojan TLS / WS TLS / gRPC TLS / XHTTP TLS |
| Dynamic port | VLESS TCP / WS dynamic port、VMess TCP / WS dynamic port |
| Dynamic port | VLESS mKCP dynamic port、VMess mKCP dynamic port |
| 其他 | VLESS Reality、Shadowsocks |

Xray 26.x 已移除旧 HTTP/2 `http` 传输；需要类似 H2/H3 的方向时优先使用 XHTTP / XHTTP TLS。

## NAT 转发规则

脚本能安装服务并生成链接，但 NAT 面板仍然必须正确转发端口。

| 协议类型 | NAT 面板要转发 |
| --- | --- |
| HY2 | UDP 单端口 |
| VLESS / VMess mKCP | UDP 单端口 |
| VLESS / VMess mKCP dynamic port | UDP 端口范围 |
| Reality、TCP、WS、gRPC、HTTPUpgrade、XHTTP、TLS | TCP 单端口 |
| VLESS / VMess TCP/WS dynamic port | TCP 端口范围 |
| Shadowsocks | 建议 TCP + UDP；只转发 TCP 时 UDP 不可用 |

端口被占用时，脚本只显示占用信息，不会默认停用 Caddy、Nginx 或其他服务。需要停用服务时，用户必须手动输入 systemd 服务名确认。

## TLS TXT 流程

涉及证书签发的协议会走 DNS-01 手动 TXT 验证。

脚本会显示需要添加的 TXT 记录，例如：

```text
_acme-challenge.example.com
```

用户在 DNS 面板添加记录后，脚本会循环检测 TXT 值。检测通过后，脚本继续申请证书、写入 Xray 配置并启动服务。

TLS 相关配置不做真实连通测试，因为证书签发依赖用户的 DNS TXT 操作；脚本只做 TXT 检测和后续自动配置。

## 菜单

```text
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
```

## 本地检查

```bash
python -m unittest discover -s tests -p 'test_*.py'
```

在 Linux 上可以额外执行：

```bash
bash -n install.sh
```
