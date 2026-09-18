#!/usr/bin/env bash
# ==============================================================================
# sing-box VPS 生产级全协议多功能智能运维引擎
# 架构规范: Bash Strict Mode | 全流程原子写入与异常自动回滚 | 跨平台多栈适配
# 协议支持: VLESS-Reality (Vision/gRPC) | ShadowTLS v3 | SS2022 | Trojan | Hy2 | TUIC v5 | CF Tunnel
# 核心拓展: WARP 原生 WireGuard 分流 | 全协议双客户端订阅 | 二维码 | 全维自检 | 测速 | 证书全生命周期
# ==============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C

readonly SCRIPT_VERSION="3.2.1"
readonly CONFIG_DIR="/etc/sing-box"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly STATE_DIR="/var/lib/sing-box-vps"
readonly STATE_FILE="${STATE_DIR}/connections.json"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly SUBS_DIR="${STATE_DIR}/subscriptions"
readonly WARP_CONF="${STATE_DIR}/warp.json"
readonly CERT_HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-sing-box"
readonly MANAGER_PATH="/usr/local/sbin/sing-box-vps"
readonly SHORTCUT_PATH="/usr/local/bin/sb"
readonly CF_DIR="/etc/cloudflared"
readonly CF_CONFIG="${CF_DIR}/config.yml"
readonly CF_TOKEN_FILE="${CF_DIR}/token.txt"

SCRIPT_UPDATE_URL="${SCRIPT_UPDATE_URL:-https://raw.githubusercontent.com/lisiyong0707/sing-box-vps/main/sing-box-vps.sh}"

# 终端色彩
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 全局临时文件追踪与安全清理
TMP_FILES=()

cleanup_tmp_files() {
  local f
  for f in "${TMP_FILES[@]}"; do
    [[ -n "$f" && -f "$f" ]] && rm -f "$f"
  done
}
trap cleanup_tmp_files EXIT

mktemp_tracked() {
  local temp
  temp=$(mktemp)
  TMP_FILES+=("$temp")
  printf '%s' "$temp"
}

info() { printf "${BLUE}[i]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
die()  { printf "${RED}[x]${NC} %s\n" "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf "${RED}[x] 执行异常中断：在脚本第 %s 行发生错误 (状态码: %s)。${NC}\n" "$1" "$exit_code" >&2
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# ==================== 环境权限与系统依赖 ====================

require_root() {
  [[ ${EUID} -eq 0 ]] || die "必须使用 root 权限运行本脚本，请执行: sudo bash $0"
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "本系统需要 systemd 服务管理器支持。"
}

require_apt() {
  command -v apt-get >/dev/null 2>&1 || die "当前管理系统专为 Debian / Ubuntu (APT) 环境优化。"
}

ensure_dirs() {
  install -d -m 700 "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR" "$SUBS_DIR" "$CF_DIR"
  if [[ ! -f "$STATE_FILE" ]]; then
    printf '{"connections":[]}\n' > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
  fi
}

install_prerequisites() {
  require_apt
  export DEBIAN_FRONTEND=noninteractive
  info "安装系统运维与底层网络工具集..."
  apt-get update -y
  apt-get install -y ca-certificates curl jq openssl iproute2 qrencode bsdmainutils dnsutils bc socat
  ok "系统依赖工具链已就绪。"
}

# ==================== 输入交互与格式验证 ====================

confirm() {
  local prompt=$1 default=${2:-N} answer
  read -r -p "$prompt [$([[ $default == Y ]] && printf 'Y/n' || printf 'y/N')]: " answer
  answer=${answer:-$default}
  [[ $answer =~ ^[Yy]$ ]]
}

ask_required() {
  local prompt=$1 value
  while true; do
    read -r -p "$prompt: " value
    [[ -n $value ]] && { printf '%s' "$value"; return; }
    warn "此输入项为必填，不能为空。"
  done
}

valid_port() {
  [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

ask_port() {
  local prompt=$1 default=$2 value
  while true; do
    read -r -p "$prompt [$default]: " value
    value=${value:-$default}
    valid_port "$value" && { printf '%s' "$value"; return; }
    warn "端口格式错误，必须为 1 到 65535 之间的整数。"
  done
}

valid_hostname() {
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

# ==================== 网络自适应探测与分流识别 ====================

detect_strategy_field() {
  if ! command -v sing-box >/dev/null 2>&1; then
    printf 'network_strategy'
    return
  fi
  local test_cfg
  test_cfg=$(mktemp_tracked)
  cat <<'EOF' > "$test_cfg"
{
  "outbounds": [
    {
      "type": "direct",
      "tag": "probe",
      "network_strategy": "prefer_ipv6"
    }
  ]
}
EOF
  if sing-box check -c "$test_cfg" >/dev/null 2>&1; then
    printf 'network_strategy'
  else
    printf 'domain_strategy'
  fi
}

check_ipv4_egress() {
  ip -4 route show default 2>/dev/null | grep -q 'default' || return 1
  curl -4fsS --connect-timeout 2 --max-time 3 https://api.ipify.org >/dev/null 2>&1 || \
    ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1
}

check_ipv6_egress() {
  ip -6 route show default 2>/dev/null | grep -q 'default' || return 1
  curl -6fsS --connect-timeout 2 --max-time 3 https://api64.ipify.org >/dev/null 2>&1 || \
    ping6 -c 1 -W 2 2606:4700:4700::1111 >/dev/null 2>&1
}

detect_network_stack_type() {
  local has_v4=false has_v6=false
  check_ipv4_egress && has_v4=true
  check_ipv6_egress && has_v6=true
  if $has_v4 && $has_v6; then
    printf "Dual-Stack (双栈连通)"
  elif $has_v4; then
    printf "IPv4-Only (纯IPv4)"
  elif $has_v6; then
    printf "IPv6-Only (纯IPv6)"
  else
    printf "Isolated (无公网出口)"
  fi
}

detect_public_ip() {
  local ip
  for endpoint in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4fsS --connect-timeout 3 --max-time 5 "$endpoint" 2>/dev/null | tr -d '\r\n[:space:]' || true)
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { printf '%s' "$ip"; return 0; }
  done
  ip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n 1)
  [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { printf '%s' "$ip"; return 0; }
  return 0
}

detect_public_ipv6() {
  local ip
  for endpoint in https://api64.ipify.org https://ifconfig.co/ip https://icanhazip.com; do
    ip=$(curl -6fsS --connect-timeout 3 --max-time 5 "$endpoint" 2>/dev/null | tr -d '\r\n[:space:]' || true)
    [[ $ip == *:* ]] && { printf '%s' "$ip"; return 0; }
  done
  ip=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | grep -v '^fe80' | head -n 1)
  [[ $ip == *:* ]] && { printf '%s' "$ip"; return 0; }
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
  country=$(curl -fsS --connect-timeout 2 --max-time 3 "https://ipapi.co/country/" 2>/dev/null | tr -d '\r\n[:space:]' || true)
  [[ -z $country ]] && country=$(curl -fsS --connect-timeout 2 --max-time 3 "https://api.country.is/" 2>/dev/null | jq -r '.country // empty' 2>/dev/null | tr -d '\r\n[:space:]' || true)
  if [[ $country =~ ^[A-Za-z]{2}$ ]]; then
    country=$(echo "$country" | tr '[:lower:]' '[:upper:]')
    c1=${country:0:1}
    c2=${country:1:1}
    printf "%b%b" "$(printf '\\U%08X' $(( 0x1F1E6 + $(printf '%d' "'$c1") - 65 )))" \
                  "$(printf '\\U%08X' $(( 0x1F1E6 + $(printf '%d' "'$c2") - 65 )))"
  else
    printf "🌐"
  fi
}

ask_node_network_mode() {
  local choice
  printf "\n选择节点监听与网络出口模式：\n"
  printf "  1) Dual 双栈节点 (推荐: 监听 ::，出站 IPv6 优先并自适应故障回退 IPv4)\n"
  printf "  2) IPv4 专用节点 (监听 0.0.0.0，出站强制仅经由 IPv4)\n"
  printf "  3) IPv6 专用节点 (监听 ::，专供 IPv6 客户端或纯 IPv6 出口)\n"
  read -r -p "请选择 [1]: " choice
  choice=${choice:-1}
  case "$choice" in
    2) printf "v4" ;;
    3) printf "v6" ;;
    *) printf "dual" ;;
  esac
}

ask_node_server() {
  local mode=$1 default val
  if [[ $mode == "v4" ]]; then
    default=$(detect_public_ip)
    read -r -p "客户端连接使用的 IPv4 地址 [${default}]: " val
    val=${val:-$default}
    [[ -n $val ]] || die "必须提供有效的 IPv4 地址。"
    printf '%s' "$val"
  elif [[ $mode == "v6" ]]; then
    default=$(detect_public_ipv6)
    read -r -p "客户端连接使用的 IPv6 地址 [${default}]: " val
    val=${val:-$default}
    [[ -n $val ]] || die "必须提供有效的 IPv6 地址。"
    printf '%s' "$val"
  else
    default=$(detect_public_ip)
    [[ -z $default ]] && default=$(detect_public_ipv6)
    read -r -p "客户端连接双栈域名或 IP (强烈建议填写已解析 A+AAAA 的域名) [${default}]: " val
    val=${val:-$default}
    [[ -n $val ]] || die "必须提供有效的连接域名或 IP。"
    printf '%s' "$val"
  fi
}

# ==================== 防火墙端口放行 (幂等防重) ====================

open_firewall_port() {
  local port=$1 protocol=${2:-tcp}
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
    ufw allow "${port}/${protocol}" >/dev/null 2>&1 || true
    ok "已通过 UFW 防火墙放行 ${port}/${protocol}"
  fi
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null || \
      iptables -I INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null || true
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -C INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null || \
      ip6tables -I INPUT -p "$protocol" --dport "$port" -j ACCEPT 2>/dev/null || true
  fi
  info "云厂商提示：若为 Oracle Cloud、阿里云、腾讯云、AWS，请务必在 Web 控制台【安全组】放行 ${port}/${protocol}。"
}

# ==================== 原子写入与多版本容灾备份 ====================

backup_config() {
  [[ -f $CONFIG_FILE ]] || return 0
  local stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  install -m 600 "$CONFIG_FILE" "${BACKUP_DIR}/config-${stamp}.json"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.json' -printf '%T@ %p\n' \
    | sort -nr | awk 'NR>15 {print $2}' | xargs -r rm -f
}

validate_config_file() {
  local file=$1
  if ! sing-box check -c "$file" >/dev/null 2>&1; then
    warn "sing-box 配置语义校验未通过，详细报错如下："
    sing-box check -c "$file" || true
    return 1
  fi
  return 0
}

apply_candidate() {
  local candidate=$1
  if ! validate_config_file "$candidate"; then
    die "生成的配置验证失败，已中止应用，现有配置未作任何改动。"
  fi
  local stamp backup_file
  stamp=$(date +%Y%m%d-%H%M%S)
  backup_file="${BACKUP_DIR}/config-${stamp}.json"
  if [[ -f $CONFIG_FILE ]]; then
    install -m 600 "$CONFIG_FILE" "$backup_file"
  fi

  install -m 600 "$candidate" "$CONFIG_FILE"
  systemctl enable --now sing-box

  if ! systemctl restart sing-box; then
    warn "sing-box 重启失败，正在触发异常安全自动回滚..."
    if [[ -f $backup_file ]]; then
      install -m 600 "$backup_file" "$CONFIG_FILE"
      systemctl restart sing-box || true
      die "服务启动失败，已成功回滚至上一稳定配置快照！请检查端口或证书是否冲突。"
    else
      die "服务启动失败，且无历史稳定备份可供还原。"
    fi
  fi
  sleep 0.5
}

get_tag_by_port() {
  local port=$1
  [[ -f $CONFIG_FILE ]] || return 1
  jq -r --argjson port "$port" '.inbounds[]? | select(.listen_port == $port) | .tag' "$CONFIG_FILE" 2>/dev/null || true
}

