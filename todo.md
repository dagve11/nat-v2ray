# `nv` 现有节点编辑 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` or `executing-plans` to implement this plan task by task. Track progress with the checkboxes below.

**Goal:** 把面板 `2) 更改配置` 实现为真正的原地编辑：选择现有 Xray profile 或 HY2 实例，所有字段默认显示当前值，回车保持不变，只提交目标节点的修改。

**Architecture:** 继续复用现有 38 个安装函数负责交互和渲染，但编辑时在临时目录运行，屏蔽服务写入和重启；候选配置验证通过后再原子替换真实文件，并且最多重启一次。编辑上下文只在子 shell 中保存 env 文件路径、目标类型和 profile 名，不批量导出 env 字段。

**Tech Stack:** Bash、Xray-core、Hysteria2、jq、systemd/OpenRC、Python `unittest`。

---

## 0. 范围与边界

本计划只涉及以下现有文件：

- Modify: `install.sh`
- Modify: `tests/test_install_sh.py`
- Modify: `README.md`
- Verify only: `install-alpine.sh`

不新增依赖，不改目录结构，不新增数据库或外部 API，不自动提交、推送或部署。Git commit/push 只在用户另行明确要求后执行。

## 1. 已验证基线（2026-08-01）

- 基线提交：`38dc7cd`。
- `install.sh` 当前 6965 行；使用函数名定位修改，不依赖容易漂移的绝对行号。
- `change_config()` 当前只是提示后进入 `protocol_menu()`，并没有编辑能力。
- 实际共有 38 个安装函数：37 个 Xray 安装函数 + `hy2_install`。
- 协议菜单有 39 项，是因为 `31) TLS-TXT-Check` 是工具，不是安装函数。
- `PROTOCOL=` 恰好有 37 个不重复值；原规格中的 37 项协议映射实际上已经完整。
- 当前 env heredoc 已保存所有交互字段，不需要扩展或重命名 schema。
- 当前测试共 49 项，已执行：

```text
Ran 49 tests
OK
```

- 当前测试主要是源码静态断言，没有执行真实的 Bash 编辑流程；新功能必须补行为测试。
- `bash -n install.sh` 已通过；当前 Windows 环境的 Git Bash 位于 `E:/Git/bin/bash.exe`。

### 必须废弃的旧假设

| 旧假设 | 已验证事实 | 决策 |
| --- | --- | --- |
| 需要扩全 env heredoc | WS、HTTPUpgrade、gRPC、XHTTP、mKCP、Trojan、SS 等字段均已保存 | 保留现有 key，禁止另造 `XRAY_WS_PATH` 等新 key |
| 共有 39 个 install 函数 | 实际为 38 个，另有 1 个 TXT 工具 | Xray 映射严格覆盖 37 个 `PROTOCOL` |
| `NV_EDIT_LISTEN_PORT` 可直接工作 | env 实际是 `XRAY_LISTEN_PORT` 或 `HY2_LISTEN_PORT` | 按目标类型解析真实 key |
| 先停服务可避免端口误判 | 会让全部节点在提示/TXT 等待期间下线，并隐藏其他 profile 的端口冲突 | 收集和渲染阶段不停止服务 |
| HY2 重签证书可接受 | 会改变推荐链接的 `pinSHA256` | host 不变必须复用证书和私钥 |
| TLS 同域已无条件快速复用 | 当前仍先初始化 ACME/账号，之后才询问是否复用 | 编辑态在 ACME 初始化前直接复用有效证书 |
| 改完仍应只有 49 项测试 | 新功能需要新增测试 | 原 49 项回归 + 新增行为测试全部通过 |

## 2. 完成定义

- [ ] `2) 更改配置` 可选择一个现有 Xray profile 或当前 HY2 实例。
- [ ] 所有现有字段均以当前值作为默认值；全程回车不会随机生成新值。
- [ ] 修改 host、端口或协议专属字段后仍覆盖原 profile，profile 名和数量不变。
- [ ] Xray 编辑只改变目标 profile；其他 profile 的 json/env 内容不变，合并配置仍包含全部 inbound。
- [ ] 收集输入、确认和等待 DNS TXT 时，现有服务继续运行。
- [ ] 用户取消、输入失败、渲染失败、配置验证失败或重启失败时，真实配置和原服务状态恢复。
- [ ] 普通 `1) 添加配置` 的默认值、流程和 profile 命名行为不变。
- [ ] Reality 无改动编辑复用原私钥、公钥和 shortId，分享链接不变。
- [ ] HY2 host 不变时复用证书/私钥，`pinSHA256` 和分享链接不变；host 改变时才重签并覆盖正确的 IP/DNS SAN。
- [ ] TLS 域名不变且证书有效时，不初始化 ACME、不注册账号、不进入 TXT 流程；域名改变或证书缺失时走现有 `Enter/r/q` TXT 流程。
- [ ] 未知协议或旧 env 缺少必需字段时，在写入真实文件前给出明确错误，不静默回退到随机值。
- [ ] systemd 与 Alpine/OpenRC 包装入口均不回归。

