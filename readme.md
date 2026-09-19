ode
Markdown
# 🚀 sing-box VPS: 企业级全协议多栈智能运维平台

<p align="center">
  <a href="https://github.com/lisiyong0707/sing-box-vps"><img src="https://img.shields.io/badge/Release-v3.2.1-blue.svg?style=flat-square" alt="Version"></a>
  <a href="https://github.com/lisiyong0707/sing-box-vps/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-GPL%20v3-green.svg?style=flat-square" alt="License"></a>
  <a href="https://www.gnu.org/software/bash/"><img src="https://img.shields.io/badge/Bash-Strict%20Mode-orange.svg?style=flat-square" alt="Bash"></a>
  <a href="https://sing-box.sagernet.org/"><img src="https://img.shields.io/badge/sing--box-Official%20APT-purple.svg?style=flat-square" alt="sing-box"></a>
  <a href="https://github.com/lisiyong0707/sing-box-vps"><img src="https://img.shields.io/badge/Platform-Debian%20%7C%20Ubuntu-lightgrey.svg?style=flat-square" alt="Platform"></a>
  <a href="https://github.com/lisiyong0707/sing-box-vps"><img src="https://img.shields.io/badge/IPv4%20%2F%20IPv6-Dual--Stack-success.svg?style=flat-square" alt="Dual-Stack"></a>
</p>

<p align="center">
  <b>面向 Linux VPS 的现代化、模块化、高可用 sing-box 一键部署管理套件</b><br>
  原子级写入保障 · 进程崩溃自动快照回滚 · 纯原生 WARP 链式分流 · 全协议双客户端订阅导出
</p>

---

## 📑 目录