ensure_port_available() {
  local port=$1 occupying_tag other_proc
  occupying_tag=$(get_tag_by_port "$port")
  if [[ -n $occupying_tag ]]; then
    die "端口 $port 已被配置中的节点 [${occupying_tag}] 占用，请更换端口或先删除冲突节点。"
  fi
  if ss -tulnH "sport = :$port" 2>/dev/null | grep -q .; then
    other_proc=$(ss -tulnp "sport = :$port" 2>/dev/null | awk 'NR>1 {print $NF}' | head -n 1)
    die "端口 $port 已被宿主机上其他进程占用 (${other_proc:-未知进程})，请先释放端口或更换端口。"
  fi
}

create_base_config() {
  [[ -f $CONFIG_FILE ]] && return 0
  info "初始化核心路由规则与多栈直连出站..."
  local candidate strat_key
  strat_key=$(detect_strategy_field)
  candidate=$(mktemp_tracked)
  jq -n --arg strat "$strat_key" '{
    "$schema": "https://sing-box.sagernet.org/schema.json",
    log: { level: "info", timestamp: true },
    inbounds: [],
    outbounds: [
      { type: "direct", tag: "direct" },
      { type: "direct", tag: "direct-v4", ($strat): "ipv4_only" },
      { type: "direct", tag: "direct-v6", ($strat): "prefer_ipv6" },
      { type: "direct", tag: "direct-dual", ($strat): "prefer_ipv6" },
      { type: "block", tag: "block" }
    ],
    route: { rules: [], final: "direct" }
  }' > "$candidate"
  install -m 600 "$candidate" "$CONFIG_FILE"
}

ensure_base_routing() {
  ensure_dirs
  create_base_config
  local candidate strat_key
  strat_key=$(detect_strategy_field)
  candidate=$(mktemp_tracked)
  jq --arg strat "$strat_key" '
    if (.outbounds | map(select(.tag == "direct-v4")) | length) == 0 then
      .outbounds += [{"type": "direct", "tag": "direct-v4", ($strat): "ipv4_only"}]
    else . end |
    if (.outbounds | map(select(.tag == "direct-v6")) | length) == 0 then
      .outbounds += [{"type": "direct", "tag": "direct-v6", ($strat): "prefer_ipv6"}]
    else . end |
    if (.outbounds | map(select(.tag == "direct-dual")) | length) == 0 then
      .outbounds += [{"type": "direct", "tag": "direct-dual", ($strat): "prefer_ipv6"}]
    else . end |
    if .route.rules == null then .route.rules = [] else . end
  ' "$CONFIG_FILE" > "$candidate"
  if ! cmp -s "$CONFIG_FILE" "$candidate"; then
    backup_config
    install -m 600 "$candidate" "$CONFIG_FILE"
  fi
}

check_and_handle_existing_tag() {
  local tag=$1 candidate
  if jq -e --arg tag "$tag" '.inbounds[]? | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
    warn "节点标识 [${tag}] 已经存在。"
    if confirm "是否确认覆盖并替换该节点？" N; then
      candidate=$(mktemp_tracked)
      jq --arg tag "$tag" '
        .inbounds |= map(select(.tag != $tag)) |
        if .route.rules then
          .route.rules |= map(select((.inbound // []) | index($tag) | not))
        else . end
      ' "$CONFIG_FILE" > "$candidate"
      apply_candidate "$candidate"
      
      candidate=$(mktemp_tracked)
      jq --arg tag "$tag" '.connections |= map(select(.tag != $tag))' "$STATE_FILE" > "$candidate"
      install -m 600 "$candidate" "$STATE_FILE"
      ok "已清理原节点 [${tag}] 配置与记录。"
      return 0
    else
      warn "操作已取消。"
      return 1
    fi
  fi
  return 0
}

apply_inbound_with_route() {
  local inbound_json=$1 tag=$2 outbound_tag=$3 candidate
  candidate=$(mktemp_tracked)
  jq --argjson inbound "$inbound_json" --arg tag "$tag" --arg outbound "$outbound_tag" '
    .inbounds += [$inbound] |
    .route.rules += [{"inbound": [$tag], "outbound": $outbound}]
  ' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
}

save_connection() {
  local type=$1 tag=$2 host=$3 port=$4 uri=$5 meta=${6:-"{}"}
  local candidate
  candidate=$(mktemp_tracked)
  jq --arg type "$type" --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg uri "$uri" --argjson meta "$meta" \
    '.connections += [{type:$type, tag:$tag, host:$host, port:$port, uri:$uri, meta:$meta, created_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}]' \
    "$STATE_FILE" > "$candidate"
  install -m 600 "$candidate" "$STATE_FILE"
  generate_all_subscriptions
}

# ==================== 密码学工具与密钥派生 ====================

random_ss_key() {
  sing-box generate rand --base64 16 2>/dev/null || openssl rand -base64 16 | tr -d '\r\n'
}

random_token() {
  openssl rand -hex 16
}

random_path() {
  printf '/%s' "$(openssl rand -hex 8)"
}

new_uuid() {
  sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
}

generate_reality_keypair() {
  local keypair private_key public_key
  keypair=$(sing-box generate reality-keypair)
  private_key=$(awk -F': ' '/PrivateKey/ {print $2}' <<<"$keypair" | tr -d '\r\n[:space:]')
  public_key=$(awk -F': ' '/PublicKey/ {print $2}' <<<"$keypair" | tr -d '\r\n[:space:]')
  [[ -n $private_key && -n $public_key ]] || die "Reality 密钥对派生失败。"
  printf '%s|%s' "$private_key" "$public_key"
}

generate_wireguard_keypair() {
  local priv_der pub_der priv_b64 pub_b64
  priv_der=$(mktemp_tracked)
  pub_der=$(mktemp_tracked)
  openssl genpkey -algorithm X25519 -outform der -out "$priv_der" 2>/dev/null
  openssl pkey -inform der -in "$priv_der" -pubout -outform der -out "$pub_der" 2>/dev/null
  priv_b64=$(tail -c 32 "$priv_der" | base64 | tr -d '\r\n')
  pub_b64=$(tail -c 32 "$pub_der" | base64 | tr -d '\r\n')
  printf '%s|%s' "$priv_b64" "$pub_b64"
}

show_qr_and_uri() {
  local uri=$1
  printf "\n${CYAN}======================= 客户端连接 URI =======================${NC}\n"
  printf "${BOLD}%s${NC}\n" "$uri"
  printf "${CYAN}=============================================================${NC}\n\n"
  if command -v qrencode >/dev/null 2>&1; then
    printf "${GREEN}终端二维码快速扫码：${NC}\n"
    qrencode -t ANSIUTF8 "$uri" || true
    printf "\n"
  fi
}

# ==================== Reality 域名探测与交互 ====================

select_reality_sni() {
  local choice custom_sni
  printf "\n选择 Reality 握手域名（SNI 目标）:\n"
  printf "  1) gateway.icloud.com   (Apple iCloud 核心网关, 推荐)\n"
  printf "  2) mask.icloud.com      (Apple Private Relay 节点)\n"
  printf "  3) www.cloudflare.com   (Cloudflare 官方主站)\n"
  printf "  4) www.microsoft.com    (微软官方主站)\n"
  printf "  5) dl.google.com        (Google CDN 全球节点)\n"
  printf "  6) 自定义输入握手域名\n"
  read -r -p "请选择 [1]: " choice
  choice=${choice:-1}
  case "$choice" in
    1) printf "gateway.icloud.com" ;;
    2) printf "mask.icloud.com" ;;
    3) printf "www.cloudflare.com" ;;
    4) printf "www.microsoft.com" ;;
    5) printf "dl.google.com" ;;
    6)
      custom_sni=$(ask_required "请输入自定义握手域名 (例如: aws.amazon.com)")
      valid_hostname "$custom_sni" || die "域名格式不合法。"
      printf '%s' "$custom_sni"
      ;;
    *) printf "gateway.icloud.com" ;;
  esac
}

validate_tls13_sni() {
  local domain=$1
  info "探测握手域名 [${domain}] 对 TLS 1.3 的兼容性..."
  if timeout 4 openssl s_client -connect "${domain}:443" -tls1_3 -servername "${domain}" </dev/null >/dev/null 2>&1; then
    ok "握手域名 [${domain}] 支持 TLS 1.3 握手，验证通过。"
  else
    warn "握手域名 [${domain}] TLS 1.3 探测超时或未响应，可能影响隐蔽性，但配置仍将正常应用。"
  fi
}

# ==================== TLS 证书生命周期管理 ====================

tls_json() {
  local domain=$1 cert=$2 key=$3
  jq -n --arg domain "$domain" --arg cert "$cert" --arg key "$key" \
    '{enabled:true,server_name:$domain,alpn:["h2","http/1.1"],min_version:"1.2",certificate_path:$cert,key_path:$key}'
}

check_port_80() {
  if ss -tulnH "sport = :80" 2>/dev/null | grep -q .; then
    warn "80 端口已被本地服务占用！"
    ss -tlpn "sport = :80" 2>/dev/null || true
    if ! confirm "是否继续？若 80 端口被占且无法停止，Certbot Standalone 模式将签发失败。" N; then
      die "操作已取消，请释放 80 端口或指定现有 PEM 证书路径。"
    fi
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
    return
  fi
  printf "\nTLS 证书配置选项：\n"
  printf "  1) 使用 Certbot 自动签发 Let's Encrypt (需域名解析到本机且 80 端口空闲)\n"
  printf "  2) 手动输入服务器现有证书和私钥路径 (PEM 格式)\n"
  read -r -p '选择 [1]: ' choice
  choice=${choice:-1}
  case $choice in
    1)
      check_port_80
      apt-get update -y >&2
      apt-get install -y certbot >&2
      open_firewall_port 80 tcp >&2
      info "正在签发域名 [${domain}] 的 SSL 证书..." >&2
      certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$domain" >&2
      install_certbot_hook
      [[ -r $cert && -r $key ]] || die "证书申请流程结束，但在预设路径未找到 PEM 证书文件。"
      ;;
    2)
      cert=$(ask_required "证书 fullchain PEM 绝对路径")
      key=$(ask_required "私钥 privkey PEM 绝对路径")
      [[ -r $cert && -r $key ]] || die "指定的证书或私钥文件不可读取。"
      ;;
    *) die "无效选项。" ;;
  esac
  printf '%s|%s' "$cert" "$key"
}

manage_certificates_menu() {
  local choice
  while true; do
    printf "\n${CYAN}================= TLS 证书生命周期管理 =================${NC}\n"
    printf "  1) 查看全部证书有效状态及剩余天数\n"
    printf "  2) 重新/强制续期全部 Let's Encrypt 证书\n"
    printf "  3) 为新域名签发 Let's Encrypt 证书\n"
    printf "  0) 返回上一级\n"
    read -r -p "请选择: " choice
    case "$choice" in
      1) show_certificate_expiry ;;
      2)
        if command -v certbot >/dev/null 2>&1; then
          info "正在执行 certbot renew 续期校验..."
          certbot renew --quiet --no-self-upgrade || true
          systemctl try-restart sing-box.service || true
          ok "续期检查完成。"
        else
          warn "未检测到 certbot 安装。"
        fi
        ;;
      3)
        local dom
        dom=$(ask_required "请输入需要申请证书的域名")
        valid_hostname "$dom" || { warn "域名格式不合规"; continue; }
        obtain_tls_paths "$dom"
        ok "证书签发成功。"
        ;;
      0) return ;;
      *) warn "无效选项。" ;;
    esac
  done
}

