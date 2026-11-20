# sing-box VPS 双栈智能管理脚本

面向 Debian / Ubuntu VPS 的 sing-box 一键部署与运维脚本。单文件 Bash 实现，提供交互菜单和命令行两种用法，安装后可直接输入 `sb` 打开控制台。

- 脚本版本：0.0.2
- 仓库：https://github.com/lisiyong0707/singbox
- 要求：root 权限、systemd、APT（Debian / Ubuntu）
- sing-box 版本：建议 >= 1.12.0；部署 Snell 需要 >= 1.14.0

---

## 快速安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lisiyong0707/singbox/main/sb.sh)
```

也可以先保存为文件再运行（推荐，便于自动创建快捷命令）：

```bash
curl -fsSL https://raw.githubusercontent.com/lisiyong0707/singbox/main/sb.sh -o sb.sh
sudo bash sb.sh install
```

安装完成后，在任意目录输入 `sb` 即可进入菜单。脚本本体安装在 `/usr/local/sbin/sing-box-vps`，快捷命令为 `/usr/local/bin/sb`。

纯 IPv6 机器如果无法访问 GitHub，需要先配置 DNS64 / NAT64，或手动将脚本上传到服务器后运行。

---

## 功能概览

| 类别 | 内容 |
|------|------|
| Reality 节点 | VLESS Reality（Dual / IPv4 / IPv6 三种网络模式）、VLESS Reality gRPC |
| 抗封锁 | ShadowTLS v3 + Shadowsocks 2022、NaiveProxy |
| 经典协议 | Shadowsocks 2022、Trojan TLS、VLESS TLS、Hysteria2、TUIC v5、AnyTLS、Snell（v5 / v6） |
| 穿透 | Cloudflare Tunnel（VLESS + WebSocket，支持 Token 模式与本机新建模式） |
| 出站 | Cloudflare WARP（官方 warp-cli，proxy 模式，SOCKS5 接入 sing-box） |
| 订阅 | 通用 Base64、sing-box JSON、Clash Meta / Mihomo YAML，可选本地带 Token 的 HTTP 服务 |
| 证书 | Certbot 自动签发、自动续期、到期查看、手动续期，也可使用已有 PEM |
| 运维 | 状态 / 日志 / 健康检查 / 系统诊断 / 测速 / BBR / 备份回滚 / reconcile 对账 / 卸载与彻底清除 |

---

## 协议选型建议

| 场景 | 推荐协议 |
|------|----------|
| 通用首选，无需证书 | VLESS Reality (Vision) |
| 需要 gRPC 特征或多路复用 | VLESS Reality gRPC |
| 对主动探测敏感 | ShadowTLS v3 + SS2022 |
| 跨洋高丢包线路 | Hysteria2 / TUIC v5（均为 UDP，需放行 UDP） |
| 已有域名与证书，想要标准 HTTPS 外观 | Trojan / VLESS TLS / AnyTLS / NaiveProxy |
| IP 被封或无公网端口 | Cloudflare Tunnel |
| Surge 用户 | Snell |

需要域名证书的协议：Trojan、VLESS TLS、Hysteria2、TUIC、AnyTLS、NaiveProxy。Reality 类协议和 ShadowTLS 只需选择握手伪装域名，不需要自己的证书。

---

## 网络模式

部署大多数节点时会询问网络模式：

| 模式 | 监听地址 | 出站行为 |
|------|----------|----------|
| Dual 双栈 | `::` | 优先 IPv6，失败回退 IPv4 |
| IPv4 专用 | `0.0.0.0` | 仅使用 IPv4 |
| IPv6 严格 | `::` | 仅使用 IPv6，不回退 |

选择 IPv4 / IPv6 模式前，脚本会先检测对应外网是否可用，不可用则拒绝部署。出站策略通过 sing-box 的 `domain_resolver` 实现，兼容 1.12 及之后版本，不使用已废弃的 `domain_strategy`。

---

## 命令行用法

```
sb [命令]
```

### 部署

| 命令 | 说明 |
|------|------|
| `install` | 安装 / 修复 sing-box 环境 |
| `reality-dual` / `reality-v4` / `reality-v6` | VLESS Reality（指定网络模式） |
| `reality-grpc` | VLESS Reality gRPC |
| `shadowtls` | ShadowTLS v3 + SS2022 |
| `ss` | Shadowsocks 2022 |
| `trojan` | Trojan TLS |
| `vless` | VLESS TLS |
| `hy2` | Hysteria2 |
| `tuic` | TUIC v5 |
| `anytls` | AnyTLS |
| `naive` | NaiveProxy |
| `snell` | Snell v5 / v6 |

### 管理

| 命令 | 说明 |
|------|------|
| `menu` | 交互菜单（默认） |
| `links` | 查看全部客户端连接串 |
| `qrcode` | 显示指定节点二维码 |
| `edit` | 编辑节点：改名 / 端口 / 连接地址 / 握手域名 / TLS 域名 |
| `remove` | 删除入站节点，联动清理 detour、路由规则和防火墙放行 |
| `sub` | 订阅系统菜单 |
| `cftunnel` | Cloudflare Tunnel 菜单 |
| `warp` | Cloudflare WARP 菜单 |
| `certs` | 证书管理菜单 |

### 运维

| 命令 | 说明 |
|------|------|
| `status` | 服务状态、网络栈、公网 IP、监听端口 |
| `logs` | 最近 150 行 sing-box 日志 |
| `check` | 校验配置并重启服务 |
| `health` | 健康检查 |
| `diag` | 系统诊断（资源 / 端口 / DNS / 网络栈 / BBR / 防火墙 / Tunnel / 配置） |
| `speedtest` | Cloudflare 延迟与上下行测速，Google / Microsoft 仅测延迟 |
| `bbr` | 启用 BBR 拥塞控制 |
| `reconcile` | 对账 config 与连接记录，检查防火墙缺口 |
| `rollback` | 回滚到最近一次配置备份 |
| `upgrade` | 升级 sing-box 核心 |
| `cf-upgrade` | 升级 cloudflared |
| `self-update` | 从 GitHub 更新本脚本 |
| `uninstall` | 卸载 sing-box（保留配置和数据） |
| `purge` | 彻底清除（不可逆，需输入 `DELETE` 确认） |

---

## 交互菜单

主菜单编号：

```
 1) VLESS Reality Dual        2) VLESS Reality IPv4       3) VLESS Reality IPv6
 4) Reality gRPC              5) ShadowTLS + SS2022       6) Cloudflare Tunnel 管理
 7) Shadowsocks 2022          8) Trojan + TLS             9) VLESS + TLS
