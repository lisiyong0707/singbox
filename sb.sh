#!/usr/bin/env bash
# ============================================================================
# sing-box-vps :: 生产级 sing-box VPS 双栈智能管理脚本
# Repository : https://github.com/lisiyong0707/singbox
#
# 功能总览:
#   VLESS Reality / Reality gRPC / ShadowTLS v3+SS2022 / Shadowsocks 2022 /
#   Trojan TLS / VLESS TLS / Hysteria2 / TUIC v5 / Cloudflare Tunnel /
#   Cloudflare WARP 出站 / 订阅系统 (sing-box / Clash Meta / Shadowrocket) /
#   节点二维码 / 证书管理 (Certbot 自动续期) / 系统诊断 / 测速 / 配置备份回滚
#
# 设计原则:
#   - set -Eeuo pipefail 严格模式, 全程 trap 统一错误处理
#   - 所有配置写入 (config.json / state.json / 订阅文件) 一律 mktemp + 校验 + install 原子替换
#   - 所有 jq 变更一律先在候选文件上验证 (sing-box check / jq 语法), 失败绝不覆盖生产文件,
#     并自动保留最近一次可用配置备份用于一键回滚
#   - 绝不使用 eval; 所有用户输入统一走 ask_*/valid_* 校验管道, 拒绝把用户输入直接嵌入
#     shell 命令行或不受控的变量展开中
# ============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="3.0.0"
readonly SB_MIN_VERSION="1.12.0"

readonly CONFIG_DIR="/etc/sing-box"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly STATE_DIR="/var/lib/sing-box-vps"
readonly STATE_FILE="${STATE_DIR}/connections.json"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly SUB_DIR="${STATE_DIR}/subscriptions"
readonly QR_CACHE_DIR="${STATE_DIR}/qrcache"
readonly LOG_FILE="${STATE_DIR}/sing-box-vps.log"

readonly CF_CONFIG_DIR="/etc/cloudflared"
readonly CF_CONFIG_FILE="${CF_CONFIG_DIR}/config.yml"
readonly CF_CRED_DIR="${CF_CONFIG_DIR}/creds"

readonly CERT_HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-sing-box"
readonly MANAGER_PATH="/usr/local/sbin/sing-box-vps"
readonly SHORTCUT_PATH="/usr/local/bin/sb"
readonly SUB_HTTPD_UNIT="/etc/systemd/system/sing-box-vps-sub.service"

SCRIPT_UPDATE_URL="${SCRIPT_UPDATE_URL:-https://raw.githubusercontent.com/lisiyong0707/sing-box-vps/main/sing-box-vps.sh}"

readonly REALITY_PRESET_DOMAINS=(
  "gateway.icloud.com"
  "mask.icloud.com"
  "www.cloudflare.com"
  "www.microsoft.com"
  "www.google.com"
  "www.apple.com"
  "dl.google.com"
  "swdist.apple.com"
)

# ---------------------------------------------------------------------------
# 颜色与日志
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

_log_raw() {
  # 日志文件不含颜色转义, 便于后续 grep/诊断
  [[ -d $STATE_DIR ]] || install -d -m 700 "$STATE_DIR" 2>/dev/null || return 0
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

info() { printf "${BLUE}[i]${NC} %s\n" "$*"; _log_raw "[INFO] $*"; }
ok()   { printf "${GREEN}[+]${NC} %s\n" "$*"; _log_raw "[OK] $*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*" >&2; _log_raw "[WARN] $*"; }
die()  { printf "${RED}[x]${NC} %s\n" "$*" >&2; _log_raw "[FATAL] $*"; exit 1; }
title(){ printf "\n${BOLD}${CYAN}== %s ==${NC}\n" "$*"; }

on_error() {
  local exit_code=$? line=$1
  printf "${RED}[x]${NC} 运行失败: 第 %s 行退出 (状态码 %s)。日志: %s\n" "$line" "$exit_code" "$LOG_FILE" >&2
  _log_raw "[FATAL] line=${line} exit=${exit_code} cmd_context=${BASH_COMMAND:-unknown}"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# 基础前置检查
# ---------------------------------------------------------------------------
require_root()    { [[ ${EUID} -eq 0 ]] || die "请使用 sudo bash $0 运行。"; }
require_systemd() { command -v systemctl >/dev/null 2>&1 || die "此脚本需要 systemd 环境支持。"; }
require_apt()      { command -v apt-get  >/dev/null 2>&1 || die "当前版本仅支持 Debian/Ubuntu (APT) 系统。"; }
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "缺少必要命令: ${c} (请先运行安装/修复环境)。"
  done
}

ensure_dirs() {
  install -d -m 700 "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR" "$SUB_DIR" "$QR_CACHE_DIR"
  if [[ ! -f $STATE_FILE ]]; then
    printf '{"connections":[]}\n' > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
  fi
  [[ -f $LOG_FILE ]] || { : > "$LOG_FILE"; chmod 600 "$LOG_FILE"; }
}

# ---------------------------------------------------------------------------
# 交互输入与严格校验 (杜绝命令注入 / 非法值)
# ---------------------------------------------------------------------------
confirm() {
  local prompt=$1 default=${2:-N} answer
  read -r -p "$prompt [$([[ $default == Y ]] && printf 'Y/n' || printf 'y/N')]: " answer || true
  answer=${answer:-$default}
  [[ $answer =~ ^[Yy]$ ]]
}

ask_required() {
  local prompt=$1 value
  while true; do
    read -r -p "$prompt: " value || true
    [[ -n $value ]] && { printf '%s' "$value"; return 0; }
    warn "此项不能为空。"
  done
}

# 仅允许安全字符集, 阻断任何可能用于命令注入 / 路径穿越的输入
valid_safe_token() {
  [[ $1 =~ ^[A-Za-z0-9_.:-]{1,128}$ ]]
}

valid_port() {
  [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

ask_port() {
  local prompt=$1 default=$2 value
  while true; do
    read -r -p "$prompt [$default]: " value || true
    value=${value:-$default}
    valid_port "$value" && { printf '%s' "$value"; return 0; }
    warn "端口必须是 1 到 65535 之间的整数。"
  done
}

valid_hostname() {
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

ask_hostname() {
  local prompt=$1 default=${2:-} value
  while true; do
    if [[ -n $default ]]; then
      read -r -p "$prompt [$default]: " value || true
      value=${value:-$default}
    else
      read -r -p "$prompt: " value || true
    fi
    valid_hostname "$value" && { printf '%s' "$value"; return 0; }
    warn "域名格式不正确, 请重新输入。"
  done
}

valid_ipv4() {
  local ip=$1 a b c d o
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  IFS=. read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do (( 10#$o <= 255 )) || return 1; done
  return 0
}

valid_ipv6() {
  [[ $1 =~ ^[0-9a-fA-F:]+$ && $1 == *:* ]]
}

# ---------------------------------------------------------------------------
# 原子写入引擎: 任意"候选文件"写好之后, 通过本函数校验并原子替换目标文件,
# 校验失败绝不落地, 不污染生产文件
# ---------------------------------------------------------------------------
atomic_install() {
  # atomic_install <candidate_tmp_file> <dest_path> <mode>
  local candidate=$1 dest=$2 mode=${3:-600}
  [[ -s $candidate ]] || die "内部错误: 候选文件为空, 拒绝写入 ${dest}。"
  install -m "$mode" "$candidate" "$dest"
}

json_validate() {
  # 仅校验合法 JSON 语法
  local file=$1
  jq -e . "$file" >/dev/null 2>&1
}

atomic_json_update() {
  # atomic_json_update <target_file> <jq_filter> [jq_args...]
  # 将 jq_filter 应用到 target_file, 结果写入临时文件并校验 JSON 合法性,
  # 校验通过才原子替换; 失败则保留原文件不变并返回非零
  local target=$1 filter=$2; shift 2
  local candidate
  candidate=$(mktemp "${target}.XXXXXX")
  if ! jq "$filter" "$@" "$target" > "$candidate" 2>>"$LOG_FILE"; then
    rm -f "$candidate"
    warn "jq 变更执行失败, 已保留原文件不变: ${target}"
    return 1
  fi
  if ! json_validate "$candidate"; then
    rm -f "$candidate"
    warn "jq 变更结果 JSON 校验失败, 已回滚: ${target}"
    return 1
  fi
  atomic_install "$candidate" "$target" 600
  rm -f "$candidate" 2>/dev/null || true
  return 0
}
# ---------------------------------------------------------------------------
# 网络栈探测: IPv4 Only / IPv6 Only / Dual Stack
# 优先通过路由表判断 (ip -4/-6 route), 再辅以出网连通性探测作为兜底/确认
# ---------------------------------------------------------------------------
has_ipv4_route() { ip -4 route show default 2>/dev/null | grep -q '.'; }
has_ipv6_route() { ip -6 route show default 2>/dev/null | grep -q '.'; }

check_ipv4_egress() {
  has_ipv4_route || return 1
  curl -4fsS --connect-timeout 2 --max-time 3 https://api.ipify.org >/dev/null 2>&1 && return 0
  curl -4fsS --connect-timeout 2 --max-time 3 https://www.cloudflare.com >/dev/null 2>&1 && return 0
  ping -4 -c 1 -W 2 1.1.1.1 >/dev/null 2>&1
}

check_ipv6_egress() {
  has_ipv6_route || return 1
  curl -6fsS --connect-timeout 2 --max-time 3 https://api64.ipify.org >/dev/null 2>&1 && return 0
  curl -6fsS --connect-timeout 2 --max-time 3 https://www.cloudflare.com >/dev/null 2>&1 && return 0
  ping -6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1
}

# 返回: v4only | v6only | dual | none
detect_network_stack() {
  local v4=0 v6=0
  check_ipv4_egress && v4=1
  check_ipv6_egress && v6=1
  if (( v4 == 1 && v6 == 1 )); then printf 'dual'
  elif (( v4 == 1 )); then printf 'v4only'
  elif (( v6 == 1 )); then printf 'v6only'
  else printf 'none'
  fi
}

detect_public_ip() {
  local ip endpoint
  for endpoint in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4fsS --connect-timeout 3 --max-time 5 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
    valid_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
  done
  hostname -I 2>/dev/null | awk '{print $1}'
}

detect_public_ipv6() {
  local ip endpoint
  for endpoint in https://api64.ipify.org https://ifconfig.co/ip; do
    ip=$(curl -6fsS --connect-timeout 3 --max-time 5 "$endpoint" 2>/dev/null | tr -d '[:space:]' || true)
    valid_ipv6 "$ip" && { printf '%s' "$ip"; return 0; }
  done
  return 0
}

format_host_uri() {
  local host=$1
  if [[ $host == *:* && $host != \[*\] ]]; then
    printf '[%s]' "$host"
  else
    printf '%s' "$host"
  fi
}

get_server_flag() {
  local country c1 c2
  country=$(curl -4fsS --connect-timeout 2 --max-time 3 "https://ipapi.co/country/" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ ! $country =~ ^[A-Za-z]{2}$ ]]; then
    country=$(curl -4fsS --connect-timeout 2 --max-time 3 "https://api.country.is/" 2>/dev/null | jq -r '.country // empty' 2>/dev/null || true)
  fi
  if [[ $country =~ ^[A-Za-z]{2}$ ]]; then
    country=$(printf '%s' "$country" | tr '[:lower:]' '[:upper:]')
    c1=${country:0:1}; c2=${country:1:1}
    printf "%b%b" \
      "$(printf '\\U%08X' $(( 0x1F1E6 + $(printf '%d' "'$c1") - 65 )))" \
      "$(printf '\\U%08X' $(( 0x1F1E6 + $(printf '%d' "'$c2") - 65 )))"
  else
    printf "🌐"
  fi
}

# sing-box outbound 层的 IP 版本策略字段几经变迁:
#   - 1.11 之前: 出站字段 domain_strategy (prefer_ipv4/prefer_ipv6/ipv4_only/ipv6_only)
#   - 1.12 起: domain_strategy 标记为废弃, 替换为 domain_resolver (引用 dns.servers 中的
#     一个 server tag, 并可选带 strategy), network_strategy 是完全不同的字段
#     (仅用于 Android/Apple 图形客户端的多网络接口选路, 与 IPv4/IPv6 偏好无关)
#   - 1.14 起: domain_strategy 若未设置环境变量 ENABLE_DEPRECATED_LEGACY_DOMAIN_STRATEGY_OPTIONS
#     会直接校验失败
# 因此本脚本统一采用 domain_resolver + 一个内置 DNS server 的现代方案, 不再探测/使用
# network_strategy 或 domain_strategy 字段。
readonly SB_DNS_RESOLVER_TAG="dns-direct"

ensure_dns_resolver() {
  # 确保配置里存在一个可供 domain_resolver 引用的 DNS server
  atomic_json_update "$CONFIG_FILE" '
    if .dns == null then .dns = {servers: []} else . end |
    if (.dns.servers | map(select(.tag == $tag)) | length) == 0 then
      .dns.servers += [{type:"udp", tag:$tag, server:"1.1.1.1"}]
    else . end
  ' --arg tag "$SB_DNS_RESOLVER_TAG" || true
}


ask_node_network_mode() {
  local stack choice
  stack=$(detect_network_stack)
  printf "\n当前服务器网络栈: %s\n" "$stack" >&2
  printf "选择节点接入与出站网络模式:\n" >&2
  printf "  1) Dual 双栈节点 (监听 ::, 出站优先 IPv6 并自动回退 IPv4)\n" >&2
  printf "  2) IPv4 专用节点 (监听 0.0.0.0, 出站强制仅使用 IPv4)\n" >&2
  printf "  3) IPv6 优先节点 (监听 ::, 出站优先 IPv6)\n" >&2
  read -r -p "请选择 [1]: " choice
  choice=${choice:-1}
  case "$choice" in
    2)
      check_ipv4_egress || die "系统检测到 IPv4 外网不可用, 无法部署 IPv4 专用节点。"
      printf 'v4' ;;
    3)
      check_ipv6_egress || die "系统检测到 IPv6 外网不可用, 无法部署 IPv6 节点。"
      printf 'v6' ;;
    *)
      printf 'dual' ;;
  esac
}

ask_node_server() {
  local mode=$1 default val
  case "$mode" in
    v4)
      default=$(detect_public_ip)
      read -r -p "客户端连接 IPv4 地址 [${default}]: " val
      val=${val:-$default}
      valid_ipv4 "$val" || valid_hostname "$val" || die "必须填写有效的 IPv4 地址或域名。"
      ;;
    v6)
      default=$(detect_public_ipv6)
      read -r -p "客户端连接 IPv6 地址 [${default}]: " val
      val=${val:-$default}
      valid_ipv6 "$val" || valid_hostname "$val" || die "必须填写有效的 IPv6 地址或域名。"
      ;;
    *)
      default=$(detect_public_ip)
      [[ -z $default ]] && default=$(detect_public_ipv6)
      read -r -p "客户端连接双栈地址 (强烈推荐填写已解析 A 和 AAAA 的域名) [${default}]: " val
      val=${val:-$default}
      [[ -n $val ]] || die "必须填写有效的连接域名或 IP。"
      ;;
  esac
  printf '%s' "$val"
}

