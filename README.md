# nat-v2ray

NAT VPS 多协议一键脚本。第一版先支持 Hysteria2，后续会继续补 Reality、VLESS WS TLS、Trojan TLS 等协议。

## 当前功能

- 交互式菜单安装
- Hysteria2 服务端安装和 systemd 自启
- 自动生成认证密码、salamander 混淆密码、自签证书
- 自动生成 HY2 分享链接和带 `pinSHA256` 的链接
- 端口占用检测：端口被占用时只提示处理，不默认停用任何服务
- TLS DNS-01 TXT 记录检测工具

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

## HY2 注意事项

HY2 使用 QUIC/UDP。NAT 面板必须把外部端口的 `UDP` 转发到本机端口。

只转发 `TCP` 时，脚本会安装成功，服务也会监听成功，但客户端连接会超时。

## 菜单

```text
1) Hysteria2 (HY2) - 推荐 NAT 机优先使用，UDP
2) Reality - 规划中
3) VLESS WS TLS - 规划中，TLS 将使用 TXT 检测
4) Trojan TLS - 规划中，TLS 将使用 TXT 检测
5) TLS TXT 检测工具
0) 退出
```

## TLS TXT 检测

后续涉及证书签发的协议会走 DNS-01。脚本会显示需要添加的 TXT 记录：

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