10) Hysteria2                11) TUIC v5                 12) AnyTLS
13) NaiveProxy               14) Snell
15) 订阅系统管理             16) Cloudflare WARP         17) 服务器测速
18) 节点管理                 19) 诊断与运维              20) 系统维护
 0) 退出
```

终端宽度不小于 100 列时使用紧凑布局，否则回退为单列显示。

---

## 部署流程与安全机制

每次部署节点时，脚本会按以下流程执行：

1. 选择网络模式、端口，检查端口是否被配置或宿主机其他进程占用。
2. 若 tag 已存在，询问是否覆盖，覆盖时自动清理旧节点及其关联入站。
3. 生成密钥 / UUID / 密码，构造候选配置到临时文件。
4. 先做 JSON 语法校验，再执行 `sing-box check`，两者都通过才备份并替换正式配置。
5. 重启服务；重启失败或服务未运行时，自动回滚到替换前的备份。
6. 写入连接记录，放行防火墙端口，输出连接串与二维码，并自动刷新订阅文件。

其他保障：

- 严格模式：`set -Eeuo pipefail`，统一的错误陷阱会输出出错函数、行号和调用链。
- 所有用户输入经过格式校验（端口、域名、IP、安全字符集），不使用 `eval`。
- 配置备份保留最近 15 份。
- 使用 `flock` 互斥锁，避免两个 `sb` 实例同时修改配置。
- 部署过程中被 Ctrl+C 等信号中断时，会提示运行 `sb reconcile` 对账。
- 脚本自身日志写入 `/var/lib/sing-box-vps/sing-box-vps.log`，并通过 logrotate 轮转。

### 防火墙

脚本按以下顺序探测并使用第一个可用的防火墙后端：UFW、firewalld、iptables / ip6tables（IPv4 与 IPv6 分别处理）、nftables（脚本专用表 `sing_box_vps`）。节点删除或改端口时会对称撤销旧规则。

云厂商的网页安全组不受本脚本控制，需要自行放行对应端口，并注意 IPv4 与 IPv6 规则要分别放行。UDP 协议（Hysteria2、TUIC、NaiveProxy、Shadowsocks）请同时放行 UDP。

---

## 订阅系统

订阅文件生成在 `/var/lib/sing-box-vps/subscriptions/`：

| 文件 | 适用客户端 |
|------|------------|
| `sub-universal.txt` | Shadowrocket / v2rayN / NekoBox 等（Base64 的 URI 列表） |
| `sub-singbox.json` | sing-box 客户端（仅含 outbounds 片段） |
| `sub-clash.yaml` | Clash Meta / Mihomo |

说明：

- 每次部署节点后会自动刷新，也可在 `sb sub` 中手动刷新。
- ShadowTLS 节点目前只出现在通用订阅中，不会写入 sing-box JSON 和 Clash YAML。
- sing-box JSON 只包含 outbounds，需要自行合并进客户端完整配置。

### 本地订阅 HTTP 服务

`sb sub` 中可启动一个仅监听 `127.0.0.1` 的 Python 服务（默认端口 28080），带 Token 校验：

- 自适应链接：`/sub?token=xxx`，根据 User-Agent 自动返回 Clash、sing-box 或通用格式。
- 指定格式：`/sub-clash.yaml`、`/sub-singbox.json`、`/sub-universal.txt`，同样需要 `?token=xxx`。
- 服务不直接暴露公网，需用 Nginx / Caddy 反向代理并加 TLS。
- Token 可在菜单中查看与重置，重置后旧链接立即失效。

---

## Cloudflare Tunnel

`sb cftunnel` 提供：新建 Tunnel + VLESS WS 节点、状态、日志、重启、停止、重新绑定 Token、卸载、升级 cloudflared。

新建时支持两种接入方式：

1. Token 模式（推荐）：在 Zero Trust 后台创建 Tunnel 并粘贴 Token，随后按脚本提示在后台添加 Public Hostname，服务类型选 HTTP，指向 `127.0.0.1:本地端口`。
2. 本机新建模式：使用 `cloudflared tunnel login / create` 在本机创建，脚本生成 `/etc/cloudflared/config.yml` 与 systemd 服务。

本地 VLESS WS 仅监听 `127.0.0.1`，客户端通过 443 + TLS + WS 连接你的 Cloudflare 域名。部署完成后脚本会做一次连通性自检并给出提示。

---

## Cloudflare WARP

`sb warp` 通过官方 `cloudflare-warp` 客户端以 proxy 模式运行，在 `127.0.0.1:40000` 暴露 SOCKS5，并在 sing-box 中添加名为 `warp-out` 的 socks 出站。不改动宿主机全局路由。

注意：

- 脚本只添加 `warp-out` 出站，不会自动把现有节点的流量切到 WARP；如需分流，请自行编辑路由规则，将目标出站指向 `warp-out`。
- 官方 warp-cli 不支持强制锁定 IPv4 / IPv6 出口，因此脚本不提供该选项。

---

## 证书管理

`sb certs`：

- 查看配置中所有本地证书的到期时间
- 立即续期 / 重新申请
- 启用或检查自动续期（优先使用 certbot.timer，否则写入 cron）

签发使用 Certbot standalone 模式，需要域名已解析到本机且 80 端口可用（脚本会检查占用并放行 80 端口）。续期后通过 deploy hook 自动重启 sing-box。也可选择输入已有 PEM 证书路径。

---

## 诊断与对账

- `sb diag`：磁盘 / inode / 内存 / 负载、端口监听、DNS、IPv4 / IPv6 出网、BBR、防火墙、cloudflared、sing-box 配置与服务状态。
- `sb health`：语法检测、服务状态、cloudflared / WARP 状态、出站列表。
- `sb reconcile`：
  - 对比 `config.json` 入站与 `connections.json` 记录，发现孤儿项后逐项确认再处理。
  - 检查每个监听端口是否真的在防火墙层放行，缺口处逐项确认后补开。
  - 全程只报告，不做静默清理。

---

## 目录结构

```
/etc/sing-box/
  config.json                  主配置