## 3. 方案比较与最终决策

### A. 先停服务，直接复用安装函数

改动最少，但取消/失败会留下停服状态；停掉整个 Xray 后也无法识别其他 profile 的端口占用。否决。

### B. 在线直改真实文件，失败时用快照回滚

可以恢复失败，但安装函数会先把实时 `config.json` 覆盖为单 inbound 并重启，其他节点会短暂消失。仅作为临时降级方案，不采用。

### C. 临时目录渲染，验证后原子提交

推荐。把真实 profile 复制到临时目录，在子 shell 中覆盖所有输出路径并屏蔽 `systemctl`/service writer；安装函数完成后得到包含全部 profile 的候选配置。验证通过才替换目标文件并重启一次，失败则真实文件完全不动。

## 4. 现有数据契约

不得重命名下列 key；编辑默认值必须直接读取它们。

| 字段组 | 现有 env key | 适用范围 |
| --- | --- | --- |
| Xray 地址/单端口 | `XRAY_HOST`、`XRAY_LISTEN_PORT`、`XRAY_PUBLIC_PORT` | 单端口 Xray 协议 |
| Xray 动态范围 | `XRAY_LISTEN_PORT_RANGE`、`XRAY_PUBLIC_PORT_RANGE` | dynamic / mKCP dynamic |
| UUID | `XRAY_UUID` | VLESS、VMess、Reality |
| WebSocket | `WS_PATH`、`WS_HOST` | 有对应 prompt 的 WS 协议 |
| HTTPUpgrade | `HTTP_PATH`、`HTTP_HOST` | 三类 HTTPUpgrade |
| gRPC | `GRPC_SERVICE_NAME` | 六类 gRPC/gRPC TLS |
| XHTTP | `XHTTP_PATH`、`XHTTP_MODE` | 六类 XHTTP/XHTTP TLS |
| mKCP | `KCP_HEADER_TYPE`、`KCP_SEED` | 四类 mKCP |
| TLS | `TLS_DOMAIN`、`TLS_CERT`、`TLS_KEY` | TLS 协议 |
| Trojan | `TROJAN_PASSWORD` | 全部 Trojan 协议 |
| Shadowsocks | `SS_METHOD`、`SS_PASSWORD` | Shadowsocks |
| Reality | `REALITY_SNI`、`REALITY_DEST`、`REALITY_PRIVATE_KEY`、`REALITY_PUBLIC_KEY`、`REALITY_SHORT_ID` | Reality |
| HY2 | `HY2_HOST`、`HY2_LISTEN_PORT`、`HY2_PUBLIC_PORT`、`HY2_AUTH`、`HY2_OBFS`、`HY2_MASQUERADE` | HY2 |

`XRAY_PORT`、`XRAY_PORT_RANGE` 和 `HY2_PORT` 仅作为已有兼容字段保留，不作为编辑默认值的首选来源。

## 5. 实现任务

### Task 1: 先建立失败测试

**Files:**

- Modify: `tests/test_install_sh.py`
- Test: `tests/test_install_sh.py`

新增测试不能只做 `assertIn`。通过 `NAT_V2RAY_LIB_ONLY=1` source `install.sh`，在临时目录覆盖路径并 mock 外部命令，实际调用编辑 helper、staging 和回滚函数；Python 负责准备 fixture、执行 Bash 子进程并断言退出码与文件内容。

- [ ] **Step 1: 增加编辑上下文与 schema 测试**

覆盖：值含空格/`=` 时按原值读取；缺 key 明确失败；普通新增时使用原默认值；子 shell 结束后没有 `NV_EDIT_*` 泄漏。

- [ ] **Step 2: 增加协议映射测试**

从 `install.sh` 提取 37 个 `PROTOCOL=` 值，逐项断言映射到实际存在的安装函数；未知协议返回失败。测试不得把菜单项 31 当作安装器。

- [ ] **Step 3: 增加端口行为测试**