# 网络模式 -> (监听地址, 出站 tag) 映射, 消除各部署函数中的重复 case 块
mode_listen_addr() {
  case "$1" in
    v4) printf '0.0.0.0' ;;
    v6) printf '::' ;;
    *)  printf '::' ;;
  esac
}
mode_outbound_tag() {
  case "$1" in
    v4) printf 'direct-v4' ;;
    v6) printf 'direct-v6' ;;
    *)  printf 'direct-dual' ;;
  esac
}

# ---------------------------------------------------------------------------
# 安装与基础路由配置
# ---------------------------------------------------------------------------
install_prerequisites() {
  require_apt
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl jq openssl iproute2 gnupg qrencode dnsutils python3 >/dev/null
}

install_sing_box() {
  require_root; require_systemd; install_prerequisites
  info "配置 sing-box 官方 APT 软件源"
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod a+r /etc/apt/keyrings/sagernet.asc
  tee /etc/apt/sources.list.d/sagernet.sources >/dev/null <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
  apt-get update -qq
  apt-get install -y -qq sing-box
  ensure_base_routing
  systemctl enable sing-box >/dev/null 2>&1 || true
  install_manager
  ok "已安装 $(sing-box version | head -n 1)"
}

install_manager() {
  local source_path=${BASH_SOURCE[0]:-}
  if [[ -z $source_path || ! -r $source_path ]]; then
    warn "无法读取当前脚本路径, 跳过创建快捷命令。"
    return 0
  fi
  install -D -m 700 "$source_path" "$MANAGER_PATH"
  tee "$SHORTCUT_PATH" >/dev/null <<EOF
#!/usr/bin/env bash
exec ${MANAGER_PATH} "\$@"
EOF
  chmod 755 "$SHORTCUT_PATH"
  ok "已创建快捷命令: sb"
}

