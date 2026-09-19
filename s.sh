#!/usr/bin/env bash
# sing-box VPS deployer. Configuration fields and package repository follow
# https://sing-box.sagernet.org/installation/package-manager/
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="1.0.0"
readonly CONFIG_DIR="/etc/sing-box"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly STATE_DIR="/var/lib/sing-box-vps"
readonly STATE_FILE="${STATE_DIR}/connections.json"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly CERT_HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-sing-box"
readonly MANAGER_PATH="/usr/local/sbin/sing-box-vps"
readonly SHORTCUT_PATH="/usr/local/bin/sb"
readonly SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/lisiyong0707/sing-box-vps/main/sing-box-vps.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { printf "${BLUE}[i]${NC} %s\n" "$*"; }
ok() { printf "${GREEN}[+]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
die() { printf "${RED}[x]${NC} %s\n" "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf "${RED}[x]${NC} 失败：第 %s 行退出（状态 %s）。\n" "$1" "$exit_code" >&2
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

require_root() {
  [[ ${EUID} -eq 0 ]] || die "请使用 sudo bash $0 运行。"
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "此脚本需要 systemd。"
}

require_apt() {
  command -v apt-get >/dev/null 2>&1 || die "当前版本支持 Debian/Ubuntu（APT）系统。"
}

ensure_dirs() {
  install -d -m 700 "$CONFIG_DIR" "$STATE_DIR" "$BACKUP_DIR"
  if [[ ! -f "$STATE_FILE" ]]; then
    printf '{"connections":[]}\n' > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
  fi
}

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
    warn "此项不能为空。"
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
    warn "端口必须是 1 到 65535 的整数。"
  done
}

valid_hostname() {
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

detect_public_ip() {
  local ip
  for endpoint in https://api.ipify.org https://ifconfig.me/ip; do
    ip=$(curl -4fsS --connect-timeout 3 --max-time 6 "$endpoint" 2>/dev/null || true)
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { printf '%s' "$ip"; return; }
  done
  hostname -I 2>/dev/null | awk '{print $1}'
}

detect_public_ipv6() {
  local ip
  for endpoint in https://api64.ipify.org https://ifconfig.co/ip; do
    ip=$(curl -6fsS --connect-timeout 3 --max-time 6 "$endpoint" 2>/dev/null || true)
    [[ $ip == *:* ]] && { printf '%s' "$ip"; return; }
  done
  return 0
}

ask_server_address() {
  local default value
  default=$(detect_public_ip)
  read -r -p "客户端连接地址（公网 IP 或域名） [${default:-请填写}]: " value
  value=${value:-$default}
  [[ -n $value ]] || die "需要一个客户端可访问的地址。"
  printf '%s' "$value"
}

install_prerequisites() {
  require_apt
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl jq openssl iproute2
}

install_sing_box() {
  require_root
  require_systemd
  install_prerequisites
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
  apt-get update
  apt-get install -y sing-box
  ensure_dirs
  systemctl enable sing-box
  install_manager
  ok "已安装 $(sing-box version | head -n 1)"
}

install_manager() {
  local source_path=${BASH_SOURCE[0]}
  if [[ ! -r $source_path ]]; then
    warn "无法读取当前脚本，未创建 sb 快捷命令。请从本地文件或 curl 下载文件后运行一次。"
    return
  fi
  install -D -m 700 "$source_path" "$MANAGER_PATH"
  tee "$SHORTCUT_PATH" >/dev/null <<EOF
#!/usr/bin/env bash
exec ${MANAGER_PATH} "\$@"
EOF
  chmod 755 "$SHORTCUT_PATH"
  ok "已创建快捷命令：sb"
}

ensure_installed() {
  command -v sing-box >/dev/null 2>&1 || install_sing_box
  command -v jq >/dev/null 2>&1 || install_prerequisites
  ensure_dirs
}

create_base_config() {
  [[ -f $CONFIG_FILE ]] && return
  info "创建基础配置"
  local candidate
  candidate=$(mktemp)
  jq -n '{
    "$schema": "https://sing-box.sagernet.org/schema.json",
    log: { level: "info", timestamp: true },
    inbounds: [],
    outbounds: [
      { type: "direct", tag: "direct" },
      { type: "block", tag: "block" }
    ],
    route: { final: "direct" }
  }' > "$candidate"
  install -m 600 "$candidate" "$CONFIG_FILE"
  rm -f "$candidate"
}

backup_config() {
  [[ -f $CONFIG_FILE ]] || return
  local stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  install -m 600 "$CONFIG_FILE" "${BACKUP_DIR}/config-${stamp}.json"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.json' -printf '%T@ %p\n' \
    | sort -nr | awk 'NR>10 {print $2}' | xargs -r rm -f
}

validate_candidate() {
  local candidate=$1
  sing-box check -c "$candidate"
}

apply_candidate() {
  local candidate=$1
  validate_candidate "$candidate"
  backup_config
  install -m 600 "$candidate" "$CONFIG_FILE"
  systemctl enable --now sing-box
  systemctl restart sing-box
}

port_is_used_in_config() {
  local port=$1
  jq -e --argjson port "$port" '.inbounds[]? | select(.listen_port == $port)' "$CONFIG_FILE" >/dev/null
}

ensure_port_available() {
  local port=$1
  if port_is_used_in_config "$port"; then
    die "端口 $port 已在 sing-box 配置中使用。"
  fi
  if ss -ltnu 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"; then
    die "端口 $port 已被其他进程监听，请换一个端口。"
  fi
}

open_firewall_port() {
  local port=$1 protocol=${2:-tcp}
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
    ufw allow "${port}/${protocol}" >/dev/null
    ok "已通过 UFW 放行 ${port}/${protocol}"
  else
    warn "未检测到启用中的 UFW；请同时在云厂商安全组放行 ${port}/${protocol}。"
  fi
}

random_ss_key() {
  sing-box generate rand --base64 16 2>/dev/null || openssl rand -base64 16 | tr -d '\n'
}

random_token() {
  openssl rand -hex 24
}

random_path() {
  printf '/%s' "$(openssl rand -hex 12)"
}

new_uuid() {
  sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
}

generate_reality_keypair() {
  local keypair private_key public_key
  keypair=$(sing-box generate reality-keypair)
  private_key=$(awk -F': ' '/PrivateKey/ {print $2}' <<<"$keypair")
  public_key=$(awk -F': ' '/PublicKey/ {print $2}' <<<"$keypair")
  [[ -n $private_key && -n $public_key ]] || die "无法生成 Reality 密钥对。"
  printf '%s|%s' "$private_key" "$public_key"
}

save_connection() {
  local type=$1 tag=$2 host=$3 port=$4 uri=$5
  local candidate
  candidate=$(mktemp)
  jq --arg type "$type" --arg tag "$tag" --arg host "$host" --argjson port "$port" --arg uri "$uri" \
    '.connections += [{type:$type, tag:$tag, host:$host, port:$port, uri:$uri, created_at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}]' \
    "$STATE_FILE" > "$candidate"
  install -m 600 "$candidate" "$STATE_FILE"
  rm -f "$candidate"
}

tls_json() {
  local domain=$1 cert=$2 key=$3
  jq -n --arg domain "$domain" --arg cert "$cert" --arg key "$key" \
    '{enabled:true,server_name:$domain,alpn:["h2","http/1.1"],min_version:"1.2",certificate_path:$cert,key_path:$key}'
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
  printf "\nTLS 证书方式：\n  1) 使用 Certbot / Let's Encrypt 自动签发（需域名已解析到本机，80/TCP 可访问）\n  2) 使用已有 PEM 证书\n"
  read -r -p '选择 [1]: ' choice
  choice=${choice:-1}
  case $choice in
    1)
      apt-get update >&2
      apt-get install -y certbot >&2
      open_firewall_port 80 tcp >&2
      info "正在申请 ${domain} 的证书" >&2
      certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$domain" >&2
      install_certbot_hook
      [[ -r $cert && -r $key ]] || die "证书文件没有生成。"
      ;;
    2)
      cert=$(ask_required "证书链 PEM 的绝对路径")
      key=$(ask_required "私钥 PEM 的绝对路径")
      [[ -r $cert && -r $key ]] || die "证书或私钥不可读。"
      ;;
    *) die "无效选择。" ;;
  esac
  printf '%s|%s' "$cert" "$key"
}