show_certificate_expiry() {
  local -a certs=()
  if [[ -f $CONFIG_FILE ]]; then
    mapfile -t certs < <(jq -r '.inbounds[]? | .tls.certificate_path? // empty' "$CONFIG_FILE" | sort -u)
  fi
  if [[ -d "/etc/letsencrypt/live" ]]; then
    while IFS= read -r f; do
      certs+=("$f")
    done < <(find /etc/letsencrypt/live -type f -name 'fullchain.pem')
  fi

  if (( ${#certs[@]} == 0 )); then
    warn "系统中未发现正在使用的本地 TLS 证书。"
    return
  fi

  printf "\n%-45s %-25s %-10s\n" "证书路径" "到期时间 (UTC)" "剩余天数"
  printf '%s\n' "--------------------------------------------------------------------------------"
  local cert end_date end_epoch now_epoch days_left
  now_epoch=$(date +%s)
  for cert in "${certs[@]}"; do
    if [[ -r $cert ]]; then
      end_date=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2-)
      end_epoch=$(date -d "$end_date" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$end_date" +%s 2>/dev/null || echo 0)
      if (( end_epoch > 0 )); then
        days_left=$(( (end_epoch - now_epoch) / 86400 ))
        printf "%-45s %-25s %s 天\n" "$cert" "$end_date" "$days_left"
      else
        printf "%-45s %-25s %s\n" "$cert" "$end_date" "未知"
      fi
    fi
  done
}

# ==================== 核心组件安装与维护 ====================

install_sing_box() {
  require_root
  require_systemd
  install_prerequisites
  info "配置 sing-box 官方 APT 存储库..."
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
  apt-get update -y
  apt-get install -y sing-box
  ensure_base_routing
  systemctl enable sing-box
  install_manager
  ok "sing-box 安装成功: $(sing-box version | head -n 1)"
}

install_manager() {
  local source_path=${BASH_SOURCE[0]}
  if [[ -r $source_path ]]; then
    install -D -m 700 "$source_path" "$MANAGER_PATH"
  fi
  tee "$SHORTCUT_PATH" >/dev/null <<EOF
#!/usr/bin/env bash
exec ${MANAGER_PATH} "\$@"
EOF
  chmod 755 "$SHORTCUT_PATH"
  ok "已配置快捷管理命令: sb"
}

ensure_installed() {
  command -v sing-box >/dev/null 2>&1 || install_sing_box
  command -v jq >/dev/null 2>&1 || install_prerequisites
  ensure_base_routing
}

# ==================== 节点部署模块 ====================

deploy_vless_reality_unified() {
  local mode=${1:-dual}
  ensure_installed
  if [[ $mode == "v4" ]] && ! check_ipv4_egress; then
    die "宿主机 IPv4 外网不可达，无法部署 IPv4 专用节点。"
  fi
  if [[ $mode == "v6" ]] && ! check_ipv6_egress; then
    die "宿主机 IPv6 外网不可达，无法部署 IPv6 专用节点。"
  fi

  local default_port listen_addr outbound_tag name_suffix
  case "$mode" in
    v4)   default_port=443;  listen_addr="0.0.0.0"; outbound_tag="direct-v4";   name_suffix="Reality-V4" ;;
    v6)   default_port=8443; listen_addr="::";      outbound_tag="direct-v6";   name_suffix="Reality-V6" ;;
    dual) default_port=443;  listen_addr="::";      outbound_tag="direct-dual"; name_suffix="Reality-Dual" ;;
  esac

  local port host formatted_host handshake keypair private_key public_key short_id uuid tag reality tls inbound uri flag meta
  port=$(ask_port "VLESS Reality 监听端口" "$default_port")
  tag="reality-${mode}-${port}"
  check_and_handle_existing_tag "$tag" || return
  ensure_port_available "$port"

  host=$(ask_node_server "$mode")
  formatted_host=$(format_host_uri "$host")
  handshake=$(select_reality_sni)
  validate_tls13_sni "$handshake"

  keypair=$(generate_reality_keypair)
  private_key=${keypair%%|*}
  public_key=${keypair#*|}
  short_id=$(openssl rand -hex 4)
  uuid=$(new_uuid)

  reality=$(jq -n --arg handshake "$handshake" --arg private_key "$private_key" --arg short_id "$short_id" \
    '{enabled:true,handshake:{server:$handshake,server_port:443},private_key:$private_key,short_id:[$short_id]}')
  tls=$(jq -n --argjson reality "$reality" '{enabled:true,reality:$reality}')
  inbound=$(jq -n --arg tag "$tag" --arg listen "$listen_addr" --argjson port "$port" --arg uuid "$uuid" --argjson tls "$tls" \
    '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",uuid:$uuid,flow:"xtls-rprx-vision"}],tls:$tls}')

  apply_inbound_with_route "$inbound" "$tag" "$outbound_tag"
  flag=$(get_server_flag)
  uri="vless://${uuid}@${formatted_host}:${port}?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=${handshake}&fp=chrome&pbk=${public_key}&sid=${short_id}#${flag}%20${name_suffix}"
  
  meta=$(jq -n --arg uuid "$uuid" --arg flow "xtls-rprx-vision" --arg sni "$handshake" --arg pbk "$public_key" --arg sid "$short_id" \
    '{uuid:$uuid, flow:$flow, sni:$sni, pbk:$pbk, sid:$sid, transport:"tcp"}')
  save_connection "vless-reality-${mode}" "$tag" "$host" "$port" "$uri" "$meta"
  open_firewall_port "$port" tcp
  ok "VLESS ${name_suffix} 部署成功！"
  show_qr_and_uri "$uri"
}

deploy_vless_reality_grpc() {
  ensure_installed
  local mode host formatted_host port handshake keypair private_key public_key short_id uuid service_name tag reality tls inbound uri flag meta
  local listen_addr outbound_tag
  mode=$(ask_node_network_mode)
  case "$mode" in
    v4) listen_addr="0.0.0.0"; outbound_tag="direct-v4" ;;
    v6) listen_addr="::";      outbound_tag="direct-v6" ;;
    *)  listen_addr="::";      outbound_tag="direct-dual" ;;
  esac

  port=$(ask_port "VLESS Reality gRPC 监听端口" 8443)
  tag="reality-grpc-${mode}-${port}"
  check_and_handle_existing_tag "$tag" || return
  ensure_port_available "$port"

  host=$(ask_node_server "$mode")
  formatted_host=$(format_host_uri "$host")
  handshake=$(select_reality_sni)
  validate_tls13_sni "$handshake"
  service_name="grpc-$(openssl rand -hex 4)"

  keypair=$(generate_reality_keypair)
  private_key=${keypair%%|*}
  public_key=${keypair#*|}
  short_id=$(openssl rand -hex 4)
  uuid=$(new_uuid)

  reality=$(jq -n --arg handshake "$handshake" --arg private_key "$private_key" --arg short_id "$short_id" \
    '{enabled:true,handshake:{server:$handshake,server_port:443},private_key:$private_key,short_id:[$short_id]}')
  tls=$(jq -n --argjson reality "$reality" '{enabled:true,reality:$reality}')
  inbound=$(jq -n --arg tag "$tag" --arg listen "$listen_addr" --argjson port "$port" --arg uuid "$uuid" --arg svc "$service_name" --argjson tls "$tls" \
    '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",uuid:$uuid}],tls:$tls,transport:{type:"grpc",service_name:$svc}}')

  apply_inbound_with_route "$inbound" "$tag" "$outbound_tag"
  flag=$(get_server_flag)
  uri="vless://${uuid}@${formatted_host}:${port}?encryption=none&security=reality&type=grpc&serviceName=${service_name}&sni=${handshake}&fp=chrome&pbk=${public_key}&sid=${short_id}#${flag}%20Reality-gRPC-${mode}"
  
  meta=$(jq -n --arg uuid "$uuid" --arg sni "$handshake" --arg pbk "$public_key" --arg sid "$short_id" --arg svc "$service_name" \
    '{uuid:$uuid, sni:$sni, pbk:$pbk, sid:$sid, transport:"grpc", service_name:$svc}')
  save_connection "vless-reality-grpc-${mode}" "$tag" "$host" "$port" "$uri" "$meta"
  open_firewall_port "$port" tcp
  ok "VLESS Reality gRPC (${mode}) 部署成功！"
  show_qr_and_uri "$uri"
}

deploy_shadowtls_ss2022() {
  ensure_installed
  local mode host formatted_host port handshake st_password ss_key tag_st tag_ss inbound_st inbound_ss candidate uri flag meta
  local listen_addr outbound_tag
  mode=$(ask_node_network_mode)
  case "$mode" in
    v4) listen_addr="0.0.0.0"; outbound_tag="direct-v4" ;;
    v6) listen_addr="::";      outbound_tag="direct-v6" ;;
    *)  listen_addr="::";      outbound_tag="direct-dual" ;;
  esac

  port=$(ask_port "ShadowTLS 公网监听端口" 443)
  tag_st="st3-${mode}-${port}"
  tag_ss="ss-inner-${port}"
  check_and_handle_existing_tag "$tag_st" || return
  ensure_port_available "$port"

  host=$(ask_node_server "$mode")
  formatted_host=$(format_host_uri "$host")
  handshake=$(select_reality_sni)
  validate_tls13_sni "$handshake"

  st_password=$(random_token)
  ss_key=$(random_ss_key)

  inbound_st=$(jq -n --arg tag "$tag_st" --arg listen "$listen_addr" --argjson port "$port" --arg pwd "$st_password" --arg hs "$handshake" --arg detour "$tag_ss" \
    '{type:"shadowtls",tag:$tag,listen:$listen,listen_port:$port,version:3,users:[{password:$pwd}],handshake:{server:$hs,server_port:443},strict_mode:true,detour:$detour}')
  inbound_ss=$(jq -n --arg tag "$tag_ss" --arg key "$ss_key" \
    '{type:"shadowsocks",tag:$tag,method:"2022-blake3-aes-128-gcm",password:$key}')

  candidate=$(mktemp_tracked)
  jq --argjson inb_st "$inbound_st" --argjson inb_ss "$inbound_ss" --arg tag "$tag_ss" --arg outbound "$outbound_tag" '
    .inbounds += [$inb_st, $inb_ss] |
    .route.rules += [{"inbound": [$tag], "outbound": $outbound}]
  ' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"

  local encoded_ss
  encoded_ss=$(printf '%s' "2022-blake3-aes-128-gcm:${ss_key}" | base64 | tr -d '\r\n')
  flag=$(get_server_flag)
  uri="ss://${encoded_ss}@${formatted_host}:${port}?plugin=shadow-tls%3Bhost%3D${handshake}%3Bpassword%3D${st_password}%3Bversion%3D3#${flag}%20ShadowTLS-SS2022-${mode}"
  
  meta=$(jq -n --arg key "$ss_key" --arg method "2022-blake3-aes-128-gcm" --arg st_pwd "$st_password" --arg sni "$handshake" \
    '{ss_key:$key, method:$method, st_password:$st_pwd, sni:$sni}')
  save_connection "shadowtls-v3-${mode}" "$tag_st" "$host" "$port" "$uri" "$meta"
  open_firewall_port "$port" tcp
  ok "ShadowTLS v3 + SS2022 (${mode}) 部署完成！"
  show_qr_and_uri "$uri"
}

deploy_shadowsocks() {
  ensure_installed
  local mode listen_addr outbound_tag port host formatted_host key tag inbound encoded uri flag meta
  mode=$(ask_node_network_mode)
  case "$mode" in
    v4) listen_addr="0.0.0.0"; outbound_tag="direct-v4" ;;
    v6) listen_addr="::";      outbound_tag="direct-v6" ;;
    *)  listen_addr="::";      outbound_tag="direct-dual" ;;
  esac

  port=$(ask_port "Shadowsocks 2022 监听端口" 8443)
  tag="ss2022-${mode}-${port}"
  check_and_handle_existing_tag "$tag" || return
  ensure_port_available "$port"

  host=$(ask_node_server "$mode")
  formatted_host=$(format_host_uri "$host")
  key=$(random_ss_key)

  inbound=$(jq -n --arg tag "$tag" --arg listen "$listen_addr" --argjson port "$port" --arg key "$key" \
    '{type:"shadowsocks",tag:$tag,listen:$listen,listen_port:$port,method:"2022-blake3-aes-128-gcm",password:$key,multiplex:{enabled:true}}')
  apply_inbound_with_route "$inbound" "$tag" "$outbound_tag"

  encoded=$(printf '%s' "2022-blake3-aes-128-gcm:${key}" | base64 | tr -d '\r\n')
  flag=$(get_server_flag)
  uri="ss://${encoded}@${formatted_host}:${port}#${flag}%20SS2022-${mode}"
  
  meta=$(jq -n --arg password "$key" --arg method "2022-blake3-aes-128-gcm" '{password:$password, method:$method}')
  save_connection "shadowsocks-2022-${mode}" "$tag" "$host" "$port" "$uri" "$meta"
  open_firewall_port "$port" tcp
  open_firewall_port "$port" udp
  ok "Shadowsocks 2022 (${mode}) 部署完成！"
  show_qr_and_uri "$uri"
}