version_ge() {
  # version_ge <have> <need> : 语义化版本比较, 返回 0 表示 have >= need
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

check_sing_box_min_version() {
  command -v sing-box >/dev/null 2>&1 || return 1
  local ver
  ver=$(sing-box version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  [[ -n $ver ]] || return 1
  if ! version_ge "$ver" "$SB_MIN_VERSION"; then
    warn "检测到 sing-box 版本 ${ver} 低于建议最低版本 ${SB_MIN_VERSION}, 部分特性 (如 Reality/Hysteria2/TUIC) 可能不受支持, 建议运行 'sb upgrade'。"
    return 1
  fi
  return 0
}

ensure_installed() {
  command -v sing-box >/dev/null 2>&1 || install_sing_box
  command -v jq >/dev/null 2>&1 || install_prerequisites
  check_sing_box_min_version || true
  ensure_base_routing
}

create_base_config() {
  [[ -f $CONFIG_FILE ]] && return 0
  ensure_dirs
  info "初始化包含 IPv4/IPv6 出站策略的基础配置"
  local candidate
  candidate=$(mktemp)
  jq -n --arg dns_tag "$SB_DNS_RESOLVER_TAG" '{
    "$schema": "https://sing-box.sagernet.org/schema.json",
    log: { level: "info", timestamp: true },
    dns: { servers: [ { type: "udp", tag: $dns_tag, server: "1.1.1.1" } ] },
    inbounds: [],
    outbounds: [
      { type: "direct", tag: "direct" },
      { type: "direct", tag: "direct-v4", domain_resolver: { server: $dns_tag, strategy: "ipv4_only" } },
      { type: "direct", tag: "direct-v6", domain_resolver: { server: $dns_tag, strategy: "prefer_ipv6" } },
      { type: "direct", tag: "direct-dual", domain_resolver: { server: $dns_tag, strategy: "prefer_ipv6" } },
      { type: "block", tag: "block" }
    ],
    route: { rules: [], final: "direct" }
  }' > "$candidate"
  json_validate "$candidate" || die "内部错误: 基础配置生成失败。"
  atomic_install "$candidate" "$CONFIG_FILE" 600
  rm -f "$candidate"
}

ensure_base_routing() {
  ensure_dirs
  create_base_config
  ensure_dns_resolver
  atomic_json_update "$CONFIG_FILE" '
    if (.outbounds | map(select(.tag == "direct-v4")) | length) == 0 then
      .outbounds += [{"type": "direct", "tag": "direct-v4", "domain_resolver": {"server": $dns_tag, "strategy": "ipv4_only"}}]
    else . end |
    if (.outbounds | map(select(.tag == "direct-v6")) | length) == 0 then
      .outbounds += [{"type": "direct", "tag": "direct-v6", "domain_resolver": {"server": $dns_tag, "strategy": "prefer_ipv6"}}]
    else . end |
    if (.outbounds | map(select(.tag == "direct-dual")) | length) == 0 then
      .outbounds += [{"type": "direct", "tag": "direct-dual", "domain_resolver": {"server": $dns_tag, "strategy": "prefer_ipv6"}}]
    else . end |
    if .route.rules == null then .route.rules = [] else . end
  ' --arg dns_tag "$SB_DNS_RESOLVER_TAG" || true
}
# ---------------------------------------------------------------------------
# 配置备份
# ---------------------------------------------------------------------------
backup_config() {
  [[ -f $CONFIG_FILE ]] || return 0
  local stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  install -m 600 "$CONFIG_FILE" "${BACKUP_DIR}/config-${stamp}.json"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.json' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | awk 'NR>15 {print $2}' | xargs -r rm -f
}

# apply_candidate <candidate_file>
# 校验通过 -> 备份现有生产配置 -> 原子替换 -> 重启服务
# 校验/重启失败 -> 自动回滚到替换前的备份, 绝不让生产服务停留在坏配置上
apply_candidate() {
  local candidate=$1
  json_validate "$candidate" || die "候选配置 JSON 语法非法, 已拒绝写入。"
  if ! sing-box check -c "$candidate" 2>>"$LOG_FILE"; then
    die "候选配置未通过 sing-box check 校验, 已拒绝写入, 详见 ${LOG_FILE}。"
  fi
  backup_config
  local prev_backup
  prev_backup=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.json' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -n1 | cut -d' ' -f2-)

  atomic_install "$candidate" "$CONFIG_FILE" 600
  systemctl enable --now sing-box >/dev/null 2>&1 || true
  if ! systemctl restart sing-box; then
    warn "sing-box 重启失败, 正在自动回滚到上一份可用配置..."
    if [[ -n $prev_backup && -f $prev_backup ]]; then
      atomic_install "$prev_backup" "$CONFIG_FILE" 600
      systemctl restart sing-box || warn "回滚后仍未能启动 sing-box, 请运行 'sb logs' 排查。"
      die "部署失败, 已回滚至变更前配置。"
    else
      die "部署失败且无可用备份用于回滚, 请手动检查 ${CONFIG_FILE}。"
    fi
  fi
  if ! systemctl is-active --quiet sing-box; then
    warn "sing-box 服务未处于运行状态, 正在自动回滚..."
    if [[ -n $prev_backup && -f $prev_backup ]]; then
      atomic_install "$prev_backup" "$CONFIG_FILE" 600
      systemctl restart sing-box || true
      die "部署失败, 已回滚至变更前配置。"
    else
      die "部署失败且无可用备份用于回滚, 请手动检查 ${CONFIG_FILE}。"
    fi
  fi
}

port_is_used_in_config() {
  local port=$1
  jq -e --argjson port "$port" '.inbounds[]? | select(.listen_port == $port)' "$CONFIG_FILE" >/dev/null 2>&1
}

ensure_port_available() {
  local port=$1
  if port_is_used_in_config "$port"; then
    die "端口 $port 已在 sing-box 配置中被占用。"
  fi
  if command -v ss >/dev/null 2>&1 && ss -tulnH "sport = :$port" 2>/dev/null | grep -q .; then
    die "端口 $port 已被宿主机其他进程占用, 请更换端口。"
  fi
}

check_and_handle_existing_tag() {
  local tag=$1
  if jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
    warn "检测到节点标识 [${tag}] 已存在!"
    if confirm "该节点已存在, 是否覆盖?" N; then
      local candidate
      candidate=$(mktemp)
      jq --arg tag "$tag" '
        .inbounds |= map(select(.tag != $tag)) |
        if .route.rules then .route.rules |= map(select((.inbound // []) | index($tag) | not)) else . end
      ' "$CONFIG_FILE" > "$candidate"
      apply_candidate "$candidate"
      rm -f "$candidate"
      atomic_json_update "$STATE_FILE" '.connections |= map(select(.tag != $tag))' --arg tag "$tag"
      ok "已自动清理旧节点 [${tag}], 开始重新写入..."
      return 0
    fi
    warn "操作已取消。"
    return 1
  fi
  return 0
}

apply_inbound_with_route() {
  local inbound_json=$1 tag=$2 outbound_tag=$3 candidate
  candidate=$(mktemp)
  jq --argjson inbound "$inbound_json" --arg tag "$tag" --arg outbound "$outbound_tag" '
    .inbounds += [$inbound] |
    .route.rules += [{"inbound": [$tag], "outbound": $outbound}]
  ' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"
}

# ---------------------------------------------------------------------------
# 防火墙
# ---------------------------------------------------------------------------
open_firewall_port() {
  local port=$1 protocol=${2:-tcp}
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "${port}/${protocol}" >/dev/null 2>&1
    ok "已通过 UFW 放行 ${port}/${protocol}"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/${protocol}" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "已通过 firewalld 放行 ${port}/${protocol}"
  else
    warn "未检测到启用中的 UFW/firewalld; 请在云厂商安全组 (阿里云/腾讯云/Vultr/Oracle Cloud 等) 放行 ${port}/${protocol}。"
  fi
}

# ---------------------------------------------------------------------------
# 密钥 / UUID / 随机路径生成
# ---------------------------------------------------------------------------
random_ss_key()  { sing-box generate rand --base64 16 2>/dev/null || openssl rand -base64 16 | tr -d '\n'; }
random_token()   { openssl rand -hex 24; }
random_path()    { printf '/%s' "$(openssl rand -hex 12)"; }
new_uuid()       { sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid; }

generate_reality_keypair() {
  local keypair private_key public_key
  keypair=$(sing-box generate reality-keypair)
  private_key=$(awk -F': ' '/PrivateKey/ {print $2}' <<<"$keypair" | tr -d '[:space:]')
  public_key=$(awk -F': ' '/PublicKey/ {print $2}' <<<"$keypair" | tr -d '[:space:]')
  [[ -n $private_key && -n $public_key ]] || die "无法生成 Reality 密钥对。"
  printf '%s|%s' "$private_key" "$public_key"
}
# Reality 握手域名: 内置推荐列表 + 自定义, 并做连通性/TLS1.3 粗校验
ask_reality_handshake_domain() {
  local i choice domain
  printf "\n选择 Reality 握手伪装域名 (需支持 TLS 1.3, 建议选用大型 CDN/云厂商域名):\n" >&2
  for i in "${!REALITY_PRESET_DOMAINS[@]}"; do
    printf "  %d) %s\n" "$((i+1))" "${REALITY_PRESET_DOMAINS[$i]}" >&2
  done
  printf "  0) 自定义输入\n" >&2
  read -r -p "请选择 [1]: " choice
  choice=${choice:-1}
  if [[ $choice == 0 ]]; then
    domain=$(ask_required "请输入握手域名")
  elif [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#REALITY_PRESET_DOMAINS[@]} )); then
    domain=${REALITY_PRESET_DOMAINS[$((choice-1))]}
  else
    domain=${REALITY_PRESET_DOMAINS[0]}
  fi
  valid_hostname "$domain" || die "握手域名格式不正确。"
  if command -v openssl >/dev/null 2>&1; then
    if ! timeout 4 openssl s_client -connect "${domain}:443" -tls1_3 -servername "$domain" </dev/null >/dev/null 2>&1; then
      warn "无法确认 ${domain} 支持 TLS 1.3 握手 (可能是网络限制), 请自行确保可用性。"
    fi
  fi
  printf '%s' "$domain"
}

# ---------------------------------------------------------------------------
# TLS 证书管理 (Certbot)
# ---------------------------------------------------------------------------
tls_json() {
  local domain=$1 cert=$2 key=$3
  jq -n --arg domain "$domain" --arg cert "$cert" --arg key "$key" \
    '{enabled:true,server_name:$domain,alpn:["h2","http/1.1"],min_version:"1.2",certificate_path:$cert,key_path:$key}'
}

check_port_80() {
  if command -v ss >/dev/null 2>&1 && ss -tulnH "sport = :80" 2>/dev/null | grep -q .; then
    warn "检测到 80 端口已被其他服务占用!"
    ss -tlpn "sport = :80" 2>/dev/null || true
    confirm "是否继续? (如果占用者为 Web 服务, Certbot 申请可能失败)" N || die "已取消申请, 请释放 80 端口或使用已有证书。"
  fi
}

install_certbot_hook() {
  install -d -m 755 "$(dirname "$CERT_HOOK")"
  tee "$CERT_HOOK" >/dev/null <<'EOF'
#!/usr/bin/env bash
systemctl try-restart sing-box.service
EOF
  chmod 755 "$CERT_HOOK"
}

obtain_tls_paths() {
  local domain=$1 cert key choice
  cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  key="/etc/letsencrypt/live/${domain}/privkey.pem"
  if [[ -r $cert && -r $key ]]; then
    printf '%s|%s' "$cert" "$key"
    return 0
  fi
  printf "\nTLS 证书获取方式:\n  1) 使用 Certbot 自动签发 Let's Encrypt (需域名解析到本机且 80 端口开放)\n  2) 使用已有 PEM 证书路径\n" >&2
  read -r -p '选择 [1]: ' choice
  choice=${choice:-1}
  case $choice in
    1)
      check_port_80
      apt-get update -qq >&2
      apt-get install -y -qq certbot >&2
      open_firewall_port 80 tcp >&2
      info "正在签发 ${domain} 证书..." >&2
      certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$domain" >&2
      install_certbot_hook
      enable_certbot_autorenew >&2
      [[ -r $cert && -r $key ]] || die "证书文件生成失败。"
      ;;
    2)
      cert=$(ask_required "证书链 fullchain PEM 绝对路径")
      key=$(ask_required "私钥 privkey PEM 绝对路径")
      [[ -r $cert && -r $key ]] || die "证书或私钥文件不可读。"
      ;;
    *) die "无效的选择。" ;;
  esac
  printf '%s|%s' "$cert" "$key"
}

enable_certbot_autorenew() {
  command -v certbot >/dev/null 2>&1 || return 0
  if systemctl list-timers --all 2>/dev/null | grep -q certbot; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  else
    # 部分发行版无内建 timer, 补一个每日随机时间的 cron
    local cronfile="/etc/cron.d/sing-box-vps-certbot"
    tee "$cronfile" >/dev/null <<'EOF'
SHELL=/bin/bash
17 3 * * * root certbot renew --quiet --deploy-hook "systemctl try-restart sing-box.service"
EOF
    chmod 644 "$cronfile"
  fi
  ok "已启用 Certbot 自动续期。"
}

show_certificate_expiry() {
  ensure_installed
  local cert_path end_date
  local -a certs=()
  mapfile -t certs < <(jq -r '.inbounds[]? | .tls.certificate_path? // empty' "$CONFIG_FILE" | sort -u)
  if (( ${#certs[@]} == 0 )); then
    warn "当前配置中没有使用本地证书文件的 TLS 入站。"
    return 0
  fi
  printf '\n证书到期时间统计:\n'
  for cert_path in "${certs[@]}"; do
    if [[ -r $cert_path ]]; then
      end_date=$(openssl x509 -enddate -noout -in "$cert_path" | cut -d= -f2-)
      printf -- '- %s\n  到期时间: %s\n' "$cert_path" "$end_date"
    else
      warn "证书文件不可读: $cert_path"
    fi
  done
}

renew_certificate_now() {
  require_cmd certbot
  local domain
  domain=$(ask_required "要立即续期/重新申请的域名")
  valid_hostname "$domain" || die "域名格式不正确。"
  check_port_80
  open_firewall_port 80 tcp
  certbot certonly --standalone --non-interactive --agree-tos --force-renewal \
    --register-unsafely-without-email -d "$domain"
  install_certbot_hook
  systemctl try-restart sing-box || true
  ok "证书已重新签发: ${domain}"
}

cert_management_menu() {
  local choice
  while true; do
    title "证书管理"
    printf '  1) 查看证书到期时间\n'
    printf '  2) 立即续期 / 重新申请证书\n'
    printf '  3) 启用/检查 Certbot 自动续期\n'
    printf '  0) 返回主菜单\n'
    read -r -p '请选择: ' choice
    case $choice in
      1) show_certificate_expiry ;;
      2) renew_certificate_now ;;
      3) enable_certbot_autorenew ;;
      0) return 0 ;;
      *) warn "无效的编号选择。" ;;
    esac
  done
}
# ---------------------------------------------------------------------------
# 连接记录存取
# ---------------------------------------------------------------------------
save_connection() {
  local type=$1 tag=$2 host=$3 port=$4 uri=$5
  atomic_json_update "$STATE_FILE" \
    '.connections += [{type:$type, tag:$tag, host:$host, port:($port|tonumber), uri:$uri, created_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}]' \
    --arg type "$type" --arg tag "$tag" --arg host "$host" --arg port "$port" --arg uri "$uri" \
    || die "保存连接记录失败。"
}

# ---------------------------------------------------------------------------
# 二维码输出
# ---------------------------------------------------------------------------
show_qrcode() {
  local uri=$1 tag=${2:-node}
  if ! command -v qrencode >/dev/null 2>&1; then
    apt-get install -y -qq qrencode >/dev/null 2>&1 || true
  fi
  if command -v qrencode >/dev/null 2>&1; then
    printf '\n'
    qrencode -t ANSIUTF8 -m 1 <<<"$uri"
    qrencode -t PNG -o "${QR_CACHE_DIR}/${tag}.png" -m 1 <<<"$uri" 2>/dev/null || true
  else
    warn "qrencode 未安装, 已跳过二维码渲染。"
  fi
}

print_result_block() {
  local title=$1 uri=$2 tag=$3
  printf '\n%s 客户端连接串:\n%s\n' "$title" "$uri"
  show_qrcode "$uri" "$tag"
  printf '\n'
}

# ---------------------------------------------------------------------------
# 通用: 依据网络模式准备端口/监听/出站/tag 的前置流程
# deploy_prepare <label> <default_port> <tag_prefix> -> 通过全局变量返回
#   D_MODE D_LISTEN D_OUTBOUND D_PORT D_TAG D_HOST D_FORMATTED_HOST
# ---------------------------------------------------------------------------
declare -g D_MODE D_LISTEN D_OUTBOUND D_PORT D_TAG D_HOST D_FORMATTED_HOST

deploy_prepare_common() {
  local port_label=$1 default_port=$2 tag_prefix=$3 fixed_mode=${4:-}
  ensure_installed
  if [[ -n $fixed_mode ]]; then
    D_MODE=$fixed_mode
    case "$D_MODE" in
      v4) check_ipv4_egress || die "系统检测到 IPv4 外网不可用, 无法部署 IPv4 专用节点。" ;;
      v6) check_ipv6_egress || die "系统检测到 IPv6 外网不可用, 无法部署 IPv6 节点。" ;;
    esac
  else
    D_MODE=$(ask_node_network_mode)
  fi
  D_LISTEN=$(mode_listen_addr "$D_MODE")
  D_OUTBOUND=$(mode_outbound_tag "$D_MODE")
  D_PORT=$(ask_port "$port_label" "$default_port")
  D_TAG="${tag_prefix}-${D_MODE}-${D_PORT}"
  check_and_handle_existing_tag "$D_TAG" || return 1
  ensure_port_available "$D_PORT"
  D_HOST=$(ask_node_server "$D_MODE")
  D_FORMATTED_HOST=$(format_host_uri "$D_HOST")
  return 0
}