deploy_shadowsocks() {
  ensure_installed
  create_base_config
  local port host key tag inbound encoded uri candidate
  port=$(ask_port "Shadowsocks 2022 监听端口" 8443)
  ensure_port_available "$port"
  host=$(ask_server_address)
  key=$(random_ss_key)
  tag="ss2022-${port}"
  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg key "$key" \
    '{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,method:"2022-blake3-aes-128-gcm",password:$key,multiplex:{enabled:true}}')
  candidate=$(mktemp)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"
  encoded=$(printf '%s' "2022-blake3-aes-128-gcm:${key}" | base64 -w 0)
  uri="ss://${encoded}@${host}:${port}#sing-box-SS2022-${port}"
  save_connection "shadowsocks-2022" "$tag" "$host" "$port" "$uri"
  open_firewall_port "$port" tcp
  open_firewall_port "$port" udp
  ok "Shadowsocks 2022 已部署"
  printf '\n客户端连接串：\n%s\n\n' "$uri"
}

deploy_trojan() {
  ensure_installed
  create_base_config
  local domain port paths cert key password tag tls inbound candidate uri
  domain=$(ask_required "TLS 域名")
  valid_hostname "$domain" || die "域名格式不正确。"
  port=$(ask_port "Trojan 监听端口" 443)
  ensure_port_available "$port"
  paths=$(obtain_tls_paths "$domain")
  cert=${paths%%|*}
  key=${paths#*|}
  password=$(random_token)
  tag="trojan-${port}"
  tls=$(tls_json "$domain" "$cert" "$key")
  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg password "$password" --argjson tls "$tls" \
    '{type:"trojan",tag:$tag,listen:"::",listen_port:$port,users:[{name:"default",password:$password}],tls:$tls}')
  candidate=$(mktemp)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"
  uri="trojan://${password}@${domain}:${port}?security=tls&sni=${domain}&type=tcp#sing-box-Trojan-${port}"
  save_connection "trojan-tls" "$tag" "$domain" "$port" "$uri"
  open_firewall_port "$port" tcp
  ok "Trojan TLS 已部署"
  printf '\n客户端连接串：\n%s\n\n' "$uri"
}