deploy_trojan() {
  ensure_installed
  local mode listen_addr outbound_tag domain formatted_host port paths cert key password tag tls inbound uri flag meta
  mode=$(ask_node_network_mode)
  case "$mode" in
    v4) listen_addr="0.0.0.0"; outbound_tag="direct-v4" ;;
    v6) listen_addr="::";      outbound_tag="direct-v6" ;;
    *)  listen_addr="::";      outbound_tag="direct-dual" ;;
  esac

  domain=$(ask_required "Trojan TLS 绑定域名")
  valid_hostname "$domain" || die "域名格式不正确。"
  formatted_host=$(format_host_uri "$domain")
  port=$(ask_port "Trojan 监听端口" 443)
  tag="trojan-${mode}-${port}"
  check_and_handle_existing_tag "$tag" || return
  ensure_port_available "$port"

  paths=$(obtain_tls_paths "$domain")
  cert=${paths%%|*}
  key=${paths#*|}
  password=$(random_token)

  tls=$(tls_json "$domain" "$cert" "$key")
  inbound=$(jq -n --arg tag "$tag" --arg listen "$listen_addr" --argjson port "$port" --arg password "$password" --argjson tls "$tls" \
    '{type:"trojan",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",password:$password}],tls:$tls}')
  apply_inbound_with_route "$inbound" "$tag" "$outbound_tag"

  flag=$(get_server_flag)
  uri="trojan://${password}@${formatted_host}:${port}?security=tls&sni=${domain}&type=tcp#${flag}%20Trojan-${mode}"
  
  meta=$(jq -n --arg password "$password" --arg sni "$domain" '{password:$password, sni:$sni}')
  save_connection "trojan-tls-${mode}" "$tag" "$domain" "$port" "$uri" "$meta"
  open_firewall_port "$port" tcp
  ok "Trojan TLS (${mode}) 部署完成！"
  show_qr_and_uri "$uri"
}

deploy_vless() {
  ensure_installed
  local mode listen_addr outbound_tag domain formatted_host port paths cert key uuid tag tls inbound uri flag meta
  mode=$(ask_node_network_mode)
  case "$mode" in
    v4) listen_addr="0.0.0.0"; outbound_tag="direct-v4" ;;
    v6) listen_addr="::";      outbound_tag="direct-v6" ;;
    *)  listen_addr="::";      outbound_tag="direct-dual" ;;
  esac

  domain=$(ask_required "VLESS TLS 绑定域名")
  valid_hostname "$domain" || die "域名格式不正确。"
  formatted_host=$(format_host_uri "$domain")
  port=$(ask_port "VLESS 监听端口" 8443)
  tag="vless-${mode}-${port}"
  check_and_handle_existing_tag "$tag" || return
  ensure_port_available "$port"

  paths=$(obtain_tls_paths "$domain")
  cert=${paths%%|*}
  key=${paths#*|}
  uuid=$(new_uuid)

  tls=$(tls_json "$domain" "$cert" "$key")
  inbound=$(jq -n --arg tag "$tag" --arg listen "$listen_addr" --argjson port "$port" --arg uuid "$uuid" --argjson tls "$tls" \
    '{type:"vless",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",uuid:$uuid}],tls:$tls}')
  apply_inbound_with_route "$inbound" "$tag" "$outbound_tag"

  flag=$(get_server_flag)
  uri="vless://${uuid}@${formatted_host}:${port}?encryption=none&security=tls&type=tcp&sni=${domain}#${flag}%20VLESS-${mode}"
  
  meta=$(jq -n --arg uuid "$uuid" --arg sni "$domain" '{uuid:$uuid, sni:$sni, tls:true}')
  save_connection "vless-tls-${mode}" "$tag" "$domain" "$port" "$uri" "$meta"
  open_firewall_port "$port" tcp
  ok "VLESS TLS (${mode}) 部署完成！"
  show_qr_and_uri "$uri"
}

deploy_hysteria2() {
  ensure_installed
  local mode listen_addr outbound_tag domain formatted_host port paths cert key password obfs_password tag tls inbound uri flag meta
  mode=$(ask_node_network_mode)
  case "$mode" in
    v4) listen_addr="0.0.0.0"; outbound_tag="direct-v4" ;;
    v6) listen_addr="::";      outbound_tag="direct-v6" ;;
    *)  listen_addr="::";      outbound_tag="direct-dual" ;;
  esac

  domain=$(ask_required "Hysteria2 TLS 绑定域名")
  valid_hostname "$domain" || die "域名格式不正确。"
  formatted_host=$(format_host_uri "$domain")
  port=$(ask_port "Hysteria2 UDP 监听端口" 8443)
  tag="hy2-${mode}-${port}"
  check_and_handle_existing_tag "$tag" || return
  ensure_port_available "$port"

  paths=$(obtain_tls_paths "$domain")
  cert=${paths%%|*}
  key=${paths#*|}
  password=$(random_token)
  obfs_password=$(random_token)

  tls=$(tls_json "$domain" "$cert" "$key")
  inbound=$(jq -n --arg tag "$tag" --arg listen "$listen_addr" --argjson port "$port" --arg password "$password" --arg obfs "$obfs_password" --argjson tls "$tls" \
    '{type:"hysteria2",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",password:$password}],obfs:{type:"salamander",password:$obfs},tls:$tls}')
  apply_inbound_with_route "$inbound" "$tag" "$outbound_tag"

  flag=$(get_server_flag)
  uri="hysteria2://${password}@${formatted_host}:${port}?sni=${domain}&obfs=salamander&obfs-password=${obfs_password}#${flag}%20Hysteria2-${mode}"
  
  meta=$(jq -n --arg password "$password" --arg sni "$domain" --arg obfs "$obfs_password" \
    '{password:$password, sni:$sni, obfs:"salamander", obfs_password:$obfs}')
  save_connection "hysteria2-${mode}" "$tag" "$domain" "$port" "$uri" "$meta"
  open_firewall_port "$port" udp
  ok "Hysteria2 (${mode}) 部署完成！"
  show_qr_and_uri "$uri"
}

deploy_tuic() {
  ensure_installed
  local mode listen_addr outbound_tag domain formatted_host port paths cert key uuid password tag tls inbound uri flag meta
  mode=$(ask_node_network_mode)
  case "$mode" in
    v4) listen_addr="0.0.0.0"; outbound_tag="direct-v4" ;;
    v6) listen_addr="::";      outbound_tag="direct-v6" ;;
    *)  listen_addr="::";      outbound_tag="direct-dual" ;;
  esac

  domain=$(ask_required "TUIC TLS 绑定域名")
  valid_hostname "$domain" || die "域名格式不正确。"
  formatted_host=$(format_host_uri "$domain")
  port=$(ask_port "TUIC UDP 监听端口" 8443)
  tag="tuic-${mode}-${port}"
  check_and_handle_existing_tag "$tag" || return
  ensure_port_available "$port"

  paths=$(obtain_tls_paths "$domain")
  cert=${paths%%|*}
  key=${paths#*|}
  uuid=$(new_uuid)
  password=$(random_token)

  tls=$(tls_json "$domain" "$cert" "$key")
  inbound=$(jq -n --arg tag "$tag" --arg listen "$listen_addr" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" --argjson tls "$tls" \
    '{type:"tuic",tag:$tag,listen:$listen,listen_port:$port,users:[{name:"default",uuid:$uuid,password:$password}],congestion_control:"bbr",zero_rtt_handshake:false,tls:$tls}')
  apply_inbound_with_route "$inbound" "$tag" "$outbound_tag"

  flag=$(get_server_flag)
  uri="tuic://${uuid}:${password}@${formatted_host}:${port}?congestion_control=bbr&sni=${domain}#${flag}%20TUIC-${mode}"
  
  meta=$(jq -n --arg uuid "$uuid" --arg password "$password" --arg sni "$domain" \
    '{uuid:$uuid, password:$password, sni:$sni, congestion_control:"bbr"}')
  save_connection "tuic-${mode}" "$tag" "$domain" "$port" "$uri" "$meta"
  open_firewall_port "$port" udp
  ok "TUIC (${mode}) 部署完成！"
  show_qr_and_uri "$uri"
}

# ==================== Cloudflare Tunnel 全套穿透管理 ====================

install_cloudflared_binary() {
  if command -v cloudflared >/dev/null 2>&1; then
    ok "已检测到 cloudflared: $(cloudflared --version 2>&1 | head -n 1)"
    return 0
  fi
  require_apt
  info "配置 Cloudflare 官方 APT 软件源..."
  install -d -m 755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg -o /usr/share/keyrings/cloudflare-main.gpg
  tee /etc/apt/sources.list.d/cloudflared.list >/dev/null <<'EOF'
deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main
EOF
  apt-get update -y
  apt-get install -y cloudflared
  ok "cloudflared 二进制部署完毕。"
}

deploy_cloudflare_tunnel() {
  ensure_installed
  install_cloudflared_binary

  local domain port path path_encoded uuid tag inbound candidate uri tunnel_token
  domain=$(ask_required "Cloudflare 托管的隧道解析域名 (如: cf.yourdomain.com)")
  valid_hostname "$domain" || die "域名格式不合法。"

  port=$(ask_port "本地 VLESS WebSocket 监听端口 (仅监听 127.0.0.1)" 10000)
  ensure_port_available "$port"
  path=$(random_path)
  uuid=$(new_uuid)
  tag="vless-ws-cf-${port}"

  printf "\n请前往 Cloudflare Zero Trust 控制台 -> Networks -> Tunnels 创建 Tunnel：\n"
  printf "  1) Public Hostname 域名填写: %s\n" "$domain"
  printf "  2) Service 协议与端口选:     HTTP -> 127.0.0.1:%s\n\n" "$port"

  read -r -s -p "请输入后台生成的 Tunnel Token (输入不回显): " tunnel_token
  printf "\n"
  [[ -n $tunnel_token ]] || die "Tunnel Token 不能为空。"

  install -d -m 700 "$CF_DIR"
  printf '%s' "$tunnel_token" > "$CF_TOKEN_FILE"
  chmod 600 "$CF_TOKEN_FILE"

  tee "$CF_CONFIG" >/dev/null <<EOF
# Cloudflare Tunnel 自动化配置文件
ingress:
  - hostname: ${domain}
    service: http://127.0.0.1:${port}
  - service: http_status:404
EOF
  chmod 600 "$CF_CONFIG"

  info "注册 cloudflared 独立 systemd 守护进程..."
  systemctl stop cloudflared 2>/dev/null || true

  local cf_bin
  cf_bin=$(command -v cloudflared)

  tee /etc/systemd/system/cloudflared.service >/dev/null <<EOF
[Unit]
Description=Cloudflare Tunnel Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${cf_bin} --no-autoupdate tunnel run --token ${tunnel_token}
Restart=always
RestartSec=5
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now cloudflared

  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" \
    '{type:"vless",tag:$tag,listen:"127.0.0.1",listen_port:$port,users:[{name:"default",uuid:$uuid}],transport:{type:"ws",path:$path}}')
  candidate=$(mktemp_tracked)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"

  path_encoded=$(jq -nr --arg path "$path" '$path | @uri')
  local flag
  flag=$(get_server_flag)
  uri="vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=${path_encoded}&sni=${domain}#${flag}%20CF-Tunnel"
  
  local meta
  meta=$(jq -n --arg uuid "$uuid" --arg host "$domain" --arg path "$path" '{uuid:$uuid, transport:"ws", host:$host, path:$path}')
  save_connection "vless-ws-cloudflare-tunnel" "$tag" "$domain" 443 "$uri" "$meta"

  ok "Cloudflare Tunnel + VLESS WS 穿透节点部署成功！"
  show_qr_and_uri "$uri"
}

repair_cloudflared_service() {
  info "正在排查并自愈修复 Cloudflare Tunnel 服务..."
  install_cloudflared_binary
  if [[ ! -f $CF_TOKEN_FILE ]]; then
    warn "未找到已保存的 Token 存档，无法执行自动修复。"
    return 1
  fi
  local token cf_bin
  token=$(cat "$CF_TOKEN_FILE")
  cf_bin=$(command -v cloudflared)
  tee /etc/systemd/system/cloudflared.service >/dev/null <<EOF
[Unit]
Description=Cloudflare Tunnel Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${cf_bin} --no-autoupdate tunnel run --token ${token}
Restart=always
RestartSec=5
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl restart cloudflared
  sleep 1
  if systemctl is-active --quiet cloudflared; then
    ok "cloudflared 服务已修复并恢复正常运行！"
  else
    warn "服务重启后状态仍异常，请运行菜单选项查看日志排查。"
  fi
}

cf_tunnel_menu() {
  local choice
  while true; do
    printf "\n${CYAN}================= Cloudflare Tunnel 管理运维 =================${NC}\n"
    printf "  1) 查看 Tunnel 服务运行状态\n"
    printf "  2) 查看 Tunnel 实时运行日志\n"
    printf "  3) 重启 Cloudflare Tunnel 服务\n"
    printf "  4) 停止 Cloudflare Tunnel 服务\n"
    printf "  5) 重新绑定 Tunnel Token\n"
    printf "  6) 自动自愈修复 (Auto-Repair) cloudflared 服务\n"
    printf "  7) 彻底卸载 Cloudflare Tunnel 组件\n"
    printf "  0) 返回上一级\n"
    read -r -p "请选择: " choice
    case "$choice" in
      1)
        if systemctl list-unit-files --full | grep -q '^cloudflared\.service'; then
          systemctl --no-pager --full status cloudflared || true
        else
          warn "未检测到 cloudflared 服务。"
        fi
        ;;
      2) journalctl -u cloudflared -n 50 --no-pager -o cat ;;
      3)
        systemctl restart cloudflared
        ok "服务已发出重启指令。"
        ;;
      4)
        systemctl stop cloudflared
        ok "服务已停止。"
        ;;
      5)
        local new_tok cf_bin
        read -r -s -p "请输入新的 Cloudflare Tunnel Token: " new_tok
        printf "\n"
        if [[ -n $new_tok ]]; then
          printf '%s' "$new_tok" > "$CF_TOKEN_FILE"
          cf_bin=$(command -v cloudflared)
          sed -i -E "s|--token [^ ]+|--token ${new_tok}|" /etc/systemd/system/cloudflared.service 2>/dev/null || true
          systemctl daemon-reload
          systemctl restart cloudflared
          ok "Token 已更新，服务已重新载入。"
        else
          warn "输入不能为空。"
        fi
        ;;
      6) repair_cloudflared_service ;;
      7)
        if confirm "确认彻底卸载 cloudflared 吗？" N; then
          systemctl disable --now cloudflared 2>/dev/null || true
          rm -f /etc/systemd/system/cloudflared.service
          rm -rf "$CF_DIR"
          systemctl daemon-reload
          apt-get remove -y cloudflared 2>/dev/null || true
          ok "Cloudflare Tunnel 环境卸载完成。"
        fi
        ;;
      0) return ;;
      *) warn "无效选项。" ;;
    esac
  done
}