# 需要 TLS 域名(而非仅 Reality 握手伪装)的协议共用的域名+证书前置流程
deploy_prepare_tls_domain() {
  local default_port=$1 tag_prefix=$2
  D_MODE=$(ask_node_network_mode)
  D_LISTEN=$(mode_listen_addr "$D_MODE")
  D_OUTBOUND=$(mode_outbound_tag "$D_MODE")
  D_HOST=$(ask_hostname "TLS 绑定域名")
  D_FORMATTED_HOST=$(format_host_uri "$D_HOST")
  D_PORT=$(ask_port "监听端口" "$default_port")
  D_TAG="${tag_prefix}-${D_MODE}-${D_PORT}"
  check_and_handle_existing_tag "$D_TAG" || return 1
  ensure_port_available "$D_PORT"
  return 0
}

# ===========================================================================
# 协议部署函数
# ===========================================================================

deploy_vless_reality_unified() {
  local mode=${1:-}
  ensure_installed
  deploy_prepare_common "VLESS Reality 监听端口" 443 "reality" "$mode" || return 0

  local handshake keypair private_key public_key short_id uuid reality tls inbound uri flag
  handshake=$(ask_reality_handshake_domain)
  keypair=$(generate_reality_keypair)
  private_key=${keypair%%|*}; public_key=${keypair#*|}
  short_id=$(openssl rand -hex 4)
  uuid=$(new_uuid)

  reality=$(jq -n --arg handshake "$handshake" --arg private_key "$private_key" --arg short_id "$short_id" \
    '{enabled:true,handshake:{server:$handshake,server_port:443},private_key:$private_key,short_id:[$short_id]}')
  tls=$(jq -n --arg hs "$handshake" --argjson reality "$reality" '{enabled:true,server_name:$hs,reality:$reality}')
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg uuid "$uuid" --argjson tls "$tls" \
    '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",uuid:$uuid,flow:"xtls-rprx-vision"}],tls:$tls}')

  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"
  flag=$(get_server_flag)
  uri="vless://${uuid}@${D_FORMATTED_HOST}:${D_PORT}?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=${handshake}&fp=chrome&pbk=${public_key}&sid=${short_id}#${flag}%20Reality-${D_MODE}"
  save_connection "vless-reality-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" tcp
  ok "VLESS Reality (${D_MODE}) 已成功部署 (绑定出口: ${D_OUTBOUND})"
  print_result_block "VLESS Reality" "$uri" "$D_TAG"
}

deploy_vless_reality_grpc() {
  ensure_installed
  deploy_prepare_common "VLESS Reality gRPC 监听端口" 8443 "reality-grpc" || return 0

  local handshake keypair private_key public_key short_id uuid service_name reality tls inbound uri flag
  handshake=$(ask_reality_handshake_domain)
  service_name="grpc-$(openssl rand -hex 4)"
  keypair=$(generate_reality_keypair)
  private_key=${keypair%%|*}; public_key=${keypair#*|}
  short_id=$(openssl rand -hex 4)
  uuid=$(new_uuid)

  reality=$(jq -n --arg handshake "$handshake" --arg private_key "$private_key" --arg short_id "$short_id" \
    '{enabled:true,handshake:{server:$handshake,server_port:443},private_key:$private_key,short_id:[$short_id]}')
  tls=$(jq -n --arg hs "$handshake" --argjson reality "$reality" '{enabled:true,server_name:$hs,reality:$reality}')
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg uuid "$uuid" --arg svc "$service_name" --argjson tls "$tls" \
    '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",uuid:$uuid}],tls:$tls,transport:{type:"grpc",service_name:$svc}}')

  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"
  flag=$(get_server_flag)
  uri="vless://${uuid}@${D_FORMATTED_HOST}:${D_PORT}?encryption=none&security=reality&type=grpc&serviceName=${service_name}&sni=${handshake}&fp=chrome&pbk=${public_key}&sid=${short_id}#${flag}%20Reality-gRPC-${D_MODE}"
  save_connection "vless-reality-grpc-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" tcp
  ok "VLESS Reality gRPC (${D_MODE}) 已部署"
  print_result_block "VLESS Reality gRPC" "$uri" "$D_TAG"
}

deploy_shadowtls_ss2022() {
  ensure_installed
  deploy_prepare_common "ShadowTLS 公网监听端口" 443 "st3" || return 0

  local handshake st_password ss_key tag_ss inbound_st inbound_ss candidate encoded_ss uri flag
  handshake=$(ask_reality_handshake_domain)
  tag_ss="ss-inner-${D_PORT}"
  st_password=$(random_token)
  ss_key=$(random_ss_key)

  inbound_st=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg pwd "$st_password" --arg hs "$handshake" --arg detour "$tag_ss" \
    '{type:"shadowtls",tag:$tag,listen:$listen,listen_port:$port,version:3,users:[{password:$pwd}],handshake:{server:$hs,server_port:443},strict_mode:true,detour:$detour}')
  inbound_ss=$(jq -n --arg tag "$tag_ss" --arg key "$ss_key" \
    '{type:"shadowsocks",tag:$tag,method:"2022-blake3-aes-128-gcm",password:$key}')

  candidate=$(mktemp)
  jq --argjson inb_st "$inbound_st" --argjson inb_ss "$inbound_ss" --arg tag "$D_TAG" --arg outbound "$D_OUTBOUND" '
    .inbounds += [$inb_st, $inb_ss] |
    .route.rules += [{"inbound": [$tag], "outbound": $outbound}]
  ' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"

  encoded_ss=$(printf '%s' "2022-blake3-aes-128-gcm:${ss_key}" | base64 -w 0)
  flag=$(get_server_flag)
  uri="ss://${encoded_ss}@${D_FORMATTED_HOST}:${D_PORT}?plugin=shadow-tls%3Bhost%3D${handshake}%3Bpassword%3D${st_password}%3Bversion%3D3#${flag}%20ShadowTLS-SS2022-${D_MODE}"
  save_connection "shadowtls-v3-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" tcp
  ok "ShadowTLS v3 + SS2022 (${D_MODE}) 已部署"
  print_result_block "ShadowTLS v3 + SS2022" "$uri" "$D_TAG"
}

deploy_shadowsocks() {
  ensure_installed
  deploy_prepare_common "Shadowsocks 2022 监听端口" 8443 "ss2022" || return 0

  local key inbound encoded uri flag
  key=$(random_ss_key)
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg key "$key" \
    '{type:"shadowsocks",tag:$tag,listen:$listen,listen_port:$port,method:"2022-blake3-aes-128-gcm",password:$key,multiplex:{enabled:true}}')
  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"

  encoded=$(printf '%s' "2022-blake3-aes-128-gcm:${key}" | base64 -w 0)
  flag=$(get_server_flag)
  uri="ss://${encoded}@${D_FORMATTED_HOST}:${D_PORT}#${flag}%20SS2022-${D_MODE}"
  save_connection "shadowsocks-2022-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" tcp
  open_firewall_port "$D_PORT" udp
  ok "Shadowsocks 2022 (${D_MODE}) 已部署"
  print_result_block "Shadowsocks 2022" "$uri" "$D_TAG"
}

deploy_trojan() {
  ensure_installed
  deploy_prepare_tls_domain 443 "trojan" || return 0

  local paths cert key password tls inbound uri flag
  paths=$(obtain_tls_paths "$D_HOST")
  cert=${paths%%|*}; key=${paths#*|}
  password=$(random_token)

  tls=$(tls_json "$D_HOST" "$cert" "$key")
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg password "$password" --argjson tls "$tls" \
    '{type:"trojan",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",password:$password}],tls:$tls}')
  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"

  flag=$(get_server_flag)
  uri="trojan://${password}@${D_FORMATTED_HOST}:${D_PORT}?security=tls&sni=${D_HOST}&type=tcp#${flag}%20Trojan-${D_MODE}"
  save_connection "trojan-tls-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" tcp
  ok "Trojan TLS (${D_MODE}) 已部署"
  print_result_block "Trojan TLS" "$uri" "$D_TAG"
}

deploy_vless() {
  ensure_installed
  deploy_prepare_tls_domain 8443 "vless" || return 0

  local paths cert key uuid tls inbound uri flag
  paths=$(obtain_tls_paths "$D_HOST")
  cert=${paths%%|*}; key=${paths#*|}
  uuid=$(new_uuid)

  tls=$(tls_json "$D_HOST" "$cert" "$key")
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg uuid "$uuid" --argjson tls "$tls" \
    '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",uuid:$uuid}],tls:$tls}')
  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"

  flag=$(get_server_flag)
  uri="vless://${uuid}@${D_FORMATTED_HOST}:${D_PORT}?encryption=none&security=tls&type=tcp&sni=${D_HOST}#${flag}%20VLESS-${D_MODE}"
  save_connection "vless-tls-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" tcp
  ok "VLESS TLS (${D_MODE}) 已部署"
  print_result_block "VLESS TLS" "$uri" "$D_TAG"
}

deploy_hysteria2() {
  ensure_installed
  deploy_prepare_tls_domain 8443 "hy2" || return 0

  local paths cert key password obfs_password tls inbound uri flag
  paths=$(obtain_tls_paths "$D_HOST")
  cert=${paths%%|*}; key=${paths#*|}
  password=$(random_token)
  obfs_password=$(random_token)

  tls=$(tls_json "$D_HOST" "$cert" "$key")
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg password "$password" --arg obfs "$obfs_password" --argjson tls "$tls" \
    '{type:"hysteria2",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",password:$password}],obfs:{type:"salamander",password:$obfs},tls:$tls}')
  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"

  flag=$(get_server_flag)
  uri="hysteria2://${password}@${D_FORMATTED_HOST}:${D_PORT}?sni=${D_HOST}&obfs=salamander&obfs-password=${obfs_password}#${flag}%20Hysteria2-${D_MODE}"
  save_connection "hysteria2-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" udp
  ok "Hysteria2 (${D_MODE}) 已部署"
  print_result_block "Hysteria2" "$uri" "$D_TAG"
}