deploy_vless() {
  ensure_installed
  create_base_config
  local domain port paths cert key uuid tag tls inbound candidate uri
  domain=$(ask_required "TLS 域名")
  valid_hostname "$domain" || die "域名格式不正确。"
  port=$(ask_port "VLESS 监听端口" 8443)
  ensure_port_available "$port"
  paths=$(obtain_tls_paths "$domain")
  cert=${paths%%|*}
  key=${paths#*|}
  uuid=$(new_uuid)
  tag="vless-${port}"
  tls=$(tls_json "$domain" "$cert" "$key")
  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --argjson tls "$tls" \
    '{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{name:"default",uuid:$uuid}],tls:$tls}')
  candidate=$(mktemp)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"
  uri="vless://${uuid}@${domain}:${port}?encryption=none&security=tls&type=tcp&sni=${domain}#sing-box-VLESS-${port}"
  save_connection "vless-tls" "$tag" "$domain" "$port" "$uri"
  open_firewall_port "$port" tcp
  ok "VLESS TLS 已部署"
  printf '\n客户端连接串：\n%s\n\n' "$uri"
}

deploy_hysteria2() {
  ensure_installed
  create_base_config
  local domain port paths cert key password obfs_password tag tls inbound candidate uri
  domain=$(ask_required "Hysteria2 TLS 域名")
  valid_hostname "$domain" || die "域名格式不正确。"
  port=$(ask_port "Hysteria2 UDP 监听端口" 8443)
  ensure_port_available "$port"
  paths=$(obtain_tls_paths "$domain")
  cert=${paths%%|*}
  key=${paths#*|}
  password=$(random_token)
  obfs_password=$(random_token)
  tag="hy2-${port}"
  tls=$(tls_json "$domain" "$cert" "$key")
  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg password "$password" --arg obfs "$obfs_password" --argjson tls "$tls" \
    '{type:"hysteria2",tag:$tag,listen:"::",listen_port:$port,network:"udp",users:[{name:"default",password:$password}],obfs:{type:"salamander",password:$obfs},tls:$tls}')
  candidate=$(mktemp)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"
  uri="hysteria2://${password}@${domain}:${port}?sni=${domain}&obfs=salamander&obfs-password=${obfs_password}#sing-box-Hysteria2-${port}"
  save_connection "hysteria2" "$tag" "$domain" "$port" "$uri"
  open_firewall_port "$port" udp
  ok "Hysteria2 已部署"
  printf '\n客户端连接串：\n%s\n\n' "$uri"
}