分别覆盖 Xray、HY2、Xray range 的当前值预填；当前目标占用原端口时允许继续；改到另一个 profile 占用的端口时拒绝。

- [ ] **Step 4: 增加事务与幂等测试**

覆盖无改动编辑、只更新目标 profile、取消不写文件、候选验证失败不写文件、重启失败回滚、初始 inactive 状态保持 inactive、staging 内不提前重启，以及子 shell 使用预先捕获的 `NV_EDIT_WAS_ACTIVE`。

- [ ] **Step 5: 增加密钥和证书测试**

覆盖 Reality 双钥复用/缺一把则拒绝编辑、HY2 同 host 保持 pin、HY2 改 host 重签、TLS 同域快速复用、新域进入 TXT，以及 staging 证书安装使用 no-op `reloadcmd`。

- [ ] **Step 6: 运行测试并确认 Red**

```bash
python -B -m unittest discover -s tests -p 'test_*.py'
```

Expected: 新增测试失败，失败原因是编辑 helper/调度尚不存在；原 49 项仍通过。

### Task 2: 建立无泄漏的编辑上下文

**Files:**

- Modify: `install.sh`，在 `xray_env_value()` 附近增加 helper
- Test: `tests/test_install_sh.py`

- [ ] **Step 1: 新增上下文变量**

只使用：

```bash
NV_EDIT_ENV_FILE   # 原节点 env 文件，仅读
NV_EDIT_KIND       # xray 或 hy2
NV_EDIT_PROFILE    # 原 Xray profile 名
NV_EDIT_STAGE      # staging 标记
NV_EDIT_WAS_ACTIVE # 进入 staging 前捕获的服务状态，0 或 1
```

这些变量只在执行编辑安装函数的子 shell 中 `export`。不要实现扫描并清理全部 `NV_EDIT_*` 的 `load_edit_context/clear_edit_context`。

- [ ] **Step 2: 新增读取 helper**

实现 `edit_env_has_key(key)`、`edit_env_value(key)`、`edit_default(key, fallback)` 和 `edit_target_default(suffix, fallback)`：

- 无编辑上下文时原样返回 fallback。
- 有编辑上下文时必须从 `NV_EDIT_ENV_FILE` 读取。
- `edit_target_default` 将 Xray 映射到 `XRAY_<suffix>`，HY2 映射到 `HY2_<suffix>`。
- key 缺失时停止编辑并给出字段名，不允许生成随机替代值。
- 所有变量展开使用 `${name:-}`，兼容脚本的 `set -u`。
- 继续复用 `xray_env_value()` 解析 `KEY=VALUE`；禁止 `source`、`eval` 或执行 env 文件内容。

- [ ] **Step 3: 固定原 profile 身份**

`register_xray_profile()` 在编辑子 shell 中优先使用 `${NV_EDIT_PROFILE:-}`；普通新增仍调用 `xray_profile_name()`。修改 host/端口后不得产生新文件名。

- [ ] **Step 4: 实现 37 项精确协议映射**

新增 `install_func_for_protocol()`。映射集合必须等于当前 37 个 `PROTOCOL=` 值，不能用未经白名单校验的动态函数调用。

- [ ] **Step 5: 运行 Task 1 对应测试并确认 Green**

### Task 3: Xray staging、验证、提交与回滚

**Files:**

- Modify: `install.sh`
- Test: `tests/test_install_sh.py`

- [ ] **Step 1: 选择并校验目标**

`edit_xray_profile(profile_name)` 检查目标 `.env`/`.json`、读取 `PROTOCOL`、解析安装函数，并在任何真实写入前拒绝未知协议或缺字段的旧 env。

- [ ] **Step 2: 创建候选目录**

用 `mktemp -d` 创建 staging root，把真实 `XRAY_PROFILE_DIR` 的全部 profile 复制到 staging profiles。为候选 config、env、service 设置独立路径。

- [ ] **Step 3: 在子 shell 中复用安装函数**

子 shell 内覆盖 `XRAY_CONFIG_DIR`、`XRAY_CONFIG_FILE`、`XRAY_ENV_FILE`、`XRAY_PROFILE_DIR`、`XRAY_SERVICE_FILE`，设置五个编辑上下文变量，并临时定义 no-op `systemctl()`、`write_xray_service()`。真实服务和真实配置在所有 prompt、确认、下载及 TXT 等待阶段保持不变。

- [ ] **Step 4: 编辑态端口冲突处理**