deploy_tuic() {
  ensure_installed
  deploy_prepare_tls_domain 8443 "tuic" || return 0

  local paths cert key uuid password tls inbound uri flag
  paths=$(obtain_tls_paths "$D_HOST")
  cert=${paths%%|*}; key=${paths#*|}
  uuid=$(new_uuid)
  password=$(random_token)

  tls=$(tls_json "$D_HOST" "$cert" "$key")
  inbound=$(jq -n --arg tag "$D_TAG" --arg listen "$D_LISTEN" --argjson port "$D_PORT" --arg uuid "$uuid" --arg password "$password" --argjson tls "$tls" \
    '{type:"tuic",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",uuid:$uuid,password:$password}],congestion_control:"bbr",zero_rtt_handshake:false,tls:$tls}')
  apply_inbound_with_route "$inbound" "$D_TAG" "$D_OUTBOUND"

  flag=$(get_server_flag)
  uri="tuic://${uuid}:${password}@${D_FORMATTED_HOST}:${D_PORT}?congestion_control=bbr&sni=${D_HOST}#${flag}%20TUIC-${D_MODE}"
  save_connection "tuic-${D_MODE}" "$D_TAG" "$D_HOST" "$D_PORT" "$uri"
  open_firewall_port "$D_PORT" udp
  ok "TUIC (${D_MODE}) 已部署"
  print_result_block "TUIC" "$uri" "$D_TAG"
}
# ===========================================================================
# Cloudflare Tunnel (config.yml + ingress, 而非仅 quick "service install")
# ===========================================================================
readonly CF_TUNNEL_STATE="${STATE_DIR}/cf_tunnel.json"

cf_state_init() {
  ensure_dirs
  [[ -f $CF_TUNNEL_STATE ]] || printf '{"tunnels":[]}\n' > "$CF_TUNNEL_STATE"
}

install_cloudflared() {
  require_apt
  info "配置 Cloudflare 官方 cloudflared APT 源"
  install -d -m 755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
  tee /etc/apt/sources.list.d/cloudflared.list >/dev/null <<'EOF'
deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main
EOF
  apt-get update -qq
  apt-get install -y -qq cloudflared
  install -d -m 700 "$CF_CONFIG_DIR" "$CF_CRED_DIR"
}

ensure_cloudflared_installed() {
  command -v cloudflared >/dev/null 2>&1 || install_cloudflared
  install -d -m 700 "$CF_CONFIG_DIR" "$CF_CRED_DIR"
}

# 使用 config.yml + ingress 规则的正式部署方式 (而非裸 quick tunnel)
deploy_cloudflare_tunnel() {
  ensure_installed
  ensure_cloudflared_installed
  cf_state_init

  local domain port path path_encoded uuid tag inbound candidate uri flag
  local tunnel_id tunnel_name cred_file tunnel_token use_token

  domain=$(ask_hostname "Cloudflare 托管域名 (例如 cf.example.com)")
  port=$(ask_port "本地 VLESS WebSocket 端口 (仅监听 127.0.0.1)" 10000)
  ensure_port_available "$port"
  path=$(random_path)
  uuid=$(new_uuid)
  tag="vless-ws-cf-${port}"
  check_and_handle_existing_tag "$tag" || return 0

  printf "\nTunnel 接入方式:\n" >&2
  printf "  1) 已在 Zero Trust 后台创建 Tunnel 并拿到 Token (推荐, 快速接入)\n" >&2
  printf "  2) 使用 cloudflared tunnel create 在本机新建 Tunnel (需已 cloudflared login)\n" >&2
  read -r -p "请选择 [1]: " use_token
  use_token=${use_token:-1}

  if [[ $use_token == 1 ]]; then
    read -r -s -p "Cloudflare Tunnel Token (输入不回显): " tunnel_token
    printf '\n'
    [[ -n $tunnel_token ]] || die "Tunnel Token 不能为空。"
    info "注册并启动 cloudflared 系统服务 (token 模式)..."
    cloudflared service install "$tunnel_token"
    tunnel_name="token-${port}"
  else
    require_cmd cloudflared
    [[ -f /root/.cloudflared/cert.pem || -f "${HOME}/.cloudflared/cert.pem" ]] || {
      warn "未检测到 cloudflared 登录凭证。"
      info "请在浏览器完成授权: 即将执行 'cloudflared tunnel login'"
      cloudflared tunnel login
    }
    tunnel_name="sbvps-$(openssl rand -hex 3)"
    cloudflared tunnel create "$tunnel_name" | tee /tmp/cf_tunnel_create.out
    tunnel_id=$(awk -F'[()]' '/Created tunnel/ {print $0}' /tmp/cf_tunnel_create.out | grep -oE '[0-9a-f-]{36}' | head -n1)
    [[ -n $tunnel_id ]] || tunnel_id=$(cloudflared tunnel list -o json 2>/dev/null | jq -r --arg n "$tunnel_name" '.[] | select(.name==$n) | .id' | head -n1)
    [[ -n $tunnel_id ]] || die "无法解析新建 Tunnel 的 ID。"
    cred_file=$(find /root/.cloudflared "${HOME}/.cloudflared" -maxdepth 1 -name "${tunnel_id}.json" 2>/dev/null | head -n1)
    [[ -n $cred_file ]] || die "未找到 Tunnel 凭证文件 ${tunnel_id}.json。"
    install -m 600 "$cred_file" "${CF_CRED_DIR}/${tunnel_id}.json"

    cloudflared tunnel route dns "$tunnel_name" "$domain" || warn "自动创建 DNS 记录失败, 请手动在 Cloudflare 后台添加 CNAME。"

    local candidate_yml
    candidate_yml=$(mktemp)
    cat > "$candidate_yml" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${CF_CRED_DIR}/${tunnel_id}.json
ingress:
  - hostname: ${domain}
    service: http://127.0.0.1:${port}
  - service: http_status:404
EOF
    atomic_install "$candidate_yml" "$CF_CONFIG_FILE" 600
    rm -f "$candidate_yml"

    tee /etc/systemd/system/cloudflared.service >/dev/null <<EOF
[Unit]
Description=cloudflared (sing-box-vps managed)
After=network.target

[Service]
Type=notify
ExecStart=/usr/bin/cloudflared --config ${CF_CONFIG_FILE} tunnel run ${tunnel_id}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi

  systemctl enable --now cloudflared
  sleep 2
  systemctl is-active --quiet cloudflared || die "cloudflared 服务启动失败, 请检查 journalctl -u cloudflared。"

  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" \
    '{type:"vless",tag:$tag,listen:"127.0.0.1",listen_port:$port,users:[{name:"default",uuid:$uuid}],transport:{type:"ws",path:$path}}')
  candidate=$(mktemp)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"

  atomic_json_update "$CF_TUNNEL_STATE" \
    '.tunnels += [{name:$name, domain:$domain, port:($port|tonumber), tag:$tag, created_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}]' \
    --arg name "$tunnel_name" --arg domain "$domain" --arg port "$port" --arg tag "$tag" || true

  path_encoded=$(jq -nr --arg path "$path" '$path | @uri')
  flag=$(get_server_flag)
  uri="vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=${path_encoded}&sni=${domain}#${flag}%20CF-Tunnel"
  save_connection "vless-ws-cloudflare-tunnel" "$tag" "$domain" 443 "$uri"
  ok "Cloudflare Tunnel 与本地 VLESS WS 部署完成"
  print_result_block "Cloudflare Tunnel + VLESS WS" "$uri" "$tag"
}

cf_tunnel_status() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    warn "cloudflared 尚未安装。"
    return 0
  fi
  cloudflared --version
  systemctl --no-pager --full status cloudflared || true
  [[ -f $CF_CONFIG_FILE ]] && { printf '\n当前 ingress 配置:\n'; cat "$CF_CONFIG_FILE"; }
}

cf_tunnel_logs() { journalctl -u cloudflared -n 150 --no-pager -o cat; }

cf_tunnel_restart() {
  systemctl restart cloudflared && ok "cloudflared 已重启。" || warn "cloudflared 重启失败, 请查看日志。"
}

cf_tunnel_stop() {
  systemctl stop cloudflared && ok "cloudflared 已停止。" || warn "cloudflared 停止失败。"
}

cf_tunnel_uninstall() {
  confirm "确认卸载 cloudflared 并移除其配置" N || return 0
  systemctl disable --now cloudflared 2>/dev/null || true
  apt-get remove -y -qq cloudflared 2>/dev/null || true
  rm -rf "$CF_CONFIG_DIR"
  rm -f /etc/systemd/system/cloudflared.service
  systemctl daemon-reload
  ok "cloudflared 已卸载, 相关配置已清理。"
}

cf_tunnel_rebind_token() {
  read -r -s -p "新的 Cloudflare Tunnel Token (输入不回显): " tunnel_token
  printf '\n'
  [[ -n $tunnel_token ]] || die "Token 不能为空。"
  systemctl stop cloudflared 2>/dev/null || true
  cloudflared service uninstall 2>/dev/null || true
  cloudflared service install "$tunnel_token"
  systemctl enable --now cloudflared
  ok "已重新绑定 Tunnel Token 并重启服务。"
}

cf_tunnel_menu() {
  local choice
  while true; do
    title "Cloudflare Tunnel 管理"
    printf '  1) 新建 Cloudflare Tunnel + VLESS WS 节点\n'
    printf '  2) 查看状态\n'
    printf '  3) 查看日志\n'
    printf '  4) 重启\n'
    printf '  5) 停止\n'
    printf '  6) 重新绑定 Token\n'
    printf '  7) 卸载\n'
    printf '  0) 返回主菜单\n'
    read -r -p '请选择: ' choice
    case $choice in
      1) deploy_cloudflare_tunnel ;;
      2) cf_tunnel_status ;;
      3) cf_tunnel_logs ;;
      4) cf_tunnel_restart ;;
      5) cf_tunnel_stop ;;
      6) cf_tunnel_rebind_token ;;
      7) cf_tunnel_uninstall ;;
      0) return 0 ;;
      *) warn "无效的编号选择。" ;;
    esac
  done
}
# ===========================================================================
# Cloudflare WARP 出站集成
# 实现方式: 官方 cloudflare-warp 客户端 (warp-cli), 以 proxy 模式在本机
# 127.0.0.1:40000 暴露 SOCKS5, 再作为 sing-box 的 socks 出站接入路由,
# 避免直接接管整机路由表, 对宿主机其余服务零侵入。
# ===========================================================================
readonly WARP_SOCKS_PORT=40000
readonly WARP_OUTBOUND_TAG="warp-out"

install_warp_client() {
  require_apt
  info "配置 Cloudflare WARP 官方 APT 源"
  install -d -m 755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  local codename
  codename=$(lsb_release -cs 2>/dev/null || echo "jammy")
  tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null <<EOF
deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main
EOF
  apt-get update -qq
  apt-get install -y -qq cloudflare-warp
}

warp_ensure_registered() {
  systemctl enable --now warp-svc >/dev/null 2>&1 || true
  sleep 2
  if ! warp-cli --accept-tos status >/dev/null 2>&1; then
    warp-cli --accept-tos registration new >/dev/null 2>&1 || true
  fi
}

warp_set_mode() {
  # mode: v4 | v6 | dual  (WARP 客户端本身仅支持整体代理模式, 这里通过
  # sing-box 出站规则决定哪些流量走 WARP, WARP 自身固定跑 proxy 模式)
  local mode=$1
  warp-cli --accept-tos mode proxy >/dev/null 2>&1 || true
  warp-cli --accept-tos proxy port "$WARP_SOCKS_PORT" >/dev/null 2>&1 || true
  case "$mode" in
    v4) warp-cli --accept-tos tunnel protocol set wireguard >/dev/null 2>&1 || true ;;
    *) : ;;
  esac
  warp-cli --accept-tos connect >/dev/null 2>&1 || true
}

install_warp() {
  ensure_installed
  command -v warp-cli >/dev/null 2>&1 || install_warp_client
  warp_ensure_registered

  local mode
  printf "\n选择 WARP 出站模式:\n" >&2
  printf "  1) 双栈 WARP (IPv4 + IPv6)\n" >&2
  printf "  2) IPv4 WARP\n" >&2
  printf "  3) IPv6 WARP\n" >&2
  read -r -p "请选择 [1]: " mode
  mode=${mode:-1}
  case $mode in
    2) mode=v4 ;;
    3) mode=v6 ;;
    *) mode=dual ;;
  esac
  warp_set_mode "$mode"
  sleep 2

  if ! warp-cli --accept-tos status 2>/dev/null | grep -qi "Connected"; then
    warn "WARP 客户端未能确认 Connected 状态, 请稍后使用 'sb' 菜单中的 WARP 状态查看。"
  fi

  local candidate
  candidate=$(mktemp)
  jq --arg tag "$WARP_OUTBOUND_TAG" --argjson port "$WARP_SOCKS_PORT" '
    if (.outbounds | map(select(.tag == $tag)) | length) == 0 then
      .outbounds += [{type:"socks", tag:$tag, server:"127.0.0.1", server_port:$port, version:"5"}]
    else . end
  ' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"

  ok "WARP 已安装并以 SOCKS5 (127.0.0.1:${WARP_SOCKS_PORT}) 接入 sing-box 出站 [${WARP_OUTBOUND_TAG}]。"
  info "可在部署节点或编辑路由规则时, 将出站指向 '${WARP_OUTBOUND_TAG}' 以让该节点流量经由 WARP。"
}

warp_status() {
  if ! command -v warp-cli >/dev/null 2>&1; then
    warn "WARP 客户端尚未安装。"
    return 0
  fi
  warp-cli --accept-tos status || true
  printf '\nsing-box 内 WARP 出站配置:\n'
  jq -r --arg tag "$WARP_OUTBOUND_TAG" '.outbounds[]? | select(.tag==$tag)' "$CONFIG_FILE" 2>/dev/null || true
}