# ==================== Cloudflare WARP 原生 WireGuard 分流 ====================

register_warp_account() {
  local keypair priv_key pub_key
  keypair=$(generate_wireguard_keypair)
  priv_key=${keypair%%|*}
  pub_key=${keypair#*|}

  info "向 Cloudflare 注册官方免费 WARP (WireGuard) 账户凭证..."
  local payload curl_resp
  payload=$(jq -n --arg pub "$pub_key" --arg date "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '{
    install_id: "",
    tos: $date,
    key: $pub,
    type: "Android",
    locale: "zh_CN"
  }')

  curl_resp=$(curl -sSL --connect-timeout 8 --max-time 15 -X POST "https://api.cloudflareclient.com/v0a3371/reg" \
    -H 'User-Agent: okhttp/3.12.1' \
    -H 'Content-Type: application/json; charset=UTF-8' \
    -d "$payload" || true)

  if ! jq -e '.result.id' <<<"$curl_resp" >/dev/null 2>&1; then
    warn "WARP 官方 API 注册失败，响应内容: ${curl_resp:-无响应}"
    return 1
  fi

  jq --arg priv "$priv_key" '.result.local_private_key = $priv' <<<"$curl_resp" > "$WARP_CONF"
  chmod 600 "$WARP_CONF"
  ok "WARP 凭证已注册成功并安全归档。"
}

apply_warp_outbound() {
  local warp_mode=$1 # v4, v6, all
  ensure_installed

  if [[ ! -f $WARP_CONF ]] || ! jq -e '.result.local_private_key' "$WARP_CONF" >/dev/null 2>&1; then
    if ! register_warp_account; then
      die "无法获取 WARP 账户凭证，请检查宿主机外网连通性。"
    fi
  fi

  info "加载 WARP Curve25519 密钥与分配 IP..."
  local priv_key peer_pub v4_addr v6_addr client_id reserved candidate
  priv_key=$(jq -r '.result.local_private_key' "$WARP_CONF")
  peer_pub=$(jq -r '.result.config.peers[0].public_key // "bmXnwTXNXwSd6HNxNOgMSZaZuBzCqmJJMAWhHzfvqVo="' "$WARP_CONF")
  v4_addr=$(jq -r '.result.config.interface.addresses.v4 // "172.16.0.2"' "$WARP_CONF")
  v6_addr=$(jq -r '.result.config.interface.addresses.v6 // empty' "$WARP_CONF")
  client_id=$(jq -r '.result.config.client_id // empty' "$WARP_CONF")

  if [[ -n $client_id ]]; then
    reserved=$(printf '%s' "$client_id" | base64 -d 2>/dev/null | od -An -tu1 2>/dev/null | awk '{print "["$1","$2","$3"]"}')
  else
    reserved="[0,0,0]"
  fi
  [[ $reserved =~ ^\[[0-9]+,[0-9]+,[0-9]+\]$ ]] || reserved="[0,0,0]"

  local local_addrs_json
  local_addrs_json=$(jq -n --arg v4 "${v4_addr}/32" --arg v6 "${v6_addr:+${v6_addr}/128}" \
    '[$v4] + (if $v6 != "" then [$v6] else [] end)')

  local warp_outbound
  warp_outbound=$(jq -n \
    --arg priv "$priv_key" \
    --arg pub "$peer_pub" \
    --argjson addrs "$local_addrs_json" \
    --argjson rsv "$reserved" '{
      type: "wireguard",
      tag: "warp-out",
      server: "engage.cloudflareclient.com",
      server_port: 2408,
      local_address: $addrs,
      private_key: $priv,
      peer_public_key: $pub,
      reserved: $rsv,
      mtu: 1280
    }')

  candidate=$(mktemp_tracked)
  jq --argjson wo "$warp_outbound" '
    .outbounds |= map(select(.tag != "warp-out")) |
    .outbounds += [$wo]
  ' "$CONFIG_FILE" > "$candidate"

  case "$warp_mode" in
    v4)
      jq '.route.rules |= map(select(.tag != "warp_rule")) |
          .route.rules = [{"ip_version": 4, "outbound": "warp-out", "tag": "warp_rule"}] + .route.rules' "$candidate" > "${candidate}.2"
      mv "${candidate}.2" "$candidate"
      ;;
    v6)
      jq '.route.rules |= map(select(.tag != "warp_rule")) |
          .route.rules = [{"ip_version": 6, "outbound": "warp-out", "tag": "warp_rule"}] + .route.rules' "$candidate" > "${candidate}.2"
      mv "${candidate}.2" "$candidate"
      ;;
    all)
      jq '.route.rules |= map(select(.tag != "warp_rule")) |
          .route.rules = [{"outbound": "warp-out", "tag": "warp_rule"}] + .route.rules |
          .route.final = "warp-out"' "$candidate" > "${candidate}.2"
      mv "${candidate}.2" "$candidate"
      ;;
  esac

  apply_candidate "$candidate"
  ok "WARP 原生分流 [${warp_mode}] 配置成功并已生效！"
}

remove_warp() {
  local candidate
  candidate=$(mktemp_tracked)
  jq '
    .outbounds |= map(select(.tag != "warp-out")) |
    if .route.rules then .route.rules |= map(select(.tag != "warp_rule" and .outbound != "warp-out")) else . end |
    if .route.final == "warp-out" then .route.final = "direct" else . end
  ' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$WARP_CONF"
  ok "已完全清除 WARP 出站及其关联的智能分流规则。"
}

show_warp_status() {
  if ! jq -e '.outbounds[]? | select(.tag == "warp-out")' "$CONFIG_FILE" >/dev/null 2>&1; then
    warn "当前配置中未启用 WARP 出站。"
    return 0
  fi
  info "WARP 出站已在 sing-box 中启用。"
  local mode="全局接管 (所有节点走 WARP)"
  if jq -e '.route.rules[]? | select(.tag == "warp_rule" and .ip_version == 4)' "$CONFIG_FILE" >/dev/null 2>&1; then
    mode="IPv4 出口走 WARP"
  elif jq -e '.route.rules[]? | select(.tag == "warp_rule" and .ip_version == 6)' "$CONFIG_FILE" >/dev/null 2>&1; then
    mode="IPv6 出口走 WARP"
  fi
  printf "当前生效分流模式: %s\n" "$mode"
  if [[ -f $WARP_CONF ]]; then
    printf "分配 WARP IPv4:   %s\n" "$(jq -r '.result.config.interface.addresses.v4 // "未知"' "$WARP_CONF")"
    printf "分配 WARP IPv6:   %s\n" "$(jq -r '.result.config.interface.addresses.v6 // "无"' "$WARP_CONF")"
  fi
}

warp_menu() {
  local choice
  while true; do
    printf "\n${CYAN}================= Cloudflare WARP 原生分流管理 =================${NC}\n"
    printf "  1) 查看当前 WARP 状态与分流模式\n"
    printf "  2) 启用 / 切换为 IPv4 WARP 出口 (解锁 Netflix/OpenAI)\n"
    printf "  3) 启用 / 切换为 IPv6 WARP 出口 (为 VPS 赋能原生 IPv6)\n"
    printf "  4) 启用 / 切换为 全局 WARP 接管 (所有流量路由至 WARP)\n"
    printf "  5) 卸载并清除 WARP 出站\n"
    printf "  0) 返回上一级\n"
    read -r -p "请选择: " choice
    case "$choice" in
      1) show_warp_status ;;
      2) apply_warp_outbound "v4" ;;
      3) apply_warp_outbound "v6" ;;
      4) apply_warp_outbound "all" ;;
      5) remove_warp ;;
      0) return ;;
      *) warn "无效选项。" ;;
    esac
  done
}

# ==================== 统一订阅管理系统 (全协议覆盖) ====================