deploy_tuic() {
  ensure_installed
  create_base_config
  local domain port paths cert key uuid password tag tls inbound candidate uri
  domain=$(ask_required "TUIC TLS 域名")
  valid_hostname "$domain" || die "域名格式不正确。"
  port=$(ask_port "TUIC UDP 监听端口" 8443)
  ensure_port_available "$port"
  paths=$(obtain_tls_paths "$domain")
  cert=${paths%%|*}
  key=${paths#*|}
  uuid=$(new_uuid)
  password=$(random_token)
  tag="tuic-${port}"
  tls=$(tls_json "$domain" "$cert" "$key")
  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg password "$password" --argjson tls "$tls" \
    '{type:"tuic",tag:$tag,listen:"::",listen_port:$port,network:"udp",users:[{name:"default",uuid:$uuid,password:$password}],congestion_control:"bbr",zero_rtt_handshake:false,tls:$tls}')
  candidate=$(mktemp)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"
  uri="tuic://${uuid}:${password}@${domain}:${port}?congestion_control=bbr&sni=${domain}#sing-box-TUIC-${port}"
  save_connection "tuic" "$tag" "$domain" "$port" "$uri"
  open_firewall_port "$port" udp
  ok "TUIC 已部署"
  printf '\n客户端连接串：\n%s\n\n' "$uri"
}

deploy_vless_reality() {
  ensure_installed
  create_base_config
  local host port handshake keypair private_key public_key short_id uuid tag reality tls inbound candidate uri
  host=$(ask_server_address)
  port=$(ask_port "VLESS Reality TCP 监听端口" 443)
  ensure_port_available "$port"
  handshake=$(ask_required "Reality 握手域名（必须可从 VPS 访问，例如 www.cloudflare.com）")
  valid_hostname "$handshake" || die "握手域名格式不正确。"
  keypair=$(generate_reality_keypair)
  private_key=${keypair%%|*}
  public_key=${keypair#*|}
  short_id=$(openssl rand -hex 4)
  uuid=$(new_uuid)
  tag="vless-reality-${port}"
  reality=$(jq -n --arg handshake "$handshake" --arg private_key "$private_key" --arg short_id "$short_id" \
    '{enabled:true,handshake:{server:$handshake,server_port:443},private_key:$private_key,short_id:[$short_id]}')
  tls=$(jq -n --argjson reality "$reality" '{enabled:true,reality:$reality}')
  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --argjson tls "$tls" \
    '{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{name:"default",uuid:$uuid,flow:"xtls-rprx-vision"}],tls:$tls}')
  candidate=$(mktemp)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"
  uri="vless://${uuid}@${host}:${port}?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=${handshake}&fp=chrome&pbk=${public_key}&sid=${short_id}#sing-box-VLESS-Reality-${port}"
  save_connection "vless-reality" "$tag" "$host" "$port" "$uri"
  open_firewall_port "$port" tcp
  ok "VLESS Reality 已部署"
  printf '\n客户端连接串：\n%s\n\n' "$uri"
}

install_cloudflared() {
  require_apt
  info "配置 Cloudflare 官方 cloudflared APT 软件源"
  install -d -m 755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    -o /usr/share/keyrings/cloudflare-main.gpg
  tee /etc/apt/sources.list.d/cloudflared.list >/dev/null <<'EOF'
deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main
EOF
  apt-get update
  apt-get install -y cloudflared
}