warp_switch_mode() {
  command -v warp-cli >/dev/null 2>&1 || die "请先安装 WARP。"
  local mode
  printf "\n选择新的 WARP 模式:\n1) 双栈  2) IPv4  3) IPv6\n"
  read -r -p "请选择 [1]: " mode
  case ${mode:-1} in
    2) warp_set_mode v4 ;;
    3) warp_set_mode v6 ;;
    *) warp_set_mode dual ;;
  esac
  ok "WARP 模式已切换。"
}

uninstall_warp() {
  confirm "确认卸载 WARP 客户端并移除其 sing-box 出站" N || return 0
  systemctl disable --now warp-svc 2>/dev/null || true
  apt-get remove -y -qq cloudflare-warp 2>/dev/null || true
  atomic_json_update "$CONFIG_FILE" --arg tag "$WARP_OUTBOUND_TAG" \
    '.outbounds |= map(select(.tag != $tag))' || true
  systemctl restart sing-box 2>/dev/null || true
  ok "WARP 已卸载。"
}

warp_menu() {
  local choice
  while true; do
    title "Cloudflare WARP 管理"
    printf '  1) 安装 WARP\n'
    printf '  2) 查看状态\n'
    printf '  3) 切换模式 (IPv4/IPv6/双栈)\n'
    printf '  4) 卸载 WARP\n'
    printf '  0) 返回主菜单\n'
    read -r -p '请选择: ' choice
    case $choice in
      1) install_warp ;;
      2) warp_status ;;
      3) warp_switch_mode ;;
      4) uninstall_warp ;;
      0) return 0 ;;
      *) warn "无效的编号选择。" ;;
    esac
  done
}

# ===========================================================================
# 测速: 延迟 + 下载 + 上传 (Cloudflare / Google / Microsoft)
# ===========================================================================
_speedtest_one() {
  local name=$1 dl_url=$2 ul_url=$3 latency_host=$4
  local latency dl_bps dl_mbps ul_bps ul_mbps

  printf '\n--- %s ---\n' "$name"
  latency=$(curl -o /dev/null -s --connect-timeout 3 --max-time 5 \
    -w '%{time_connect}' "https://${latency_host}/" 2>/dev/null || echo "N/A")
  if [[ $latency != "N/A" ]]; then
    printf '延迟: %s ms\n' "$(awk -v t="$latency" 'BEGIN{printf "%.1f", t*1000}')"
  else
    printf '延迟: 测量失败\n'
  fi

  dl_bps=$(curl -o /dev/null -s --max-time 10 -w '%{speed_download}' "$dl_url" 2>/dev/null || echo 0)
  dl_mbps=$(awk -v b="$dl_bps" 'BEGIN{printf "%.2f", (b*8)/1000000}')
  printf '下载速度: %s Mbps\n' "$dl_mbps"

  if [[ -n $ul_url ]]; then
    local tmpfile
    tmpfile=$(mktemp)
    dd if=/dev/urandom of="$tmpfile" bs=1M count=8 >/dev/null 2>&1
    ul_bps=$(curl -o /dev/null -s --max-time 15 -w '%{speed_upload}' -X POST --data-binary "@${tmpfile}" "$ul_url" 2>/dev/null || echo 0)
    ul_mbps=$(awk -v b="$ul_bps" 'BEGIN{printf "%.2f", (b*8)/1000000}')
    printf '上传速度: %s Mbps\n' "$ul_mbps"
    rm -f "$tmpfile"
  fi
}

run_speedtest() {
  require_cmd curl awk
  info "开始测速 (依次测试 Cloudflare / Google / Microsoft, 可能耗时较久)..."
  _speedtest_one "Cloudflare" "https://speed.cloudflare.com/__down?bytes=104857600" \
    "https://speed.cloudflare.com/__up" "speed.cloudflare.com"
  _speedtest_one "Google" "https://dl.google.com/dl/android/studio/install/latest/android-studio-linux.tar.gz" \
    "" "www.google.com"
  _speedtest_one "Microsoft" "https://download.microsoft.com/download/speedtest/dummy" \
    "" "www.microsoft.com"
  printf '\n'
  ok "测速完成。"
}

# ===========================================================================
# 系统诊断
# ===========================================================================
diag_check_ports() {
  printf '\n[端口占用]\n'
  if [[ -f $CONFIG_FILE ]]; then
    jq -r '.inbounds[]? | select(.listen_port != null) | "\(.listen_port)"' "$CONFIG_FILE" | sort -u | while read -r p; do
      if command -v ss >/dev/null 2>&1 && ss -tulnH "sport = :$p" 2>/dev/null | grep -q .; then
        printf "  端口 %s: ${GREEN}监听中${NC}\n" "$p"
      else
        printf "  端口 %s: ${RED}未监听 (异常)${NC}\n" "$p"
      fi
    done
  fi
}

diag_check_dns() {
  printf '\n[DNS 解析]\n'
  if command -v dig >/dev/null 2>&1; then
    dig +short example.com A 2>/dev/null | head -3 || printf '  DNS 解析失败\n'
  else
    getent hosts example.com || printf '  DNS 解析失败\n'
  fi
}

diag_check_network() {
  printf '\n[网络栈]\n'
  printf '  IPv4 出网: %s\n' "$(check_ipv4_egress && echo 可用 || echo 不可用)"
  printf '  IPv6 出网: %s\n' "$(check_ipv6_egress && echo 可用 || echo 不可用)"
}

diag_check_bbr() {
  printf '\n[BBR / 拥塞控制]\n'
  printf '  当前算法: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"
  printf '  队列规则: %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo 未知)"
}

diag_check_firewall() {
  printf '\n[防火墙]\n'
  if command -v ufw >/dev/null 2>&1; then
    printf '  UFW: %s\n' "$(ufw status 2>/dev/null | head -1)"
  else
    printf '  UFW: 未安装\n'
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    printf '  firewalld: %s\n' "$(systemctl is-active firewalld 2>/dev/null || echo 未运行)"
  fi
}

diag_check_cloudflared() {
  printf '\n[Cloudflare Tunnel]\n'
  if command -v cloudflared >/dev/null 2>&1; then
    printf '  已安装: %s\n' "$(cloudflared --version 2>/dev/null | head -1)"
    printf '  服务状态: %s\n' "$(systemctl is-active cloudflared 2>/dev/null || echo 未运行)"
  else
    printf '  未安装\n'
  fi
}

diag_check_singbox() {
  printf '\n[sing-box 配置与服务]\n'
  if command -v sing-box >/dev/null 2>&1; then
    printf '  版本: %s\n' "$(sing-box version | head -1)"
    if sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then
      printf '  配置语法: 通过\n'
    else
      printf "  配置语法: ${RED}失败${NC}\n"
    fi
    printf '  服务状态: %s\n' "$(systemctl is-active sing-box 2>/dev/null || echo 未运行)"
  else
    printf '  sing-box 未安装\n'
  fi
}

run_diagnostics() {
  ensure_installed
  title "系统诊断"
  diag_check_ports
  diag_check_dns
  diag_check_network
  diag_check_bbr
  diag_check_firewall
  diag_check_cloudflared
  diag_check_singbox
  printf '\n'
  ok "诊断完成。"
}
# ===========================================================================
# 订阅系统
# 生成三类订阅文件到 SUB_DIR:
#   sub-singbox.json   sing-box 客户端可直接导入的 outbounds 片段
#   sub-clash.yaml      Clash Meta / Mihomo 通用 YAML
#   sub-universal.txt   Base64 编码的 vless/ss/trojan/hy2/tuic URI 列表
#                         (Shadowrocket / v2rayN / NekoBox 等通用订阅格式)
# 可选启动一个仅监听 127.0.0.1 的 python3 http.server 供 nginx/反代转发,
# 或直接用本机文件路径自行分发, 不强制暴露公网端口。
# ===========================================================================
readonly SUB_PORT_DEFAULT=28080

sub_collect_uris() {
  jq -r '.connections[]?.uri' "$STATE_FILE" 2>/dev/null
}

sub_build_universal() {
  ensure_dirs
  local out="${SUB_DIR}/sub-universal.txt" tmp
  tmp=$(mktemp)
  sub_collect_uris > "$tmp"
  if [[ ! -s $tmp ]]; then
    rm -f "$tmp"
    warn "尚无任何节点记录, 无法生成订阅。"
    return 1
  fi
  base64 -w 0 "$tmp" > "${out}.tmp"
  mv -f "${out}.tmp" "$out"
  chmod 600 "$out"
  rm -f "$tmp"
  printf '%s' "$out"
}

sub_build_singbox_json() {
  ensure_dirs
  local out="${SUB_DIR}/sub-singbox.json" tmp
  tmp=$(mktemp)
  # 直接复用生产 config.json 的 outbounds 中非 direct/block/warp 的节点定义是不现实的
  # (inbound 与 outbound 结构不同), 这里改为逐条把已保存 URI 转成 sing-box outbound JSON。
  jq -n '{outbounds: []}' > "$tmp"
  while IFS= read -r uri; do
    [[ -z $uri ]] && continue
    local ob
    ob=$(uri_to_singbox_outbound "$uri" || true)
    [[ -n $ob ]] || continue
    jq --argjson ob "$ob" '.outbounds += [$ob]' "$tmp" > "${tmp}.n" && mv "${tmp}.n" "$tmp"
  done < <(sub_collect_uris)
  json_validate "$tmp" || { rm -f "$tmp"; die "生成 sing-box 订阅 JSON 失败。"; }
  atomic_install "$tmp" "$out" 600
  rm -f "$tmp"
  printf '%s' "$out"
}