`ensure_port_available()` 仅在“输入端口等于目标 env 的原监听端口，且 `NV_EDIT_WAS_ACTIVE=1`”时忽略该占用。服务状态必须在覆盖 `systemctl()` 前捕获，不能在 staging 子 shell 中重新查询。编辑态遇到其他 profile/服务占用时直接返回冲突错误，不得通过 no-op 的 staging `systemctl()` 去停用无关服务；普通新增仍保留现有处理菜单。

动态端口范围继续保持现有校验能力；新增范围重叠检测不属于本次范围。

- [ ] **Step 5: 验证完整候选配置**

staging profiles 必须包含全部原 profile，并以原文件名覆盖目标 profile。运行：

```bash
"${XRAY_BIN}" run -test -config "${candidate_config}"
```

Expected: exit 0。失败时删除 staging，真实文件和服务状态不变。

- [ ] **Step 6: 原子提交并只重启一次**

先在目标目录生成 `.tmp.$$` 文件，再用 `mv` 替换目标 profile json/env、`XRAY_ENV_FILE` 和合并后的 `XRAY_CONFIG_FILE`，权限保持 `600`。其他 profile 文件不得改写。

- [ ] **Step 7: 处理重启失败**

提交前备份四个被替换文件并记录原 active 状态。原服务 active 时重启一次；重启失败则恢复备份并再次启动旧配置。原服务 inactive 时不擅自启动。

- [ ] **Step 8: 无论成功失败都删除 staging**

用父层 `trap` 清理临时目录；不要依赖安装函数在 `die` 后继续执行清理代码。

### Task 4: HY2 staging 与证书稳定性

**Files:**

- Modify: `install.sh`
- Test: `tests/test_install_sh.py`

- [ ] **Step 1: 校验 HY2 实例存在**

`edit_hy2()` 在缺少 `HY2_ENV_FILE` 或当前 config 时返回可理解的提示，不进入安装流程。

- [ ] **Step 2: 在 staging 中运行 `hy2_install`**

覆盖 HY2 config/env/cert/key/service 输出路径，屏蔽 service writer 和 `systemctl`。真实服务在交互阶段保持运行。

- [ ] **Step 3: 保持证书身份**

在调用 `create_self_signed_cert()` 之前决定证书策略：若输入 host 与原 `HY2_HOST` 相同、原 cert/key 均有效且 SAN 匹配，则复制并复用原证书；若 host 改变或证书缺失/不匹配，才在 staging 生成新证书。验证必须检查 DNS SAN 或 IP SAN，不能只检查 CN。

- [ ] **Step 4: 重新渲染最终候选 config**

候选 YAML 中的证书路径必须是最终 `HY2_CERT_FILE`/`HY2_KEY_FILE`，不能残留 staging 路径。配置值来自候选 env。

- [ ] **Step 5: 原子提交、单次重启、失败回滚**

替换 config/env；仅在重签时替换 cert/key。保存原 active 状态，重启失败恢复全部旧文件和状态。

### Task 5: 全字段默认值接线

**Files:**

- Modify: `install.sh` 中 38 个安装函数和两个 NAT port helper
- Test: `tests/test_install_sh.py`

- [ ] **Step 1: 修改单端口和范围 helper**

`prompt_nat_port_pair()` 使用 `edit_target_default('LISTEN_PORT', default)` 和 `edit_target_default('PUBLIC_PORT', listen)`；range 使用 Xray 的 `LISTEN_PORT_RANGE`/`PUBLIC_PORT_RANGE`。保留现有提示文案和 NAT 映射语义。

- [ ] **Step 2: 修改公共 prompt 默认值**

Xray 连接地址用 `XRAY_HOST`，HY2 地址用 `HY2_HOST`，UUID 用 `XRAY_UUID`，Trojan/SS/HY2 凭据使用第 4 节的真实 key。

- [ ] **Step 3: 按协议组接入专属字段**

- WS：`WS_PATH`、存在该 prompt 时的 `WS_HOST`
- HTTPUpgrade：`HTTP_PATH`、`HTTP_HOST`
- gRPC：`GRPC_SERVICE_NAME`
- XHTTP：`XHTTP_PATH`、`XHTTP_MODE`
- mKCP：`KCP_HEADER_TYPE`、`KCP_SEED`
- TLS：`TLS_DOMAIN`
- Reality：`REALITY_SNI`、`REALITY_DEST`、`REALITY_SHORT_ID`

- [ ] **Step 4: 数据驱动检查 prompt/env 对应关系**