deploy_cloudflare_tunnel() {
  ensure_installed
  create_base_config
  local domain port path path_encoded uuid tag inbound candidate uri tunnel_token

  if command -v cloudflared >/dev/null 2>&1 || systemctl list-unit-files --no-legend 2>/dev/null | grep -q '^cloudflared\.service'; then
    die "检测到已有 cloudflared 安装或服务。为避免覆盖现有 Tunnel，本脚本不会修改它。"
  fi

  domain=$(ask_required "Cloudflare 已托管的公网域名（例如 cf.example.com）")
  valid_hostname "$domain" || die "域名格式不正确。"
  port=$(ask_port "本地 VLESS WebSocket 端口（仅监听 127.0.0.1）" 10000)
  ensure_port_available "$port"
  path=$(random_path)
  uuid=$(new_uuid)
  tag="vless-ws-cf-${port}"

  printf '\n请先在 Cloudflare Zero Trust 后台创建远程管理 Tunnel，并添加 Published application：\n'
  printf '  Hostname: %s\n' "$domain"
  printf '  Service URL: http://127.0.0.1:%s\n' "$port"
  printf '完成后，在 Tunnel 的 Add a replica 页面复制 Token。\n\n'
  confirm "已创建上述 Tunnel 路由，继续安装连接器" N || return

  read -r -s -p "Cloudflare Tunnel Token（输入不回显）: " tunnel_token
  printf '\n'
  [[ -n $tunnel_token ]] || die "Tunnel Token 不能为空。"

  install_cloudflared
  info "安装 Cloudflare Tunnel 系统服务"
  cloudflared service install "$tunnel_token"
  systemctl enable --now cloudflared
  systemctl is-active --quiet cloudflared || die "cloudflared 服务未能启动，请检查 journalctl -u cloudflared。"

  inbound=$(jq -n --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" --arg path "$path" \
    '{type:"vless",tag:$tag,listen:"127.0.0.1",listen_port:$port,users:[{name:"default",uuid:$uuid}],transport:{type:"ws",path:$path}}')
  candidate=$(mktemp)
  jq --argjson inbound "$inbound" '.inbounds += [$inbound]' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"

  path_encoded=$(jq -nr --arg path "$path" '$path | @uri')
  uri="vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=${path_encoded}&sni=${domain}#sing-box-CF-Tunnel"
  save_connection "vless-ws-cloudflare-tunnel" "$tag" "$domain" 443 "$uri"
  ok "Cloudflare Tunnel 与本地 VLESS WebSocket 入站已部署"
  printf '\n客户端连接串：\n%s\n\n' "$uri"
}

show_cloudflared_status() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    warn "cloudflared 尚未安装。"
    return
  fi
  cloudflared --version
  systemctl --no-pager --full status cloudflared || true
}

show_connections() {
  ensure_dirs
  if [[ $(jq '.connections | length' "$STATE_FILE") -eq 0 ]]; then
    warn "尚未由本脚本创建连接。"
    return
  fi
  printf '\n已保存的客户端连接串（请妥善保管）：\n\n'
  jq -r '.connections[] | "[\(.type)] \(.tag)  \(.host):\(.port)\n\(.uri)\n"' "$STATE_FILE"
}

list_inbounds() {
  create_base_config
  jq -r '.inbounds | to_entries[] | "\(.key + 1). \(.value.tag) [\(.value.type)] :\(.value.listen_port)"' "$CONFIG_FILE"
}

remove_inbound() {
  ensure_installed
  create_base_config
  local tag candidate
  if [[ $(jq '.inbounds | length' "$CONFIG_FILE") -eq 0 ]]; then
    warn "当前没有入站。"
    return
  fi
  printf '\n当前入站：\n'
  list_inbounds
  tag=$(ask_required "输入要删除的 tag")
  jq -e --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null || die "未找到该 tag。"
  confirm "确认删除 ${tag}" N || return
  candidate=$(mktemp)
  jq --arg tag "$tag" '.inbounds |= map(select(.tag != $tag))' "$CONFIG_FILE" > "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"
  candidate=$(mktemp)
  jq --arg tag "$tag" '.connections |= map(select(.tag != $tag))' "$STATE_FILE" > "$candidate"
  install -m 600 "$candidate" "$STATE_FILE"
  rm -f "$candidate"
  ok "已删除 ${tag}"
}