# 极简 URI -> sing-box outbound 解析器, 覆盖本脚本自身生成的 vless/ss/trojan/hy2/tuic URI
uri_to_singbox_outbound() {
  local uri=$1 scheme rest tag
  scheme=${uri%%://*}
  rest=${uri#*://}
  tag=$(printf '%s' "$uri" | sed -n 's/.*#\(.*\)$/\1/p')
  tag=$(python3 -c "import urllib.parse,sys; print(urllib.parse.unquote(sys.argv[1]))" "${tag:-node}" 2>/dev/null || printf '%s' "${tag:-node}")
  case "$scheme" in
    vless)
      local userinfo hostport query uuid host port sni pbk sid flow security stype svc path
      userinfo=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      uuid=$userinfo
      host=${hostport%:*}; port=${hostport##*:}
      security=$(printf '%s' "$query" | grep -oE 'security=[^&]*' | cut -d= -f2)
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      pbk=$(printf '%s' "$query" | grep -oE 'pbk=[^&]*' | cut -d= -f2)
      sid=$(printf '%s' "$query" | grep -oE 'sid=[^&]*' | cut -d= -f2)
      flow=$(printf '%s' "$query" | grep -oE 'flow=[^&]*' | cut -d= -f2)
      stype=$(printf '%s' "$query" | grep -oE 'type=[^&]*' | cut -d= -f2)
      svc=$(printf '%s' "$query" | grep -oE 'serviceName=[^&]*' | cut -d= -f2)
      path=$(printf '%s' "$query" | grep -oE 'path=[^&]*' | cut -d= -f2)
      jq -n --arg tag "$tag" --arg host "$host" --argjson port "${port:-443}" --arg uuid "$uuid" \
        --arg security "$security" --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" --arg flow "$flow" \
        --arg stype "$stype" --arg svc "$svc" --arg path "$path" '
        {type:"vless", tag:$tag, server:$host, server_port:$port, uuid:$uuid} +
        (if $flow != "" then {flow:$flow} else {} end) +
        (if $security == "reality" then
          {tls:{enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:"chrome"},
                reality:{enabled:true, public_key:$pbk, short_id:$sid}}}
         elif $security == "tls" then
          {tls:{enabled:true, server_name:$sni}}
         else {} end) +
        (if $stype == "grpc" then {transport:{type:"grpc", service_name:$svc}}
         elif $stype == "ws" then {transport:{type:"ws", path:$path}}
         else {} end)
      ' 2>/dev/null
      ;;
    trojan)
      local password hostport query host port sni
      password=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      jq -n --arg tag "$tag" --arg host "$host" --argjson port "${port:-443}" --arg password "$password" --arg sni "$sni" \
        '{type:"trojan", tag:$tag, server:$host, server_port:$port, password:$password, tls:{enabled:true, server_name:$sni}}' 2>/dev/null
      ;;
    ss)
      local b64 hostport host port method pass decoded
      b64=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; hostport=${hostport%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      valid_port "$port" || return 1
      decoded=$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)
      method=${decoded%%:*}; pass=${decoded#*:}
      [[ -n $method && -n $pass ]] || return 1
      jq -n --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg method "$method" --arg pass "$pass" \
        '{type:"shadowsocks", tag:$tag, server:$host, server_port:$port, method:$method, password:$pass}' 2>/dev/null
      ;;
    hysteria2)
      local password hostport query host port sni obfs
      password=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      obfs=$(printf '%s' "$query" | grep -oE 'obfs-password=[^&]*' | cut -d= -f2)
      jq -n --arg tag "$tag" --arg host "$host" --argjson port "${port:-443}" --arg password "$password" --arg sni "$sni" --arg obfs "$obfs" \
        '{type:"hysteria2", tag:$tag, server:$host, server_port:$port, password:$password,
          obfs:{type:"salamander", password:$obfs}, tls:{enabled:true, server_name:$sni}}' 2>/dev/null
      ;;
    tuic)
      local cred hostport query host port sni uuid password
      cred=${rest%%@*}; rest=${rest#*@}
      uuid=${cred%%:*}; password=${cred#*:}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      jq -n --arg tag "$tag" --arg host "$host" --argjson port "${port:-443}" --arg uuid "$uuid" --arg password "$password" --arg sni "$sni" \
        '{type:"tuic", tag:$tag, server:$host, server_port:$port, uuid:$uuid, password:$password,
          congestion_control:"bbr", tls:{enabled:true, server_name:$sni}}' 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

sub_build_clash_yaml() {
  ensure_dirs
  local out="${SUB_DIR}/sub-clash.yaml" tmp
  tmp=$(mktemp)
  {
    printf 'proxies:\n'
    while IFS= read -r uri; do
      [[ -z $uri ]] && continue
      clash_proxy_yaml_from_uri "$uri" || true
    done < <(sub_collect_uris)
    printf 'proxy-groups:\n'
    printf '  - name: PROXY\n'
    printf '    type: select\n'
    printf '    proxies:\n'
    while IFS= read -r uri; do
      [[ -z $uri ]] && continue
      local name
      name=$(printf '%s' "$uri" | sed -n 's/.*#\(.*\)$/\1/p')
      name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.unquote(sys.argv[1]))" "${name:-node}" 2>/dev/null || printf '%s' "${name:-node}")
      printf '      - "%s"\n' "$name"
    done < <(sub_collect_uris)
    printf 'rules:\n  - MATCH,PROXY\n'
  } > "$tmp"
  atomic_install "$tmp" "$out" 600
  rm -f "$tmp"
  printf '%s' "$out"
}