generate_all_subscriptions() {
  ensure_dirs
  [[ -f $STATE_FILE ]] || return 0
  local conns_count
  conns_count=$(jq '.connections | length' "$STATE_FILE")
  if (( conns_count == 0 )); then
    rm -f "${SUBS_DIR}/singbox.json" "${SUBS_DIR}/clash_meta.yaml" "${SUBS_DIR}/sub.txt" "${SUBS_DIR}/sub_base64.txt"
    return 0
  fi

  # 1. 导出 Raw 文本与 Base64 通用订阅串
  local raw_uris=""
  while IFS= read -r u; do
    [[ -n $u ]] && raw_uris+="${u}"$'\n'
  done < <(jq -r '.connections[]?.uri // empty' "$STATE_FILE")

  printf '%s' "$raw_uris" > "${SUBS_DIR}/sub.txt"
  printf '%s' "$raw_uris" | base64 | tr -d '\r\n' > "${SUBS_DIR}/sub_base64.txt"

  # 2. 生成 Mihomo / Clash Meta 代理 YAML (全协议完整映射)
  local yaml_file="${SUBS_DIR}/clash_meta.yaml"
  cat <<'EOF' > "$yaml_file"
# Mihomo / Clash Meta 自动订阅片段
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info
proxies:
EOF

  while IFS= read -r item; do
    local type tag host port meta flow
    type=$(jq -r '.type' <<<"$item")
    tag=$(jq -r '.tag' <<<"$item")
    host=$(jq -r '.host' <<<"$item")
    port=$(jq -r '.port' <<<"$item")
    meta=$(jq -c '.meta // {}' <<<"$item")
    flow=$(jq -r '.flow // empty' <<<"$meta")

    if [[ $type =~ vless-reality ]]; then
      cat <<EOF >> "$yaml_file"
  - name: "${tag}"
    type: vless
    server: ${host}
    port: ${port}
    uuid: $(jq -r '.uuid' <<<"$meta")
    cipher: none
    tls: true
    udp: true
    servername: $(jq -r '.sni' <<<"$meta")
    reality-opts:
      public-key: $(jq -r '.pbk' <<<"$meta")
      short-id: $(jq -r '.sid' <<<"$meta")
    client-fingerprint: chrome
EOF
      [[ -n $flow ]] && printf '    flow: %s\n' "$flow" >> "$yaml_file"
      if [[ $(jq -r '.transport // ""' <<<"$meta") == "grpc" ]]; then
        cat <<EOF >> "$yaml_file"
    network: grpc
    grpc-opts:
      grpc-service-name: $(jq -r '.service_name' <<<"$meta")
EOF
      fi
    elif [[ $type =~ shadowtls ]]; then
      cat <<EOF >> "$yaml_file"
  - name: "${tag}"
    type: ss
    server: ${host}
    port: ${port}
    cipher: 2022-blake3-aes-128-gcm
    password: $(jq -r '.ss_key' <<<"$meta")
    plugin: shadow-tls
    client-fingerprint: chrome
    plugin-opts:
      host: $(jq -r '.sni' <<<"$meta")
      password: $(jq -r '.st_password' <<<"$meta")
      version: 3
EOF
    elif [[ $type =~ shadowsocks-2022 ]]; then
      cat <<EOF >> "$yaml_file"
  - name: "${tag}"
    type: ss
    server: ${host}
    port: ${port}
    cipher: 2022-blake3-aes-128-gcm
    password: $(jq -r '.password' <<<"$meta")
    udp: true
EOF
    elif [[ $type =~ trojan ]]; then
      cat <<EOF >> "$yaml_file"
  - name: "${tag}"
    type: trojan
    server: ${host}
    port: ${port}
    password: $(jq -r '.password' <<<"$meta")
    sni: $(jq -r '.sni' <<<"$meta")
    skip-cert-verify: false
    udp: true
EOF
    elif [[ $type =~ vless-tls ]]; then
      cat <<EOF >> "$yaml_file"
  - name: "${tag}"
    type: vless
    server: ${host}
    port: ${port}
    uuid: $(jq -r '.uuid' <<<"$meta")
    cipher: none
    tls: true
    udp: true
    servername: $(jq -r '.sni' <<<"$meta")
    client-fingerprint: chrome
EOF
    elif [[ $type =~ vless-ws-cloudflare-tunnel ]]; then
      cat <<EOF >> "$yaml_file"
  - name: "${tag}"
    type: vless
    server: ${host}
    port: 443
    uuid: $(jq -r '.uuid' <<<"$meta")
    cipher: none
    tls: true
    udp: true
    servername: ${host}
    network: ws
    ws-opts:
      path: $(jq -r '.path' <<<"$meta")
      headers:
        Host: ${host}
EOF
    elif [[ $type =~ hysteria2 ]]; then
      cat <<EOF >> "$yaml_file"
  - name: "${tag}"
    type: hysteria2
    server: ${host}
    port: ${port}
    password: $(jq -r '.password' <<<"$meta")
    sni: $(jq -r '.sni' <<<"$meta")
    obfs: salamander
    obfs-password: $(jq -r '.obfs_password' <<<"$meta")
    skip-cert-verify: false
EOF
    elif [[ $type =~ tuic ]]; then
      cat <<EOF >> "$yaml_file"
  - name: "${tag}"
    type: tuic
    server: ${host}
    port: ${port}
    uuid: $(jq -r '.uuid' <<<"$meta")
    password: $(jq -r '.password' <<<"$meta")
    sni: $(jq -r '.sni' <<<"$meta")
    congestion-controller: bbr
    skip-cert-verify: false
EOF
    fi
  done < <(jq -c '.connections[]?' "$STATE_FILE")

  # 3. 生成完整可用的 sing-box 客户端 profile JSON (包含完整 Outbound 定义)
  local sb_client="${SUBS_DIR}/singbox.json"
  local candidate client_outbounds="[]"

  while IFS= read -r item; do
    local type tag host port meta ob_json
    type=$(jq -r '.type' <<<"$item")
    tag=$(jq -r '.tag' <<<"$item")
    host=$(jq -r '.host' <<<"$item")
    port=$(jq -r '.port' <<<"$item")
    meta=$(jq -c '.meta // {}' <<<"$item")

    if [[ $type =~ vless-reality ]]; then
      ob_json=$(jq -n \
        --arg tag "$tag" --arg srv "$host" --argjson port "$port" \
        --arg uuid "$(jq -r '.uuid' <<<"$meta")" \
        --arg flow "$(jq -r '.flow // empty' <<<"$meta")" \
        --arg sni "$(jq -r '.sni' <<<"$meta")" \
        --arg pbk "$(jq -r '.pbk' <<<"$meta")" \
        --arg sid "$(jq -r '.sid' <<<"$meta")" '{
          type: "vless",
          tag: $tag,
          server: $srv,
          server_port: $port,
          uuid: $uuid,
          tls: {
            enabled: true,
            server_name: $sni,
            utls: { enabled: true, fingerprint: "chrome" },
            reality: { enabled: true, public_key: $pbk, short_id: $sid }
          }
        } + (if $flow != "" then {flow: $flow} else {} end)')
      if [[ $(jq -r '.transport // ""' <<<"$meta") == "grpc" ]]; then
        ob_json=$(jq --arg svc "$(jq -r '.service_name' <<<"$meta")" '.transport = {type: "grpc", service_name: $svc}' <<<"$ob_json")
      fi
    elif [[ $type =~ shadowtls ]]; then
      local st_detour="${tag}-st"
      local st_ob ss_ob
      st_ob=$(jq -n \
        --arg tag "$st_detour" --arg srv "$host" --argjson port "$port" \
        --arg pwd "$(jq -r '.st_password' <<<"$meta")" \
        --arg sni "$(jq -r '.sni' <<<"$meta")" '{
          type: "shadowtls",
          tag: $tag,
          server: $srv,
          server_port: $port,
          version: 3,
          password: $pwd,
          tls: {
            enabled: true,
            server_name: $sni,
            utls: { enabled: true, fingerprint: "chrome" }
          }
        }')
      ss_ob=$(jq -n \
        --arg tag "$tag" --arg srv "$host" --argjson port "$port" \
        --arg pwd "$(jq -r '.ss_key' <<<"$meta")" \
        --arg detour "$st_detour" '{
          type: "shadowsocks",
          tag: $tag,
          server: $srv,
          server_port: $port,
          method: "2022-blake3-aes-128-gcm",
          password: $pwd,
          detour: $detour
        }')
      client_outbounds=$(jq --argjson st "$st_ob" --argjson ss "$ss_ob" '. += [$st, $ss]' <<<"$client_outbounds")
      continue
    elif [[ $type =~ shadowsocks-2022 ]]; then
      ob_json=$(jq -n \
        --arg tag "$tag" --arg srv "$host" --argjson port "$port" \
        --arg method "$(jq -r '.method' <<<"$meta")" \
        --arg pwd "$(jq -r '.password' <<<"$meta")" '{
          type: "shadowsocks",
          tag: $tag,
          server: $srv,
          server_port: $port,
          method: $method,
          password: $pwd
        }')
    elif [[ $type =~ trojan ]]; then
      ob_json=$(jq -n \
        --arg tag "$tag" --arg srv "$host" --argjson port "$port" \
        --arg pwd "$(jq -r '.password' <<<"$meta")" \
        --arg sni "$(jq -r '.sni' <<<"$meta")" '{
          type: "trojan",
          tag: $tag,
          server: $srv,
          server_port: $port,
          password: $pwd,
          tls: { enabled: true, server_name: $sni }
        }')
    elif [[ $type =~ vless-tls ]]; then
      ob_json=$(jq -n \
        --arg tag "$tag" --arg srv "$host" --argjson port "$port" \
        --arg uuid "$(jq -r '.uuid' <<<"$meta")" \
        --arg sni "$(jq -r '.sni' <<<"$meta")" '{
          type: "vless",
          tag: $tag,
          server: $srv,
          server_port: $port,
          uuid: $uuid,
          tls: { enabled: true, server_name: $sni }
        }')
    elif [[ $type =~ vless-ws-cloudflare-tunnel ]]; then
      ob_json=$(jq -n \
        --arg tag "$tag" --arg srv "$host" \
        --arg uuid "$(jq -r '.uuid' <<<"$meta")" \
        --arg path "$(jq -r '.path' <<<"$meta")" '{
          type: "vless",
          tag: $tag,
          server: $srv,
          server_port: 443,
          uuid: $uuid,
          tls: { enabled: true, server_name: $srv },
          transport: { type: "ws", path: $path, headers: { Host: $srv } }
        }')
    elif [[ $type =~ hysteria2 ]]; then
      ob_json=$(jq -n \
        --arg tag "$tag" --arg srv "$host" --argjson port "$port" \
        --arg pwd "$(jq -r '.password' <<<"$meta")" \
        --arg sni "$(jq -r '.sni' <<<"$meta")" \
        --arg obfs "$(jq -r '.obfs_password' <<<"$meta")" '{
          type: "hysteria2",
          tag: $tag,
          server: $srv,
          server_port: $port,
          password: $pwd,
          tls: { enabled: true, server_name: $sni },
          obfs: { type: "salamander", password: $obfs }
        }')
    elif [[ $type =~ tuic ]]; then
      ob_json=$(jq -n \
        --arg tag "$tag" --arg srv "$host" --argjson port "$port" \
        --arg uuid "$(jq -r '.uuid' <<<"$meta")" \
        --arg pwd "$(jq -r '.password' <<<"$meta")" \
        --arg sni "$(jq -r '.sni' <<<"$meta")" '{
          type: "tuic",
          tag: $tag,
          server: $srv,
          server_port: $port,
          uuid: $uuid,
          password: $pwd,
          congestion_control: "bbr",
          tls: { enabled: true, server_name: $sni }
        }')
    else
      continue
    fi
    client_outbounds=$(jq --argjson ob "$ob_json" '. += [$ob]' <<<"$client_outbounds")
  done < <(jq -c '.connections[]?' "$STATE_FILE")

  candidate=$(mktemp_tracked)
  jq -n --argjson obs "$client_outbounds" '{
    "$schema": "https://sing-box.sagernet.org/schema.json",
    log: { level: "info" },
    dns: {
      servers: [
        { tag: "remote-dns", address: "tls://8.8.8.8" },
        { tag: "local-dns", address: "local", detour: "direct" }
      ]
    },
    inbounds: [
      { type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 2080 }
    ],
    outbounds: ([
      { type: "selector", tag: "proxy", outbounds: ($obs | map(select(.type != "shadowtls") | .tag)) },
      { type: "direct", tag: "direct" },
      { type: "block", tag: "block" }
    ] + $obs)
  }' > "$candidate"
  install -m 600 "$candidate" "$sb_client"
}