- [🌟 为什么选择本项目？](#-为什么选择本项目)
- [⚡ 一键快速安装](#-一键快速安装)
- [🎯 协议矩阵与场景选型指南](#-协议矩阵与场景选型指南)
- [🏗️ 核心架构与工程设计](#️-核心架构与工程设计)
- [💻 命令行 CLI 自动化速查](#-命令行-cli-自动化速查)
- [📱 客户端订阅与配置使用](#-客户端订阅与配置使用)
- [🩺 9 维全生命周期诊断系统](#-9-维全生命周期诊断系统)
- [❓ 常见问题排查 (FAQ)](#-常见问题排查-faq)
- [📂 运行时目录架构](#-运行时目录架构)
- [⚖️ 开源协议与免责声明](#️-开源协议与免责声明)

---

## 🌟 为什么选择本项目？

市面上多数代理部署脚本仍停留在“简单字符串拼接、强行改写系统全局路由、无容错回滚”的阶段。本项目按照**生产环境 Linux 运维标准**进行重构，具备以下核心硬实力：

1. **工业级鲁棒性 (Strict Mode)**：全面遵循 `set -Eeuo pipefail` 与全局退出陷阱捕获，彻底杜绝静默失败与管道错误击穿。
2. **原子化操作与灾难自动自愈**：所有配置写入基于 `mktemp` 临时隔离区流转，**重启校验失败 0.5 秒内自动还原上一个备份快照**，绝不导致 VPS 节点失联。
3. **原生纯净 WARP 出站**：现场 OpenSSL 派生 X25519 密钥注册 WireGuard 账户，利用 sing-box 内部 Outbound 与路由表实现精准分流，**零内核网络模块污染、零宿主机全局路由篡改**。
4. **全自动闭环订阅**：节点落地的同时，后台全量同步生成 **Mihomo (Clash.Meta) YAML**、**sing-box 客户端完整配置 Profile** 及 **通用 Base64 订阅**。

---

## ⚡ 一键快速安装

### 方式 A：标准官方一键安装（推荐，海外 VPS）

```
bash <(curl -fsSL https://raw.githubusercontent.com/lisiyong0707/singbox/main/sb.sh)
```
### 方式 B：国内 / 连通不畅镜像加速
code

bash <(curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/lisiyong0707/sing-box-vps/main/sing-box-vps.sh)
###方式 C：纯 IPv6 专属 VPS 安装
code

curl -fsSL -6 https://raw.githubusercontent.com/lisiyong0707/sing-box-vps/main/sing-box-vps.sh -o /usr/local/sbin/sing-box-vps && chmod +x /usr/local/sbin/sing-box-vps && ln -sf /usr/local/sbin/sing-box-vps /usr/local/bin/sb && sb
快捷唤醒：安装完毕后，在服务器任意目录直接输入 sb 即可打开控制台。
## 🎯 协议矩阵与场景选型指南
针对不同的网络链路、机房环境与封锁强度，脚本内置了经过参数调优的完备入站协议：
code
Code
┌── 线路极佳 / 延迟低 ──────────► VLESS-Reality (Vision / gRPC)
                    │
                    ├── 晚高峰丢包高 / 跨洋链路 ──────► Hysteria2 (QUIC 暴力抗丢包)
网络环境评估 ───────┼── 针对特定省份的主动探测阻断 ────► ShadowTLS v3 + SS2022
                    │
                    ├── 建站共用 / 传统标准 HTTPS ────► Trojan TLS / VLESS TLS
                    │
                    └── IP 被墙 / NAT 无公网端口 ────► Cloudflare Tunnel (Argo)
协议入站	核心特性	伪装/底层	推荐应用场景
VLESS Reality (Vision)	0 证书申请，直通大厂 TLS 1.3 握手	TCP + XTLS Vision	绝大多数双栈 VPS 首选，速度快且隐蔽
VLESS Reality (gRPC)	多路复用，原生云上长连接特征	gRPC / HTTP2	频繁长链接并发、CDN 穿透或防特征阻断
ShadowTLS v3 + SS2022	双向真实握手分离，抗深度主动探测	TLS 1.3 + BLAKE3	阻断严打时期、防防火墙主动嗅探封端口
Hysteria2 (Hy2)	单流拥塞丢包反冲，BBR 自适应加速	UDP QUIC (Salamander)	跨洋远距离高丢包、移动宽带、低质量骨干网
TUIC v5	原生零 RTT 握手，超低延迟建连	UDP QUIC (BBR)	多连接频繁发起的场景，轻量顺滑
Cloudflare Tunnel	无需暴露 VPS 真实公网 IP 与端口	HTTP/WS -> Argo 隧道	拯救被墙 IP、NAT 共享 IP 服务器、无独立端口机器
Shadowsocks 2022	现代高效对称加密，低 CPU 占用	2022-blake3-aes-128	软路由主路由高性能直通、省电省算力
## 🏗️ 核心架构与工程设计
1. 原子配置写入与失败秒级自愈
code
Code
[新配置生成] ──► mktemp 隔离文件 ──► sing-box check 语法校验 
                                              │ (校验通过)
 [服务即刻恢复] ◄── 还原快照备份 ◄── 重启失败? ◄── 替换正式配置 & 重启 systemd
2. 原生 WireGuard/WARP 链式分流架构
传统 WARP 脚本多采用修改宿主机内核全局默认路由的方式，导致 SSH 容易失联或本地端口失效。本项目将 WARP 运行在应用层：
code
Code
客户端请求 ──► Inbound 节点 ──► sing-box 内部核心路由规则
                                        │
                       ┌────────────────┴────────────────┐
                       ▼                                 ▼
             常规流出 / 境内流量                 流媒体 / 解锁流量
                       │                                 │
                 direct 出口                        warp-out 出口
            (宿主机 IPv4/IPv6 出口)               (WireGuard 到 Cloudflare)
## 💻 命令行 CLI 自动化速查
除了交互式控制台，支持通过参数静默调用，便于集成与批量维护：
code
Bash
# === 节点一键部署 ===
sb reality           # 部署双栈自适应 VLESS Reality Dual (默认推荐)
sb reality-v4        # 部署纯 IPv4 专用 Reality 节点
sb reality-v6        # 部署纯 IPv6 专用 Reality 节点
sb grpc              # 部署 VLESS Reality gRPC
sb shadowtls         # 部署 ShadowTLS v3 + SS2022
sb hy2               # 部署 Hysteria2 (UDP QUIC)
sb tuic              # 部署 TUIC v5
sb trojan            # 部署 Trojan TLS (需域名解析)
sb vless             # 部署 VLESS TLS
sb ss                # 部署 Shadowsocks 2022

# === 穿透与出口分流 ===
sb cftunnel          # 打开 Cloudflare Tunnel 管理菜单
sb warp              # 打开 Cloudflare WARP 智能分流菜单

# === 订阅中心与连接导出 ===
sb links             # 列出全部已部署节点连接串（支持终端二维码打印）
sb subs              # 查看与刷新 Clash.Meta / sing-box 客户端订阅

# === 系统级运维与体检 ===
sb diag              # 执行 9 项全维系统深度体检诊断 (或输入 sb health)
sb test              # 执行国际多节点延迟与双向带宽吞吐测速
sb certs             # 查看证书生命周期、剩余天数与手动续期
sb logs              # 实时打印 sing-box 运行日志
sb status            # 查看服务状态与当前各节点监听端口
sb check             # 语法校验配置并平滑热重载服务
sb bbr               # 一键开启系统内核级 BBR 拥塞控制
sb rollback          # 列出多版本配置快照，一键选择历史回退
sb remove            # 删除指定节点（级联清理附属 detour 及路由规则）
sb upgrade           # 从官方源升级 sing-box 核心二进制
sb self-update       # 从 GitHub 拉取升级本管理脚本
sb uninstall         # 彻底卸载 sing-box（保留配置数据）
## 📱 客户端订阅与配置使用
脚本内部集成全功能订阅引擎，路径保存在 /var/lib/sing-box-vps/subscriptions/：
1. 通用客户端 (Shadowrocket / v2rayN / Loon / Quantumult X)
部署节点后，终端会直接渲染 ANSI-UTF8 二维码，打开手机扫码即可直接录入。
运行 sb subs 选择选项 1，可复制整组 通用 Base64 订阅串。
2. Mihomo (Clash.Meta)
自动生成标准 YAML 节点集合，支持 Reality、gRPC、ShadowTLS、Hy2、TUIC 全协议。
配置文件位置：/var/lib/sing-box-vps/subscriptions/clash_meta.yaml。
3. sing-box 官方客户端
自动拼接开箱即用的完整 profile，包含完整的本地 Inbound（Mixed 2080 端口）、Selector 分流规则及全部已生成的实际 Outbound 实体。
配置文件位置：/var/lib/sing-box-vps/subscriptions/singbox.json。
## 🩺 9 维全生命周期诊断系统
运行 sb diag 命令，对节点服务进行秒级健康体检：
code
Text
检查项目                     诊断结果           状态说明/检测指标
--------------------------------------------------------------------------------
端口绑定冲突                 正常               已声明业务端口无第三方冲突抢占
系统 DNS 解析                正常               公网与海外 CDN 域名解析通畅
IPv4 出口状态                连通良好           89.xxx.xxx.xxx
IPv6 出口状态                连通良好           2607:xxxx::xxxx
TCP 拥塞算法                 BBR 活跃生效       当前内核算法: bbr
防火墙策略 (UFW)             放通/未启用        本地无规则拦截端口
Cloudflare Tunnel            常驻运行           隧道服务正常通信
sing-box 语法校验            通过               JSON 架构合法且出站对齐
sing-box 进程状态            运行中             Active (running)
## ❓ 常见问题排查 (FAQ)
### Q1: 节点配置完成后，客户端无法连接超时？
云服务商安全组：Oracle Cloud（甲骨文）、AWS、阿里云、腾讯云等均有独立的网页端网络安全组/子网防火墙。仅在 Linux 本地开放端口无效，必须登录网页控制台放行对应的 TCP/UDP 端口。
UDP 阻断：若部署了 Hysteria2 或 TUIC，请确保云服务商安全组同时放行了 UDP 端口。部分校园网或公司网络限制了 UDP 流量，此时可切换为 VLESS Reality TCP 模式。
### Q2: Let's Encrypt 证书申请失败？
确认待申请的域名解析（A / AAAA 记录）已经正确生效并指向当前服务器公网 IP。
确保服务器 80 端口 未被 Nginx、Caddy 或 Apache 等 Web 服务抢占（脚本会自动检查 80 端口状态）。若被占用，可选择选项输入已有 PEM 证书路径。
### Q3: 纯 IPv6 (IPv6-Only) VPS 能够使用该脚本吗？
完全支持。脚本内部已做好 IPv4/IPv6 自适应判断。
注意：部分纯 IPv6 机器没有提供公共 NAT64/DNS64 访问外界，会导致拉取 GitHub 软件源失败。请在安装前配置公共 DNS64（例如 /etc/resolv.conf 中追加 nameserver 2001:67c:2b0::4）。
## 📂 运行时目录架构
code
Text
/etc/sing-box/
  └── config.json                     # 当前在跑的主配置 (chmod 600)
/var/lib/sing-box-vps/
  ├── connections.json                # 节点连接元数据清单
  ├── warp.json                       # WARP WireGuard 账户认证私钥凭证
  ├── backups/                        # 历史滚动快照存储池 (最多保留 15 个)
  │   ├── config-20260918-101201.json
  │   └── ...
  └── subscriptions/                  # 实时同步生成的客户端多格式配置
      ├── clash_meta.yaml             # Clash.Meta (Mihomo) 片段
      ├── singbox.json                # sing-box 客户端 profile 模板
      ├── sub.txt                     # 原始单节点 URI 列表
      └── sub_base64.txt              # Base64 订阅链接串
/etc/cloudflared/
  ├── config.yml                      # 本地 Ingress 规则映射
  └── token.txt                       # Tunnel Token 离线脱机备份 (用于自愈修复)
## ⚖️ 开源协议与免责声明
本项目基于 GPL-3.0 License 开放源代码。
本脚本仅作为系统网络运维工具及开源技术交流使用，请在符合所在地法律法规及服务商 ToS 约定的前提下进行测试学习。使用者需自行对使用行为及产生的网络流量合规性负责。