clash_proxy_yaml_from_uri() {
  local uri=$1 scheme rest name
  scheme=${uri%%://*}; rest=${uri#*://}
  name=$(printf '%s' "$uri" | sed -n 's/.*#\(.*\)$/\1/p')
  name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.unquote(sys.argv[1]))" "${name:-node}" 2>/dev/null || printf '%s' "${name:-node}")
  case "$scheme" in
    vless)
      local userinfo hostport query uuid host port sni pbk sid flow security stype svc path
      userinfo=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      uuid=$userinfo; host=${hostport%:*}; port=${hostport##*:}
      security=$(printf '%s' "$query" | grep -oE 'security=[^&]*' | cut -d= -f2)
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      pbk=$(printf '%s' "$query" | grep -oE 'pbk=[^&]*' | cut -d= -f2)
      sid=$(printf '%s' "$query" | grep -oE 'sid=[^&]*' | cut -d= -f2)
      flow=$(printf '%s' "$query" | grep -oE 'flow=[^&]*' | cut -d= -f2)
      stype=$(printf '%s' "$query" | grep -oE 'type=[^&]*' | cut -d= -f2)
      svc=$(printf '%s' "$query" | grep -oE 'serviceName=[^&]*' | cut -d= -f2)
      printf '  - name: "%s"\n    type: vless\n    server: %s\n    port: %s\n    uuid: %s\n    network: %s\n' \
        "$name" "$host" "$port" "$uuid" "${stype:-tcp}"
      [[ -n $flow ]] && printf '    flow: %s\n' "$flow"
      if [[ $security == reality ]]; then
        printf '    tls: true\n    servername: %s\n    client-fingerprint: chrome\n    reality-opts:\n      public-key: %s\n      short-id: "%s"\n' \
          "$sni" "$pbk" "$sid"
      elif [[ $security == tls ]]; then
        printf '    tls: true\n    servername: %s\n' "$sni"
      fi
      [[ $stype == grpc ]] && printf '    grpc-opts:\n      grpc-service-name: %s\n' "$svc"
      ;;
    trojan)
      local password hostport query host port sni
      password=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      printf '  - name: "%s"\n    type: trojan\n    server: %s\n    port: %s\n    password: %s\n    sni: %s\n' \
        "$name" "$host" "$port" "$password" "$sni"
      ;;
    ss)
      local b64 hostport host port decoded method pass
      b64=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; hostport=${hostport%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      decoded=$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)
      method=${decoded%%:*}; pass=${decoded#*:}
      printf '  - name: "%s"\n    type: ss\n    server: %s\n    port: %s\n    cipher: %s\n    password: "%s"\n' \
        "$name" "$host" "$port" "$method" "$pass"
      ;;
    hysteria2)
      local password hostport query host port sni obfs
      password=${rest%%@*}; rest=${rest#*@}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      obfs=$(printf '%s' "$query" | grep -oE 'obfs-password=[^&]*' | cut -d= -f2)
      printf '  - name: "%s"\n    type: hysteria2\n    server: %s\n    port: %s\n    password: "%s"\n    sni: %s\n    obfs: salamander\n    obfs-password: "%s"\n' \
        "$name" "$host" "$port" "$password" "$sni" "$obfs"
      ;;
    tuic)
      local cred hostport query host port sni uuid password
      cred=${rest%%@*}; rest=${rest#*@}
      uuid=${cred%%:*}; password=${cred#*:}
      hostport=${rest%%\?*}; query=${rest#*\?}; query=${query%%#*}
      host=${hostport%:*}; port=${hostport##*:}
      sni=$(printf '%s' "$query" | grep -oE 'sni=[^&]*' | cut -d= -f2)
      printf '  - name: "%s"\n    type: tuic\n    server: %s\n    port: %s\n    uuid: %s\n    password: "%s"\n    sni: %s\n    congestion-controller: bbr\n' \
        "$name" "$host" "$port" "$uuid" "$password" "$sni"
      ;;
  esac
}

sub_build_all() {
  ensure_dirs
  local f1 f2 f3
  f1=$(sub_build_universal) || return 1
  f2=$(sub_build_singbox_json)
  f3=$(sub_build_clash_yaml)
  ok "订阅文件已生成:"
  printf '  通用 (Shadowrocket/v2rayN/NekoBox): %s\n' "$f1"
  printf '  sing-box JSON: %s\n' "$f2"
  printf '  Clash Meta / Mihomo YAML: %s\n' "$f3"
}

sub_serve_start() {
  ensure_dirs
  local port
  port=$(ask_port "本地订阅 HTTP 服务端口 (仅监听 127.0.0.1, 自行用 Nginx/Caddy 反代加 TLS)" "$SUB_PORT_DEFAULT")
  tee "$SUB_HTTPD_UNIT" >/dev/null <<EOF
[Unit]
Description=sing-box-vps subscription file server (127.0.0.1 only)
After=network.target

[Service]
Type=simple
WorkingDirectory=${SUB_DIR}
ExecStart=/usr/bin/python3 -m http.server ${port} --bind 127.0.0.1
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now sing-box-vps-sub
  ok "订阅服务已启动: http://127.0.0.1:${port}/ (请自行反代并加 TLS 后再对外提供)"
}

sub_serve_stop() {
  systemctl disable --now sing-box-vps-sub 2>/dev/null || true
  ok "订阅本地服务已停止。"
}

subscription_menu() {
  local choice
  while true; do
    title "订阅系统"
    printf '  1) 生成 / 刷新全部订阅文件\n'
    printf '  2) 查看订阅文件路径\n'
    printf '  3) 启动本地订阅 HTTP 服务 (127.0.0.1)\n'
    printf '  4) 停止本地订阅 HTTP 服务\n'
    printf '  5) 删除全部订阅文件\n'
    printf '  0) 返回主菜单\n'
    read -r -p '请选择: ' choice
    case $choice in
      1) sub_build_all ;;
      2) find "$SUB_DIR" -maxdepth 1 -type f 2>/dev/null | sed 's/^/  - /' ;;
      3) sub_serve_start ;;
      4) sub_serve_stop ;;
      5) confirm "确认删除全部订阅文件" N && rm -f "${SUB_DIR:?}"/* && ok "已清空订阅文件。" ;;
      0) return 0 ;;
      *) warn "无效的编号选择。" ;;
    esac
  done
}
# ===========================================================================
# 节点管理 / 运维
# ===========================================================================
show_connections() {
  ensure_dirs
  if [[ $(jq '.connections | length' "$STATE_FILE") -eq 0 ]]; then
    warn "尚未由本脚本创建任何连接记录。"
    return 0
  fi
  printf '\n已保存的客户端连接串:\n\n'
  jq -r '.connections[] | "[\(.type)] \(.tag) -> \(.host):\(.port)\n\(.uri)\n"' "$STATE_FILE"
}

show_connection_qrcode() {
  ensure_dirs
  local tags tag uri
  if [[ $(jq '.connections | length' "$STATE_FILE") -eq 0 ]]; then
    warn "尚未由本脚本创建任何连接记录。"
    return 0
  fi
  mapfile -t tags < <(jq -r '.connections[].tag' "$STATE_FILE")
  printf '\n可用节点:\n'
  local i
  for i in "${!tags[@]}"; do printf '  %d) %s\n' "$((i+1))" "${tags[$i]}"; done
  read -r -p "选择要显示二维码的节点编号: " idx
  [[ $idx =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#tags[@]} )) || die "无效编号。"
  tag=${tags[$((idx-1))]}
  uri=$(jq -r --arg tag "$tag" '.connections[] | select(.tag==$tag) | .uri' "$STATE_FILE")
  print_result_block "$tag" "$uri" "$tag"
}

list_inbounds() {
  ensure_base_routing
  jq -r '.inbounds | to_entries[] | "\(.key + 1). \(.value.tag) [\(.value.type)] :\(.value.listen_port // "Detour")"' "$CONFIG_FILE"
}

remove_inbound() {
  ensure_installed
  if [[ $(jq '.inbounds | length' "$CONFIG_FILE") -eq 0 ]]; then
    warn "当前没有任何入站节点。"
    return 0
  fi
  printf '\n当前已配置的入站:\n'
  list_inbounds
  local tag
  tag=$(ask_required "请输入要删除的节点 tag")
  valid_safe_token "$tag" || die "非法 tag 格式。"
  jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 || die "未找到对应的节点 tag。"
  confirm "确认删除 ${tag} 并清除关联的分流规则" N || return 0

  local candidate
  candidate=$(mktemp)
  jq --arg tag "$tag" '
    .inbounds |= map(select(.tag != $tag)) |
    if .route.rules then .route.rules |= map(select((.inbound // []) | index($tag) | not)) else . end
  ' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"

  atomic_json_update "$STATE_FILE" '.connections |= map(select(.tag != $tag))' --arg tag "$tag" || true
  ok "已成功删除 ${tag} 并同步更新路由。"
}

validate_and_restart() {
  ensure_installed
  sing-box check -c "$CONFIG_FILE"
  systemctl enable --now sing-box
  systemctl restart sing-box
  ok "配置校验通过, sing-box 服务已重启。"
}

show_status() {
  ensure_installed
  local stack v4_status="不可用" v6_status="不可用" public_ipv4 public_ipv6
  stack=$(detect_network_stack)
  check_ipv4_egress && v4_status="可用"
  check_ipv6_egress && v6_status="可用"
  public_ipv4=$(detect_public_ip || true)
  public_ipv6=$(detect_public_ipv6 || true)
  printf '\nsing-box 版本: '; sing-box version | head -n 1
  printf '出站 IP 版本策略: domain_resolver (dns tag: %s)\n' "$SB_DNS_RESOLVER_TAG"
  printf '网络栈判定: %s\n' "$stack"
  printf '外网栈连通性: IPv4 [%s] | IPv6 [%s]\n' "$v4_status" "$v6_status"
  printf '公网 IPv4: %s\n' "${public_ipv4:-未检测到}"
  printf '公网 IPv6: %s\n' "${public_ipv6:-未检测到}"
  printf '\n服务运行状态:\n'
  systemctl --no-pager --full status sing-box || true
  printf '\n当前入站与监听:\n'
  jq -r '.inbounds[]? | "- \(.tag) [\(.type)] 监听 \(.listen // "Detour"):\(.listen_port // "-")"' "$CONFIG_FILE"
}

show_logs() { journalctl -u sing-box -n 150 --no-pager -o cat; }

health_check() {
  ensure_installed
  local failed=0
  printf '\nsing-box 语法检测: '
  if sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then printf '通过\n'; else printf '失败\n'; failed=1; fi
  printf 'sing-box 服务状态: '
  if systemctl is-active --quiet sing-box; then printf '运行中\n'; else printf '未运行\n'; failed=1; fi
  if command -v cloudflared >/dev/null 2>&1; then
    printf 'cloudflared 状态: '
    if systemctl is-active --quiet cloudflared; then printf '运行中\n'; else printf '未运行\n'; failed=1; fi
  fi
  if command -v warp-cli >/dev/null 2>&1; then
    printf 'WARP 状态: '
    warp-cli --accept-tos status 2>/dev/null | grep -qi Connected && printf '已连接\n' || { printf '未连接\n'; failed=1; }
  fi
  printf '\n出站规则列表:\n'
  jq -r '.outbounds[]? | "- \(.tag) [\(.type)] domain_resolver 策略: \(.domain_resolver.strategy // "默认")"' "$CONFIG_FILE"
  if (( failed == 0 )); then ok "各项健康检查正常"; else warn "健康检查发现异常, 请运行 'sb logs' 或 'sb diag' 排查。"; fi
}

update_manager() {
  local candidate
  candidate=$(mktemp)
  info "从远程仓库拉取脚本更新: $SCRIPT_UPDATE_URL"
  curl -fL --proto '=https' --tlsv1.2 "$SCRIPT_UPDATE_URL" -o "$candidate"
  bash -n "$candidate" || { rm -f "$candidate"; die "下载的脚本语法校验失败, 已拒绝安装。"; }
  install -D -m 700 "$candidate" "$MANAGER_PATH"
  rm -f "$candidate"
  tee "$SHORTCUT_PATH" >/dev/null <<EOF
#!/usr/bin/env bash
exec ${MANAGER_PATH} "\$@"
EOF
  chmod 755 "$SHORTCUT_PATH"
  ok "管理脚本更新完毕, 直接输入 sb 即可使用新版本。"
}

upgrade_sing_box() {
  ensure_installed
  info "更新 sing-box 软件包..."
  apt-get update -qq
  apt-get install -y -qq --only-upgrade sing-box
  validate_and_restart
  ok "更新完成: $(sing-box version | head -n 1)"
}

enable_bbr() {
  require_root
  local virt
  virt=$(systemd-detect-virt 2>/dev/null || true)
  if [[ $virt =~ (lxc|openvz|container) ]]; then
    warn "检测到当前环境处于容器虚拟化 ($virt), 内核层可能不允许自行修改 TCP 拥塞控制。"
  fi
  local sysctl_file="/etc/sysctl.d/99-sing-box-bbr.conf"
  tee "$sysctl_file" >/dev/null <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1 || warn "sysctl 应用返回警告, 可能需要宿主机内核支持。"
  ok "已写入 BBR 配置; 当前生效算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"
}

restore_backup() {
  ensure_installed
  local file candidate
  file=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.json' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -n 1 | cut -d' ' -f2-)
  [[ -n $file ]] || die "未发现任何可用的备份文件。"
  warn "将回退到最近的备份: $file"
  confirm "确认恢复该备份" N || return 0
  candidate=$(mktemp)
  install -m 600 "$file" "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"
  ok "配置已回滚并成功重启服务。"
}

uninstall_sing_box() {
  require_root
  warn "这将会停止并卸载 sing-box 程序; 现有配置文件和节点连接串将保留在系统内。"
  confirm "确认卸载 sing-box" N || return 0
  systemctl disable --now sing-box 2>/dev/null || true
  apt-get remove -y -qq sing-box
  ok "sing-box 已卸载完毕; 数据保留目录: ${CONFIG_DIR}, ${STATE_DIR}"
}

# ===========================================================================
# 菜单交互
# ===========================================================================
print_menu() {
  local v4_tag="[无IPv4]" v6_tag="[无IPv6]"
  check_ipv4_egress && v4_tag="[IPv4正常]"
  check_ipv6_egress && v6_tag="[IPv6正常]"
  printf '\n%s\n' '=================================================='
  printf ' sing-box VPS 双栈智能管理 v%s %s %s\n' "$SCRIPT_VERSION" "$v4_tag" "$v6_tag"
  printf '%s\n' '=================================================='
  printf ' [VLESS Reality 专项节点]\n'
  printf '  1) 新建 VLESS Reality Dual (双栈智能推荐)\n'
  printf '  2) 新建 VLESS Reality IPv4 (出口强制 IPv4)\n'
  printf '  3) 新建 VLESS Reality IPv6 (出口优先 IPv6 / 回退 IPv4)\n\n'
  printf ' [高隐蔽 / 抗封锁 / 穿透节点]\n'
  printf '  4) 新建 VLESS Reality gRPC (云原生特征 / 多路复用)\n'
  printf '  5) 新建 ShadowTLS v3 + SS2022\n'
  printf '  6) Cloudflare Tunnel 管理 (新建 / 状态 / 日志 / 重启 / 卸载)\n\n'
  printf ' [经典协议入站]\n'
  printf '  7) 新建 Shadowsocks 2022 入站\n'
  printf '  8) 新建 Trojan + TLS 入站\n'
  printf '  9) 新建 VLESS + TLS 入站\n'
  printf ' 10) 新建 Hysteria2 + TLS 入站\n'
  printf ' 11) 新建 TUIC v5 入站\n\n'
  printf ' [订阅 / WARP / 测速]\n'
  printf ' 12) 订阅系统管理\n'
  printf ' 13) Cloudflare WARP 管理\n'
  printf ' 14) 服务器测速\n\n'
  printf ' [管理与运维]\n'
  printf ' 15) 查看客户端连接串\n'
  printf ' 16) 查看节点二维码\n'
  printf ' 17) 删除入站节点 (联动清理分流路由)\n'
  printf ' 18) 查看服务状态与网络栈情况\n'
  printf ' 19) 查看实时运行日志\n'
  printf ' 20) 校验配置并重启服务\n'
  printf ' 21) 系统健康检查\n'
  printf ' 22) 系统诊断 (端口/DNS/BBR/防火墙/Tunnel/配置)\n'
  printf ' 23) 证书管理\n'
  printf ' 24) 启用 BBR 拥塞控制\n'
  printf ' 25) 恢复最近一次配置备份\n'
  printf ' 26) 安装 / 修复官方 sing-box 环境\n'
  printf ' 27) 更新 sing-box 核心\n'
  printf ' 28) 从 GitHub 更新本脚本\n'
  printf ' 29) 卸载 sing-box\n'
  printf '  0) 退出\n\n'
}

menu() {
  local choice
  while true; do
    print_menu
    read -r -p '请选择操作编号: ' choice
    case $choice in
      1) deploy_vless_reality_unified "dual" ;;
      2) deploy_vless_reality_unified "v4" ;;
      3) deploy_vless_reality_unified "v6" ;;
      4) deploy_vless_reality_grpc ;;
      5) deploy_shadowtls_ss2022 ;;
      6) cf_tunnel_menu ;;
      7) deploy_shadowsocks ;;
      8) deploy_trojan ;;
      9) deploy_vless ;;
      10) deploy_hysteria2 ;;
      11) deploy_tuic ;;
      12) subscription_menu ;;
      13) warp_menu ;;
      14) run_speedtest ;;
      15) show_connections ;;
      16) show_connection_qrcode ;;
      17) remove_inbound ;;
      18) show_status ;;
      19) show_logs ;;
      20) validate_and_restart ;;
      21) health_check ;;
      22) run_diagnostics ;;
      23) cert_management_menu ;;
      24) enable_bbr ;;
      25) restore_backup ;;
      26) install_sing_box ;;
      27) upgrade_sing_box ;;
      28) update_manager ;;
      29) uninstall_sing_box ;;
      0) exit 0 ;;
      *) warn "无效的编号选择。" ;;
    esac
  done
}

usage() {
  cat <<'EOF'
用法: sb [命令]

  menu            交互菜单 (默认)
  install         安装 / 修复 sing-box 环境
  reality-dual|reality-v4|reality-v6   部署 VLESS Reality (指定网络模式)
  reality-grpc    部署 VLESS Reality gRPC
  shadowtls       部署 ShadowTLS v3 + SS2022
  ss              部署 Shadowsocks 2022
  trojan          部署 Trojan TLS
  vless           部署 VLESS TLS
  hy2             部署 Hysteria2
  tuic            部署 TUIC v5
  cftunnel        Cloudflare Tunnel 管理菜单
  warp            Cloudflare WARP 管理菜单
  sub             订阅系统管理菜单
  speedtest       服务器测速
  links           查看客户端连接串
  qrcode          查看节点二维码
  remove          删除入站节点
  status          查看服务状态
  logs            查看运行日志
  check           校验配置并重启
  health          系统健康检查
  diag            系统诊断
  certs           证书管理菜单
  bbr             启用 BBR
  rollback        恢复最近一次配置备份
  upgrade         更新 sing-box 核心
  self-update     从 GitHub 更新本脚本
  uninstall       卸载 sing-box
EOF
}

main() {
  case ${1:-menu} in
    -h|--help|help) usage; return 0 ;;
  esac
  require_root
  case ${1:-menu} in
    menu) menu ;;
    install) install_sing_box ;;
    reality-dual) deploy_vless_reality_unified "dual" ;;
    reality-v4) deploy_vless_reality_unified "v4" ;;
    reality-v6) deploy_vless_reality_unified "v6" ;;
    reality-grpc) deploy_vless_reality_grpc ;;
    shadowtls) deploy_shadowtls_ss2022 ;;
    cftunnel) cf_tunnel_menu ;;
    warp) warp_menu ;;
    sub) subscription_menu ;;
    speedtest) run_speedtest ;;
    ss) deploy_shadowsocks ;;
    trojan) deploy_trojan ;;
    vless) deploy_vless ;;
    hy2) deploy_hysteria2 ;;
    tuic) deploy_tuic ;;
    status) show_status ;;
    links) show_connections ;;
    qrcode) show_connection_qrcode ;;
    check) validate_and_restart ;;
    logs) show_logs ;;
    health) health_check ;;
    diag) run_diagnostics ;;
    certs) cert_management_menu ;;
    self-update) update_manager ;;
    upgrade) upgrade_sing_box ;;
    bbr) enable_bbr ;;
    rollback) restore_backup ;;
    remove) remove_inbound ;;
    uninstall) uninstall_sing_box ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