show_subscription_menu() {
  local choice
  while true; do
    printf "\n${CYAN}================= 客户端订阅与配置导出中心 =================${NC}\n"
    printf "  1) 查看通用 Base64 订阅内容 (Shadowrocket / v2rayN 通用)\n"
    printf "  2) 查看 / 导出 Mihomo (Clash Meta) 配置文件\n"
    printf "  3) 查看 / 导出 sing-box 客户端标准 profile 格式 (全节点就绪)\n"
    printf "  4) 手动重建并刷新全套客户端订阅\n"
    printf "  0) 返回上一级\n"
    read -r -p "请选择: " choice
    case "$choice" in
      1)
        if [[ -f "${SUBS_DIR}/sub_base64.txt" ]]; then
          printf "\n${GREEN}通用 Base64 订阅内容如下：${NC}\n"
          cat "${SUBS_DIR}/sub_base64.txt"
          printf "\n\n"
        else
          warn "暂无已保存的节点连接记录。"
        fi
        ;;
      2)
        if [[ -f "${SUBS_DIR}/clash_meta.yaml" ]]; then
          printf "\n${GREEN}Clash Meta 配置文件片段：${NC}\n"
          cat "${SUBS_DIR}/clash_meta.yaml"
          printf "\n"
        else
          warn "未生成 Clash 配置文件。"
        fi
        ;;
      3)
        if [[ -f "${SUBS_DIR}/singbox.json" ]]; then
          printf "\n${GREEN}sing-box 客户端配置模板：${NC}\n"
          cat "${SUBS_DIR}/singbox.json"
          printf "\n"
        else
          warn "未生成 sing-box 订阅文件。"
        fi
        ;;
      4)
        generate_all_subscriptions
        ok "全套订阅文件已成功重建 (保存在目录: ${SUBS_DIR})。"
        ;;
      0) return ;;
      *) warn "无效选项。" ;;
    esac
  done
}

# ==================== 国际多节点测速与吞吐测试 ====================

run_speed_test() {
  info "正在探测核心国际 CDN / DNS 往返延迟 (RTT)..."
  printf "\n%-25s %-28s %-15s\n" "测试目标" "往返握手延迟 (RTT)" "连通性"
  printf '%s\n' "----------------------------------------------------------------------"

  local -a targets=(
    "Cloudflare:https://1.1.1.1"
    "Google-DNS:https://dns.google"
    "Microsoft:https://www.microsoft.com"
    "Apple-iCloud:https://gateway.icloud.com"
    "AWS-CloudFront:https://aws.amazon.com"
  )

  for item in "${targets[@]}"; do
    local name url lat
    name=${item%%:*}
    url=${item#*:}
    lat=$(curl -o /dev/null -s -w '%{time_connect}\n' --connect-timeout 3 "$url" 2>/dev/null || echo "0")
    if (( $(echo "$lat > 0" | bc -l 2>/dev/null || echo 0) )); then
      local ms
      ms=$(echo "$lat * 1000 / 1" | bc 2>/dev/null || echo "N/A")
      printf "%-25s %-28s %-15s\n" "$name" "${ms} ms" "正常"
    else
      printf "%-25s %-28s %-15s\n" "$name" "超时/不可达" "不可达"
    fi
  done

  printf "\n${CYAN}测定服务器双向带宽吞吐率 (基于 Cloudflare CDN 网络)...${NC}\n"
  local down_speed down_mbps
  down_speed=$(curl -sk --connect-timeout 5 --max-time 10 -w '%{speed_download}\n' -o /dev/null \
    "https://speed.cloudflare.com/__down?bytes=100000000" 2>/dev/null || echo "0")
  down_mbps=$(echo "scale=2; $down_speed * 8 / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
  ok "下行下载峰值吞吐: ${down_mbps} Mbps"

  local up_tmp up_speed up_mbps
  up_tmp=$(mktemp_tracked)
  head -c 10485760 </dev/zero > "$up_tmp" 2>/dev/null || true
  up_speed=$(curl -sk --connect-timeout 5 --max-time 10 -w '%{speed_upload}\n' -o /dev/null \
    --data-binary @"$up_tmp" "https://speed.cloudflare.com/__up" 2>/dev/null || echo "0")
  up_mbps=$(echo "scale=2; $up_speed * 8 / 1024 / 1024" | bc -l 2>/dev/null || echo "0")
  ok "上行上传峰值吞吐: ${up_mbps} Mbps"
}

# ==================== 系统全维自检与健康诊断 (9维) ====================

run_full_system_diagnostic() {
  info "正在执行 9 项关键维度深度系统健康诊断..."
  printf "\n${BOLD}%-28s %-18s %s${NC}\n" "检查项目" "诊断结果" "状态说明/检测指标"
  printf '%s\n' "--------------------------------------------------------------------------------"

  local conflicts=0
  local conflict_details=""
  if [[ -f $CONFIG_FILE ]]; then
    while IFS= read -r port; do
      if [[ -n $port && $port != "null" ]]; then
        local other_proc
        other_proc=$(ss -tulnpH "sport = :$port" 2>/dev/null | grep -v "sing-box" | awk '{print $NF}' | head -n 1 || true)
        if [[ -n $other_proc ]]; then
          ((conflicts++)) || true
          conflict_details="端口 ${port} 被 ${other_proc} 抢占"
        fi
      fi
    done < <(jq -r '.inbounds[]?.listen_port // empty' "$CONFIG_FILE")
  fi
  if (( conflicts == 0 )); then
    printf "%-28s ${GREEN}%-18s${NC} %s\n" "端口绑定冲突" "正常" "已声明业务端口无第三方冲突抢占"
  else
    printf "%-28s ${RED}%-18s${NC} %s\n" "端口绑定冲突" "存在冲突" "${conflict_details:-检测到端口已被抢占}"
  fi

  if host -W 2 google.com >/dev/null 2>&1 || curl -s --connect-timeout 2 https://1.1.1.1 >/dev/null 2>&1; then
    printf "%-28s ${GREEN}%-18s${NC} %s\n" "系统 DNS 解析" "正常" "公网与海外 CDN 域名解析通畅"
  else
    printf "%-28s ${RED}%-18s${NC} %s\n" "系统 DNS 解析" "异常" "请排查 /etc/resolv.conf 权威源配置"
  fi

  local v4_ip
  v4_ip=$(detect_public_ip || true)
  if check_ipv4_egress; then
    printf "%-28s ${GREEN}%-18s${NC} %s\n" "IPv4 出口状态" "连通良好" "${v4_ip:-已连通}"
  else
    printf "%-28s ${YELLOW}%-18s${NC} %s\n" "IPv4 出口状态" "不可用" "宿主机无 IPv4 默认出口路由"
  fi

  local v6_ip
  v6_ip=$(detect_public_ipv6 || true)
  if check_ipv6_egress; then
    printf "%-28s ${GREEN}%-18s${NC} %s\n" "IPv6 出口状态" "连通良好" "${v6_ip:-已连通}"
  else
    printf "%-28s ${YELLOW}%-18s${NC} %s\n" "IPv6 出口状态" "未启用/不可达" "宿主机无原生 IPv6 连通路由"
  fi

  local cc
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
  if [[ $cc == "bbr" ]]; then
    printf "%-28s ${GREEN}%-18s${NC} %s\n" "TCP 拥塞算法" "BBR 活跃生效" "当前内核算法: ${cc}"
  else
    printf "%-28s ${YELLOW}%-18s${NC} %s\n" "TCP 拥塞算法" "未开启 BBR" "当前使用: ${cc}"
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
    printf "%-28s ${YELLOW}%-18s${NC} %s\n" "防火墙策略 (UFW)" "启用中" "请确保全部业务端口已设置 allow"
  else
    printf "%-28s ${GREEN}%-18s${NC} %s\n" "防火墙策略 (UFW)" "放通/未启用" "本地无规则拦截端口"
  fi

  if command -v cloudflared >/dev/null 2>&1; then
    if systemctl is-active --quiet cloudflared; then
      printf "%-28s ${GREEN}%-18s${NC} %s\n" "Cloudflare Tunnel" "常驻运行" "隧道服务正常通信"
    else
      printf "%-28s ${YELLOW}%-18s${NC} %s\n" "Cloudflare Tunnel" "服务停止" "隧道未激活，可通过菜单修复"
    fi
  else
    printf "%-28s %-18s %s\n" "Cloudflare Tunnel" "未配置" "未部署该穿透组件"
  fi

  if sing-box check -c "$CONFIG_FILE" >/dev/null 2>&1; then
    printf "%-28s ${GREEN}%-18s${NC} %s\n" "sing-box 语法校验" "通过" "JSON 架构合法且出站对齐"
  else
    printf "%-28s ${RED}%-18s${NC} %s\n" "sing-box 语法校验" "失败" "存在语法错，请执行 sb check"
  fi

  if systemctl is-active --quiet sing-box; then
    printf "%-28s ${GREEN}%-18s${NC} %s\n" "sing-box 进程状态" "运行中" "Active (running)"
  else
    printf "%-28s ${RED}%-18s${NC} %s\n" "sing-box 进程状态" "停止" "服务异常中断，请排查日志"
  fi
  printf "\n"
}

# ==================== 运维与连接节点查询 ====================

show_connections() {
  ensure_dirs
  local count
  count=$(jq '.connections | length' "$STATE_FILE")
  if (( count == 0 )); then
    warn "当前尚未通过本管理系统部署任何节点记录。"
    return
  fi
  printf "\n${CYAN}======================== 已保存的节点连接列表 ========================${NC}\n"
  local i tag type host port uri
  for (( i=0; i<count; i++ )); do
    tag=$(jq -r ".connections[$i].tag" "$STATE_FILE")
    type=$(jq -r ".connections[$i].type" "$STATE_FILE")
    host=$(jq -r ".connections[$i].host" "$STATE_FILE")
    port=$(jq -r ".connections[$i].port" "$STATE_FILE")
    uri=$(jq -r ".connections[$i].uri" "$STATE_FILE")
    printf "${BOLD}%d) [%s] %s -> %s:%s${NC}\n" "$((i+1))" "$type" "$tag" "$host" "$port"
    printf "   连接串: %s\n\n" "$uri"
  done

  if confirm "是否选择某个节点打印终端二维码？" N; then
    local node_num
    read -r -p "请输入要打印二维码的节点序号 (1-${count}): " node_num
    if [[ $node_num =~ ^[0-9]+$ ]] && (( node_num >= 1 && node_num <= count )); then
      local selected_uri
      selected_uri=$(jq -r ".connections[$((node_num-1))].uri" "$STATE_FILE")
      show_qr_and_uri "$selected_uri"
    else
      warn "输入序号无效。"
    fi
  fi
}

list_inbounds() {
  ensure_base_routing
  jq -r '.inbounds | to_entries[] | "\(.key + 1). \(.value.tag) [\(.value.type)] 端口:\(.value.listen_port // "Detour")"' "$CONFIG_FILE"
}

remove_inbound() {
  ensure_installed
  if [[ $(jq '.inbounds | length' "$CONFIG_FILE") -eq 0 ]]; then
    warn "当前配置中没有任何活动入站节点。"
    return
  fi
  printf "\n当前已激活的 Inbound 节点列表：\n"
  list_inbounds
  local tag candidate detour_tag
  tag=$(ask_required "请输入要删除节点的 Tag 标识")
  jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1 || die "未匹配到对应的节点 Tag。"
  confirm "确认彻底删除 [${tag}] 并联动清除关联路由规则？" N || return

  detour_tag=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag) | .detour // empty' "$CONFIG_FILE")

  candidate=$(mktemp_tracked)
  jq --arg tag "$tag" --arg detour "$detour_tag" '
    .inbounds |= map(select(.tag != $tag and (.tag != $detour or $detour == ""))) |
    if .route.rules then
      .route.rules |= map(select(
        ((.inbound // []) | index($tag) | not) and
        ((.inbound // []) | index($detour) | not)
      ))
    else . end
  ' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"

  candidate=$(mktemp_tracked)
  jq --arg tag "$tag" '.connections |= map(select(.tag != $tag))' "$STATE_FILE" > "$candidate"
  install -m 600 "$candidate" "$STATE_FILE"
  generate_all_subscriptions
  ok "节点 [${tag}] ${detour_tag:+及附属 [$detour_tag] }已被安全剔除，路由规则与订阅已同步刷新。"
}

validate_and_restart() {
  ensure_installed
  sing-box check -c "$CONFIG_FILE"
  systemctl enable --now sing-box
  systemctl restart sing-box
  ok "配置语法通过验证，sing-box 服务已平滑重启。"
}

show_status() {
  ensure_installed
  local net_type public_ipv4 public_ipv6
  net_type=$(detect_network_stack_type)
  public_ipv4=$(detect_public_ip || true)
  public_ipv6=$(detect_public_ipv6 || true)

  printf "\n${CYAN}======================= sing-box 服务与网络拓扑概览 =======================${NC}\n"
  printf "核心版本: "
  sing-box version | head -n 1
  printf "出站分流策略关键字: %s\n" "$(detect_strategy_field)"
  printf "宿主机网络栈状态:   %s\n" "$net_type"
  printf "公网 IPv4:          %s\n" "${public_ipv4:-未检测到}"
  printf "公网 IPv6:          %s\n" "${public_ipv6:-未检测到}"
  printf "\n${BOLD}[服务进程运行状态]${NC}\n"
  systemctl --no-pager --full status sing-box || true
  printf "\n${BOLD}[当前监听中的入站]${NC}\n"
  jq -r '.inbounds[]? | "- \(.tag) [\(.type)] 监听 \(.listen // "Detour"):\(.listen_port // "-")"' "$CONFIG_FILE" 2>/dev/null || true
}

show_logs() {
  journalctl -u sing-box -n 120 --no-pager -o cat
}

enable_bbr() {
  require_root
  local virt
  virt=$(systemd-detect-virt 2>/dev/null || true)
  if [[ "$virt" =~ (lxc|openvz|container) ]]; then
    warn "检测到当前处于容器虚拟化环境 ($virt)，内核层可能不允许自定义拥塞控制算法。"
  fi
  local sysctl_file="/etc/sysctl.d/99-sing-box-bbr.conf"
  tee "$sysctl_file" >/dev/null <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1 || sysctl -p "$sysctl_file" >/dev/null 2>&1 || warn "sysctl 返回非 0，若为容器需宿主机支持。"
  ok "BBR 拥塞控制配置已写入；当前内核算法: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '未知')"
}

restore_backup() {
  ensure_installed
  local -a files=()
  mapfile -t files < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.json' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 5 | cut -d' ' -f2-)
  
  if (( ${#files[@]} == 0 )); then
    die "未发现任何可用的历史备份快照。"
  fi

  printf "\n可用配置快照列表 (最多展示最近 5 个)：\n"
  local i
  for i in "${!files[@]}"; do
    printf "  %d) %s (%s)\n" "$((i+1))" "$(basename "${files[$i]}")" "$(date -r "${files[$i]}" '+%Y-%m-%d %H:%M:%S')"
  done

  local pick
  read -r -p "请选择需要恢复的快照序号 [1]: " pick
  pick=${pick:-1}
  (( pick >= 1 && pick <= ${#files[@]} )) || die "选择序号无效。"

  local target_file="${files[$((pick-1))]}"
  warn "将回滚至配置快照: $target_file"
  confirm "确认恢复该备份快照？" N || return

  local candidate
  candidate=$(mktemp_tracked)
  install -m 600 "$target_file" "$candidate"
  apply_candidate "$candidate"
  ok "配置已回退，服务已基于历史配置重启。"
}

upgrade_sing_box() {
  ensure_installed
  info "通过官方 APT 源检查并升级 sing-box..."
  apt-get update -y
  apt-get install -y --only-upgrade sing-box
  validate_and_restart
  ok "升级完成，当前版本: $(sing-box version | head -n 1)"
}

update_manager() {
  local candidate
  candidate=$(mktemp_tracked)
  info "正在拉取最新版本管理运维引擎: $SCRIPT_UPDATE_URL"
  curl -fL --proto '=https' --tlsv1.2 "$SCRIPT_UPDATE_URL" -o "$candidate"
  bash -n "$candidate"
  install -D -m 700 "$candidate" "$MANAGER_PATH"
  tee "$SHORTCUT_PATH" >/dev/null <<EOF
#!/usr/bin/env bash
exec ${MANAGER_PATH} "\$@"
EOF
  chmod 755 "$SHORTCUT_PATH"
  ok "管理系统更新成功，直接键入 sb 即可享受最新特性。"
}

uninstall_sing_box() {
  require_root
  warn "此操作将停止服务并卸载 sing-box 核心；用户配置和历史订阅仍安全保存在 ${STATE_DIR}。"
  confirm "确认卸载 sing-box 核心程序？" N || return
  systemctl disable --now sing-box 2>/dev/null || true
  apt-get remove -y sing-box 2>/dev/null || true
  ok "sing-box 程序卸载完成。"
}

# ==================== 控制台主菜单系统 ====================

print_menu() {
  local v4_tag="[IPv4不可用]" v6_tag="[IPv6不可用]"
  check_ipv4_egress && v4_tag="${GREEN}[IPv4正常]${NC}"
  check_ipv6_egress && v6_tag="${GREEN}[IPv6正常]${NC}"
  printf "\n${CYAN}================================================================${NC}\n"
  printf " ${BOLD}sing-box VPS 全能智能运维引擎 v%s %b %b${NC}\n" "$SCRIPT_VERSION" "$v4_tag" "$v6_tag"
  printf "${CYAN}================================================================${NC}\n"
  printf " ${BOLD}[VLESS Reality 核心入站]${NC}\n"
  printf "   1) 部署 VLESS Reality Dual (双栈智能自适应推荐)\n"
  printf "   2) 部署 VLESS Reality IPv4 (强制锁定 IPv4 出口)\n"
  printf "   3) 部署 VLESS Reality IPv6 (IPv6 优先，适合双栈/纯 IPv6)\n"
  printf "   4) 部署 VLESS Reality gRPC (云原生通道，多路复用)\n\n"
  printf " ${BOLD}[抗封锁 / 强伪装 / 经典协议]${NC}\n"
  printf "   5) 部署 ShadowTLS v3 + SS2022 (TLS 1.3 终极伪装)\n"
  printf "   6) 部署 Shadowsocks 2022 (BLAKE3 极速对称加密)\n"
  printf "   7) 部署 Trojan TLS (原生 TLS 伪装 Web 入站)\n"
  printf "   8) 部署 VLESS TLS (标准 TLS 传输)\n"
  printf "   9) 部署 Hysteria2 (UDP QUIC 暴力单流抗丢包)\n"
  printf "  10) 部署 TUIC v5 (高并发 QUIC 原生代理)\n\n"
  printf " ${BOLD}[穿透拓展与智能路由分流]${NC}\n"
  printf "  11) Cloudflare Tunnel 穿透管理菜单 (救砖/无公网端口)\n"
  printf "  12) Cloudflare WARP 原生分流菜单 (解锁流媒体/为 VPS 赋能 IPv6)\n\n"
  printf " ${BOLD}[节点导出与订阅中心]${NC}\n"
  printf "  13) 查看已保存的节点连接串 (支持打印二维码)\n"
  printf "  14) 客户端全协议订阅导出中心 (Clash Meta / sing-box / Base64)\n"
  printf "  15) 删除指定入站节点 (联动清理分流路由)\n\n"
  printf " ${BOLD}[系统运维 / 网络自检与安全]${NC}\n"
  printf "  16) 运行 9 项全维深度健康自检与诊断\n"
  printf "  17) 国际出口网络延迟与带宽吞吐测速\n"
  printf "  18) TLS / SSL 证书全生命周期管理\n"
  printf "  19) 查看 sing-box 实时运行日志\n"
  printf "  20) 查看服务状态与网络拓扑\n"
  printf "  21) 校验当前配置并重启服务\n"
  printf "  22) 一键启用系统内核 TCP BBR 加速\n"
  printf "  23) 恢复历史配置快照备份 (多版本可选)\n"
  printf "  24) 升级 sing-box 核心软件\n"
  printf "  25) 升级本管理运维脚本源码\n"
  printf "  26) 卸载 sing-box 核心\n"
  printf "   0) 退出管理控制台\n"
  printf "${CYAN}----------------------------------------------------------------${NC}\n"
}

main_menu() {
  local choice
  while true; do
    print_menu
    read -r -p "请输入操作序号 [0-26]: " choice
    case "$choice" in
      1) deploy_vless_reality_unified "dual" ;;
      2) deploy_vless_reality_unified "v4" ;;
      3) deploy_vless_reality_unified "v6" ;;
      4) deploy_vless_reality_grpc ;;
      5) deploy_shadowtls_ss2022 ;;
      6) deploy_shadowsocks ;;
      7) deploy_trojan ;;
      8) deploy_vless ;;
      9) deploy_hysteria2 ;;
      10) deploy_tuic ;;
      11) cf_tunnel_menu ;;
      12) warp_menu ;;
      13) show_connections ;;
      14) show_subscription_menu ;;
      15) remove_inbound ;;
      16) run_full_system_diagnostic ;;
      17) run_speed_test ;;
      18) manage_certificates_menu ;;
      19) show_logs ;;
      20) show_status ;;
      21) validate_and_restart ;;
      22) enable_bbr ;;
      23) restore_backup ;;
      24) upgrade_sing_box ;;
      25) update_manager ;;
      26) uninstall_sing_box ;;
      0) exit 0 ;;
      *) warn "输入无效，请重新选择。" ;;
    esac
  done
}