validate_and_restart() {
  ensure_installed
  sing-box check -c "$CONFIG_FILE"
  systemctl enable --now sing-box
  systemctl restart sing-box
  ok "配置校验通过，服务已重启。"
}

show_status() {
  ensure_installed
  local public_ipv4 public_ipv6
  public_ipv4=$(detect_public_ip)
  public_ipv6=$(detect_public_ipv6)
  printf '\nsing-box: '
  sing-box version | head -n 1
  printf '公网 IPv4: %s\n' "${public_ipv4:-未检测到}"
  printf '公网 IPv6: %s\n' "${public_ipv6:-未检测到}"
  printf '\n服务状态：\n'
  systemctl --no-pager --full status sing-box || true
  printf '\n已配置的入站：\n'
  if [[ -f $CONFIG_FILE ]]; then
    jq -r '.inbounds[]? | "- \(.tag) [\(.type)] 监听 \(.listen):\(.listen_port)"' "$CONFIG_FILE"
  fi
}

show_logs() {
  journalctl -u sing-box -n 120 --no-pager -o cat
}

health_check() {
  ensure_installed
  local failed=0
  printf '\nsing-box 配置： '
  if sing-box check -c "$CONFIG_FILE" >/dev/null; then
    printf '通过\n'
  else
    printf '失败\n'
    failed=1
  fi
  printf 'sing-box 服务： '
  if systemctl is-active --quiet sing-box; then
    printf '运行中\n'
  else
    printf '未运行\n'
    failed=1
  fi
  if command -v cloudflared >/dev/null 2>&1; then
    printf 'cloudflared 服务： '
    if systemctl is-active --quiet cloudflared; then
      printf '运行中\n'
    else
      printf '未运行\n'
      failed=1
    fi
  fi
  printf '\n已配置监听端口：\n'
  jq -r '.inbounds[]? | "- \(.tag) [\(.type)] \(.listen):\(.listen_port)"' "$CONFIG_FILE"
  (( failed == 0 )) && ok "健康检查通过" || warn "健康检查发现异常，请查看 sb logs 或 systemctl status sing-box。"
}