测试逐个安装函数核对：每个交互字段都有同名 env key，每个编辑默认 key 都确实由该函数持久化。实现后的 `install.sh` 不得新增 `XRAY_WS_PATH`、`XRAY_HOST_HEADER`、`XRAY_XHTTP_PATH`、`XRAY_SEED`、`XRAY_HEADER_TYPE`、`XRAY_METHOD` 或通用 `XRAY_PASSWORD`。

### Task 6: Reality、TLS 与 HY2 的无改动幂等

**Files:**

- Modify: `install.sh`
- Test: `tests/test_install_sh.py`

- [ ] **Step 1: Reality 成对复用密钥**

编辑态同时存在 `REALITY_PRIVATE_KEY` 和 `REALITY_PUBLIC_KEY` 时复用；缺少任意一项时在真实写入前拒绝编辑，不能混用旧/新密钥或静默重建。普通新增路径仍调用 `generate_reality_keys()`，且在 `set -u` 下不报未绑定变量。

- [ ] **Step 2: TLS 编辑快速复用**

在 `request_tls_cert_manual_dns()` 的 ACME 安装和账号注册之前增加编辑态 fast path：同域、证书未过期且证书/私钥公钥匹配时直接返回。域名改变、文件缺失或校验失败时保持当前签发流程和最近提交加入的 `Enter/r/q` 交互。`NV_EDIT_STAGE=1` 时 acme `--install-cert` 的 `reloadcmd` 必须为 no-op，禁止它绕过 staging 提前重启真实 Xray。

- [ ] **Step 3: 验证无改动结果**

Reality URI、HY2 pinned URI、TLS URI 在全回车编辑后与编辑前一致；只允许文件时间戳变化，不允许凭据、pin、profile 名或链接内容变化。

### Task 7: 菜单、帮助与 README

**Files:**

- Modify: `install.sh` 的 `change_config()`、`show_help()`
- Modify: `README.md`
- Test: `tests/test_install_sh.py`

- [ ] **Step 1: 实现更改配置菜单**

菜单只提供：`1) 编辑 Xray profile`、`2) 编辑 HY2`、`0) 返回`。无对应实例时提示先添加配置；非法选项留在当前菜单；一次编辑完成后返回总控台。

- [ ] **Step 2: 保持既有交互约束**

继续使用 `read_input`/`prompt_menu_choice`，保留 `2) 更改配置` 标签、`change_config()` 函数边界、现有返回暂停行为，以及现有 49 项测试依赖的文案。

- [ ] **Step 3: 更新帮助和 README**

说明回车保留当前值、Xray 原 profile 覆盖、HY2 单实例覆盖、同域证书复用和失败回滚。本次不新增 `nv edit` 子命令，避免扩大范围。

## 6. 验证清单

### 第一轮：自动测试与语法

- [ ] `python -B -m unittest discover -s tests -p 'test_*.py'`：原 49 项和全部新增测试通过。
- [ ] `bash -n install.sh`：通过。
- [ ] `bash -n install-alpine.sh`：通过。

### 第二轮：静态一致性

- [ ] 37 个 `PROTOCOL=` 值与 `install_func_for_protocol()` 一一对应，无缺失、重复或额外项。
- [ ] 仅在实现文件 `install.sh` 中搜索并确认没有旧规格虚构的 env key；不要把本 TODO 中的“禁止项”当作实现字段。
- [ ] 所有新增变量在 `set -Eeuo pipefail` 下安全，普通新增路径不依赖任何 `NV_EDIT_*` 已定义。
- [ ] `git diff --check` 无空白错误；README 与帮助文案一致。

### 第三轮：可丢弃 Linux/OpenRC 环境场景

- [ ] Xray：全回车、只改外网端口、只改 UUID、只改 WS/XHTTP/mKCP 字段。
- [ ] 多 profile：编辑一个节点后，另一个节点持续运行且内容不变。
- [ ] Reality：全回车后密钥和 URI 不变。
- [ ] TLS：同域不触发 ACME/TXT；换域进入 `Enter/r/q` TXT 流程。
- [ ] HY2：同 host pin 不变；更换 DNS/IP 后 SAN 与 pin 更新。
- [ ] 取消、候选验证失败、服务重启失败：旧配置和原服务状态恢复。
- [ ] Debian/Ubuntu systemd 与 Alpine OpenRC 各完成至少一组 Xray 和 HY2 编辑。

## 7. 明确排除项

- 不新增或改名 env schema。
- 不增加 dynamic range 的跨 profile 重叠检测；保留现有能力。
- 不重构 6965 行脚本的整体架构。
- 不新增 `nv edit` CLI 子命令。
- 不在本任务中 commit、push、部署或连接远程服务器。