usage() {
  cat <<EOF
用法: sb [命令]

可用命令列表:
  menu          打开交互式控制台主菜单 (默认)
  install       安装 sing-box 及其运行时环境
  reality       一键部署 VLESS Reality Dual (双栈)
  grpc          一键部署 VLESS Reality gRPC
  shadowtls     一键部署 ShadowTLS v3 + SS2022
  ss            一键部署 Shadowsocks 2022
  trojan        一键部署 Trojan TLS
  vless         一键部署 VLESS TLS
  hy2           一键部署 Hysteria2
  tuic          一键部署 TUIC v5
  cftunnel      进入 Cloudflare Tunnel 管理菜单
  warp          进入 Cloudflare WARP 原生分流菜单
  links         查看全部连接串并支持二维码生成
  subs          进入多客户端订阅管理中心
  diag          执行 9 项全维系统深度体检
  test          执行国际出口延迟与带宽吞吐测速
  certs         管理 SSL / TLS 证书生命周期
  logs          查看 sing-box 实时运行日志
  status        查看服务活跃状态与网络拓扑
  check         语法校验并平滑重启服务
  bbr           配置内核级 BBR 拥塞控制
  rollback      回滚恢复历史配置快照
  upgrade       在线更新 sing-box 官方程序包
  self-update   在线更新本管理脚本源码
  uninstall     卸载 sing-box 核心
EOF
}

# ==================== 主程序入口 ====================

main() {
  case ${1:-menu} in
    -h|--help|help) usage; return ;;
  esac
  require_root
  case ${1:-menu} in
    menu)                      main_menu ;;
    install)                   install_sing_box ;;
    reality|reality-dual)      deploy_vless_reality_unified "dual" ;;
    reality-v4)                deploy_vless_reality_unified "v4" ;;
    reality-v6)                deploy_vless_reality_unified "v6" ;;
    grpc|reality-grpc)         deploy_vless_reality_grpc ;;
    shadowtls)                 deploy_shadowtls_ss2022 ;;
    ss)                        deploy_shadowsocks ;;
    trojan)                    deploy_trojan ;;
    vless)                     deploy_vless ;;
    hy2)                       deploy_hysteria2 ;;
    tuic)                      deploy_tuic ;;
    cftunnel)                  cf_tunnel_menu ;;
    cfstatus)                  systemctl --no-pager --full status cloudflared 2>/dev/null || true ;;
    warp)                      warp_menu ;;
    links)                     show_connections ;;
    subs)                      show_subscription_menu ;;
    diag|health)               run_full_system_diagnostic ;;
    test)                      run_speed_test ;;
    certs)                     manage_certificates_menu ;;
    logs)                      show_logs ;;
    status)                    show_status ;;
    check)                     validate_and_restart ;;
    bbr)                       enable_bbr ;;
    rollback)                  restore_backup ;;
    remove)                    remove_inbound ;;
    upgrade)                   upgrade_sing_box ;;
    self-update)               update_manager ;;
    uninstall)                 uninstall_sing_box ;;
    *)                         usage; exit 1 ;;
  esac
}

main "$@"