/var/lib/sing-box-vps/
  connections.json             节点连接记录（含完整 URI）
  cf_tunnel.json               Cloudflare Tunnel 记录
  sub_token                    订阅访问 Token
  sub-server.py                本地订阅服务脚本
  ip_cache                     公网 IP 缓存（300 秒）
  sing-box-vps.log             脚本操作日志
  backups/                     配置备份（最多 15 份）
  subscriptions/               订阅文件
  qrcache/                     节点二维码 PNG
/etc/cloudflared/
  config.yml                   本机新建模式的 ingress 配置
  creds/                       Tunnel 凭证
/usr/local/sbin/sing-box-vps   脚本本体
/usr/local/bin/sb              快捷命令
```

`connections.json` 和 Token 等文件包含节点密钥，权限为 600，请勿外泄。

---

## 常见问题

**节点部署成功但客户端连不上？**
先在云厂商控制台放行对应端口（IPv4 与 IPv6 分别放行；Hysteria2 / TUIC 要放 UDP），再运行 `sb diag` 与 `sb reconcile` 检查监听和本机防火墙。部分网络会限制 UDP，可改用 Reality 等 TCP 协议。

**证书申请失败？**
确认域名的 A / AAAA 记录已指向本机，80 端口未被 Nginx / Caddy 等占用；也可选择使用已有证书路径。

**提示 sing-box 版本过低？**
运行 `sb upgrade`。Snell 需要 1.14.0 及以上。

**配置被改坏了？**
运行 `sb rollback` 恢复最近一次备份。

**更新脚本报 apt 源错误？**
升级时某个第三方源（如旧的 cloudflared 源）密钥失效只会告警，不会阻止 sing-box 官方源的升级。

---

## 卸载

- `sb uninstall`：仅卸载 sing-box 软件包，保留配置与数据。
- `sb purge`：彻底清除 sing-box / cloudflared / WARP、配置、数据、systemd 单元、APT 源、logrotate、续期钩子等，可选清理 certbot 证书与防火墙规则。不可逆，不创建备份，需输入大写 `DELETE` 确认。云厂商安全组需自行清理。

---

## 免责声明

本脚本仅用于系统网络运维与技术交流，请在遵守所在地法律法规及服务商条款的前提下使用，使用者自行承担相应责任。