show_certificate_expiry() {
  ensure_installed
  local cert_path end_date
  local -a certs=()
  mapfile -t certs < <(jq -r '.inbounds[]? | .tls.certificate_path? // empty' "$CONFIG_FILE" | sort -u)
  if (( ${#certs[@]} == 0 )); then
    warn "当前没有使用文件证书的 TLS 入站。"
    return
  fi
  printf '\n证书到期信息：\n'
  for cert_path in "${certs[@]}"; do
    if [[ -r $cert_path ]]; then
      end_date=$(openssl x509 -enddate -noout -in "$cert_path" | cut -d= -f2-)
      printf -- '- %s\n  %s\n' "$cert_path" "$end_date"
    else
      warn "不可读取：$cert_path"
    fi
  done
}

update_manager() {
  local candidate
  candidate=$(mktemp)
  info "从你的 GitHub 仓库下载管理脚本更新"
  curl -fL --proto '=https' --tlsv1.2 "$SCRIPT_UPDATE_URL" -o "$candidate"
  bash -n "$candidate"
  install -D -m 700 "$candidate" "$MANAGER_PATH"
  rm -f "$candidate"
  tee "$SHORTCUT_PATH" >/dev/null <<EOF
#!/usr/bin/env bash
exec ${MANAGER_PATH} "\$@"
EOF
  chmod 755 "$SHORTCUT_PATH"
  ok "管理脚本已更新。重新输入 sb 即可使用新版本。"
}

upgrade_sing_box() {
  ensure_installed
  info "更新 sing-box 官方软件包"
  apt-get update
  apt-get install -y --only-upgrade sing-box
  validate_and_restart
  ok "更新完成：$(sing-box version | head -n 1)"
}

enable_bbr() {
  require_root
  local sysctl_file="/etc/sysctl.d/99-sing-box-bbr.conf"
  tee "$sysctl_file" >/dev/null <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null
  ok "已写入 BBR 设置；当前算法：$(sysctl -n net.ipv4.tcp_congestion_control)"
}

restore_backup() {
  ensure_installed
  local file candidate
  file=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'config-*.json' -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d' ' -f2-)
  [[ -n $file ]] || die "没有可用备份。"
  warn "将恢复最近备份：$file"
  confirm "确认恢复" N || return
  candidate=$(mktemp)
  install -m 600 "$file" "$candidate"
  apply_candidate "$candidate"
  rm -f "$candidate"
  ok "已恢复最近备份。"
}

uninstall_sing_box() {
  require_root
  warn "这会停止并卸载 sing-box 软件包；配置和连接记录会保留在本机，便于恢复。"
  confirm "确认卸载" N || return
  systemctl disable --now sing-box 2>/dev/null || true
  apt-get remove -y sing-box
  ok "sing-box 已卸载；保留目录：${CONFIG_DIR}、${STATE_DIR}"
}

print_menu() {
  printf '\n%s\n' '========================================'
  printf ' sing-box VPS 一键部署 v%s\n' "$SCRIPT_VERSION"
  printf '%s\n' '========================================'
  printf '1) 安装 / 修复官方 sing-box\n'
  printf '2) 新建 Shadowsocks 2022 入站\n'
  printf '3) 新建 Trojan + TLS 入站\n'
  printf '4) 新建 VLESS + TLS 入站\n'
  printf '5) 新建 Hysteria2 + TLS 入站\n'
  printf '6) 新建 TUIC + TLS 入站\n'
  printf '7) 新建 VLESS Reality 入站\n'
  printf '8) 查看客户端连接串\n'
  printf '9) 删除入站\n'
  printf '10) 校验配置并重启\n'
  printf '11) 查看服务状态与公网 IP\n'
  printf '12) 查看最近日志\n'
  printf '13) 更新 sing-box\n'
  printf '14) 启用 BBR\n'
  printf '15) 恢复最近配置备份\n'
  printf '16) 卸载 sing-box（保留配置）\n'
  printf '17) 配置 Cloudflare Tunnel + VLESS WebSocket\n'
  printf '18) 查看 Cloudflare Tunnel 状态\n'
  printf '19) 健康检查\n'
  printf '20) 查看 TLS 证书到期时间\n'
  printf '21) 安装 / 修复 sb 快捷命令\n'
  printf '22) 从 GitHub 更新管理脚本\n'
  printf '0) 退出\n\n'
}

menu() {
  local choice
  while true; do
    print_menu
    read -r -p '请选择: ' choice
    case $choice in
      1) install_sing_box ;;
      2) deploy_shadowsocks ;;
      3) deploy_trojan ;;
      4) deploy_vless ;;
      5) deploy_hysteria2 ;;
      6) deploy_tuic ;;
      7) deploy_vless_reality ;;
      8) show_connections ;;
      9) remove_inbound ;;
      10) validate_and_restart ;;
      11) show_status ;;
      12) show_logs ;;
      13) upgrade_sing_box ;;
      14) enable_bbr ;;
      15) restore_backup ;;
      16) uninstall_sing_box ;;
      17) deploy_cloudflare_tunnel ;;
      18) show_cloudflared_status ;;
      19) health_check ;;
      20) show_certificate_expiry ;;
      21) install_manager ;;
      22) update_manager ;;
      0) exit 0 ;;
      *) warn "无效选择。" ;;
    esac
  done
}

usage() {
  printf '用法：sb [menu|install|ss|trojan|vless|hy2|tuic|reality|cftunnel|cfstatus|status|links|check|logs|health|certs|self-update|upgrade|bbr|rollback|remove|uninstall]\n'
}

main() {
  case ${1:-menu} in
    -h|--help|help) usage; return ;;
  esac
  require_root
  case ${1:-menu} in
    menu) menu ;;
    install) install_sing_box ;;
    ss) deploy_shadowsocks ;;
    trojan) deploy_trojan ;;
    vless) deploy_vless ;;
    hy2) deploy_hysteria2 ;;
    tuic) deploy_tuic ;;
    reality) deploy_vless_reality ;;
    cftunnel) deploy_cloudflare_tunnel ;;
    cfstatus) show_cloudflared_status ;;
    status) show_status ;;
    links) show_connections ;;
    check) validate_and_restart ;;
    logs) show_logs ;;
    health) health_check ;;
    certs) show_certificate_expiry ;;
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
