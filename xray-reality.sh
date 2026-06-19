#!/usr/bin/env bash
# xray-reality.sh — Multi-protocol Xray one-click installer
# Protocols: VLESS+Reality, SS/VLESS/VMess/Trojan + WS/gRPC + TLS
# License: MIT
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_NAME="xray-reality"
SCRIPT_VERSION="2.1.0"

XRAY_BIN="/usr/local/bin/xray"
SELF_CMD="/usr/local/bin/xr"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
XRAY_SHARE_FILE="${XRAY_CONFIG_DIR}/.share.txt"
XRAY_META_FILE="${XRAY_CONFIG_DIR}/.meta.env"
SSL_DIR="${XRAY_CONFIG_DIR}/ssl"
ACME_SH="$HOME/.acme.sh/acme.sh"

OFFICIAL_INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

DEFAULT_DESTS=(
  "www.microsoft.com" "addons.mozilla.org" "www.lovelive-anime.jp"
  "swdist.apple.com"  "www.tesla.com"      "gateway.icloud.com"
  "www.cloudflare.com"
)

# Global node state — populated by _reload_meta or during install
PROTO="" PORT="" UUID="" PASSWORD="" PRIVKEY="" PUBKEY="" SHORTID=""
DEST="" SNI="" DOMAIN="" WS_PATH="" GRPC_SVC="" SS_METHOD="" ADDR="" NAME=""

# ─────────────────────────── UI helpers ───────────────────────────
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1 && [[ $(tput colors 2>/dev/null || echo 0) -ge 8 ]]; then
  R=$'\033[1;31m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; B=$'\033[1;36m'; D=$'\033[2m'; N=$'\033[0m'
else
  R=; G=; Y=; B=; D=; N=
fi
msg()  { printf '%s\n' "${B}[*]${N} $*"; }
ok()   { printf '%s\n' "${G}[+]${N} $*"; }
warn() { printf '%s\n' "${Y}[!]${N} $*" >&2; }
err()  { printf '%s\n' "${R}[x]${N} $*" >&2; }
die()  { err "$*"; exit 1; }
trap 'err "脚本第 $LINENO 行异常，已中止。"' ERR

# ─────────────────────────── Preflight ───────────────────────────
require_root() { [[ $EUID -eq 0 ]] || die "请使用 root 权限执行（sudo bash $0 $*）"; }

detect_pm() {
  if   command -v apt-get >/dev/null; then PM=apt
  elif command -v dnf     >/dev/null; then PM=dnf
  elif command -v yum     >/dev/null; then PM=yum
  elif command -v zypper  >/dev/null; then PM=zypper
  elif command -v pacman  >/dev/null; then PM=pacman
  elif command -v apk     >/dev/null; then PM=apk
  else die "未检测到受支持的包管理器（apt/dnf/yum/zypper/pacman/apk）"
  fi
}

pkg_install() {
  local pkgs=("$@")
  ((${#pkgs[@]})) || return 0
  case "$PM" in
    apt)    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${pkgs[@]}" >/dev/null ;;
    dnf)    dnf install -y -q "${pkgs[@]}" >/dev/null ;;
    yum)    yum install -y -q "${pkgs[@]}" >/dev/null ;;
    zypper) zypper --non-interactive install -y "${pkgs[@]}" >/dev/null ;;
    pacman) pacman -Sy --noconfirm --needed "${pkgs[@]}" >/dev/null ;;
    apk)    apk add --no-cache "${pkgs[@]}" >/dev/null ;;
  esac
}

pkg_available() {
  local pkg=$1
  case "$PM" in
    apt)    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
            apt-cache show "$pkg" >/dev/null 2>&1 ;;
    dnf)    dnf -q repoquery "$pkg" >/dev/null 2>&1 ;;
    yum)    yum -q list available "$pkg" >/dev/null 2>&1 ;;
    zypper) zypper --non-interactive search -x "$pkg" >/dev/null 2>&1 ;;
    pacman) pacman -Sy >/dev/null 2>&1 && pacman -Si "$pkg" >/dev/null 2>&1 ;;
    apk)    apk search -e "$pkg" >/dev/null 2>&1 ;;
  esac
}

install_deps() {
  detect_pm
  local pkgs=()
  command -v curl     >/dev/null || pkgs+=("curl")
  command -v openssl  >/dev/null || pkgs+=("openssl")
  command -v ss       >/dev/null || case "$PM" in apt|zypper|pacman|apk) pkgs+=("iproute2");; *) pkgs+=("iproute");; esac
  command -v tar      >/dev/null || pkgs+=("tar")
  if ((${#pkgs[@]})); then
    msg "安装依赖：${pkgs[*]}"
    pkg_install "${pkgs[@]}" || die "必需依赖安装失败：${pkgs[*]}"
  fi
  if ! command -v qrencode >/dev/null; then
    if pkg_available qrencode; then
      msg "安装可选依赖：qrencode"
      pkg_install qrencode || warn "qrencode 安装失败，仅影响二维码显示，不影响主流程"
    else
      warn "当前软件源未提供 qrencode，跳过二维码工具安装"
    fi
  fi
}

# ─────────────────────────── Xray core ───────────────────────────
install_xray() {
  local tmp installer_sha
  tmp=$(mktemp); chmod 600 "$tmp"
  msg "下载官方安装脚本（HTTPS + TLS1.2+）"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --max-time 30 \
       "$OFFICIAL_INSTALLER_URL" -o "$tmp" \
    || { rm -f "$tmp"; die "无法下载官方安装脚本"; }
  installer_sha=$(sha256sum "$tmp" | awk '{print $1}')
  printf '%s    %s\n' "$installer_sha" "$OFFICIAL_INSTALLER_URL" >&2
  if [[ -n "${XRAY_INSTALLER_SHA256:-}" ]]; then
    [[ "$installer_sha" == "$XRAY_INSTALLER_SHA256" ]] \
      || { rm -f "$tmp"; die "SHA256 校验不符，疑似中间人或上游变更"; }
    ok "官方安装脚本 SHA256 校验通过"
  else
    warn "未提供 XRAY_INSTALLER_SHA256（建议钉住以加固安全）"
  fi
  bash "$tmp" install ${XRAY_VERSION:+--version "$XRAY_VERSION"}
  rm -f "$tmp"
  [[ -x "$XRAY_BIN" ]] || die "Xray 安装后未找到 $XRAY_BIN"
  local version_out version_line
  version_out=$("$XRAY_BIN" version 2>/dev/null || true)
  version_line=${version_out%%$'\n'*}
  ok "Xray 已安装：${version_line:-$XRAY_BIN}"
}

uninstall_xray() {
  local tmp; tmp=$(mktemp); chmod 600 "$tmp"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --max-time 30 \
       "$OFFICIAL_INSTALLER_URL" -o "$tmp" || die "无法下载官方卸载脚本"
  bash "$tmp" remove --purge || true
  rm -f "$tmp" "$XRAY_SHARE_FILE" "$XRAY_META_FILE"
}

# ─────────────────────────── Network / Crypto ───────────────────────────
get_public_ip() {
  local ip
  for s in api.ipify.org ipv4.icanhazip.com ifconfig.me; do
    ip=$(curl -fsS --proto '=https' --tlsv1.2 --max-time 4 "https://${s}" 2>/dev/null | tr -d '[:space:]') || continue
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return; }
  done
  for s in api64.ipify.org ifconfig.co; do
    ip=$(curl -fsS --proto '=https' --tlsv1.2 --max-time 4 "https://${s}" 2>/dev/null | tr -d '[:space:]') || continue
    [[ -n "$ip" ]] && { echo "$ip"; return; }
  done
  echo ""
}

pick_dest() {
  if [[ -n "${REALITY_DEST:-}" ]]; then echo "$REALITY_DEST"; return; fi
  msg "TLS 握手测速…" >&2
  local best="" best_ms=999999 d t ms
  for d in "${DEFAULT_DESTS[@]}"; do
    t=$(curl -o /dev/null -s -w '%{time_appconnect}' --max-time 3 --connect-timeout 2 \
        --proto '=https' --tlsv1.2 "https://${d}/" 2>/dev/null || echo 0)
    ms=$(awk -v x="$t" 'BEGIN{printf "%d", x*1000}')
    (( ms > 0 && ms < best_ms )) && { best_ms=$ms; best=$d; }
    printf "  %-28s %5d ms\n" "$d" "$ms" >&2
  done
  [[ -z "$best" ]] && { best="www.microsoft.com"; best_ms=0; }
  ok "伪装目标：${best} (${best_ms} ms)" >&2
  echo "$best"
}

pick_port() {
  if [[ -n "${REALITY_PORT:-}" ]]; then echo "$REALITY_PORT"; return; fi
  local p
  for _ in $(seq 1 60); do
    p=$(( RANDOM % 20001 + 30000 ))
    ss -tlnH "sport = :$p" 2>/dev/null | grep -q . || { echo "$p"; return; }
  done
  echo 8443
}

gen_keys()    { "$XRAY_BIN" x25519 | awk '/[Pp]rivate.?[Kk]ey/{priv=$NF}/Public.?key|Password/{pub=$NF}END{printf "%s|%s",priv,pub}'; }
gen_shortid() { openssl rand -hex 8; }
gen_uuid()    { "$XRAY_BIN" uuid; }
gen_password() { openssl rand -hex 16; }
gen_path()    { openssl rand -hex 8; }

get_acme_email() {
  local acme_email="${ACME_EMAIL:-}"
  [[ -n "$acme_email" ]] || die "TLS 证书申请需要设置 ACME_EMAIL"
  [[ "$acme_email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] \
    || die "ACME_EMAIL 格式无效，请提供真实可用邮箱"
  printf '%s' "$acme_email"
}

# ─────────────────────────── TLS cert (acme.sh) ───────────────────────────
install_acme() {
  [[ -x "$ACME_SH" ]] && return
  local acme_email; acme_email=$(get_acme_email)
  msg "安装 acme.sh..."
  curl -fsSL https://get.acme.sh | sh -s email="$acme_email" >/dev/null 2>&1 \
    || die "acme.sh 安装失败"
  # Reload path
  ACME_SH="$HOME/.acme.sh/acme.sh"
  [[ -x "$ACME_SH" ]] || die "acme.sh 安装后未找到"
}

ensure_acme_account() {
  local server=$1
  local acme_email; acme_email=$(get_acme_email)
  msg "同步 ACME 账户邮箱：$acme_email"
  "$ACME_SH" --server "$server" --register-account -m "$acme_email" 2>&1 \
    || "$ACME_SH" --server "$server" --update-account -m "$acme_email" 2>&1 \
    || die "ACME 账户初始化失败，请检查 ACME_EMAIL 是否为真实可用邮箱"
}

port_users() {
  local port=$1
  ss -tlnpH "sport = :$port" 2>/dev/null || true
}

ensure_port_free() {
  local port=$1 users
  users=$(port_users "$port")
  [[ -z "$users" ]] && return 0
  printf '%s\n%s\n' "${port} 端口已被占用：" "$users" >&2
  die "Xray 需要监听 ${port}/tcp。请先停止占用该端口的服务，或用 REALITY_PORT 指定其他 Cloudflare 支持的 HTTPS 端口。"
}

stop_acme_services() {
  local stopped=() services=() svc
  [[ -n "${ACME_STOP_SERVICES:-}" ]] || return 0
  read -r -a services <<<"${ACME_STOP_SERVICES//,/ }"
  for svc in "${services[@]}"; do
    [[ -n "$svc" ]] || continue
    if systemctl is-active --quiet "$svc"; then
      msg "临时停止服务以申请证书：$svc"
      systemctl stop "$svc"
      stopped+=("$svc")
    fi
  done
  ACME_STOPPED_SERVICES="${stopped[*]:-}"
}

restart_acme_services() {
  local svc
  [[ -n "${ACME_STOPPED_SERVICES:-}" ]] || return 0
  for svc in $ACME_STOPPED_SERVICES; do
    msg "恢复服务：$svc"
    systemctl start "$svc" || warn "服务恢复失败：$svc"
  done
  ACME_STOPPED_SERVICES=""
}

get_cert() {
  local domain=$1
  install_acme
  mkdir -p "$SSL_DIR"
  if [[ "${ACME_DNS:-}" == "cloudflare" ]]; then
    [[ -n "${CF_Token:-}" ]] || die "Cloudflare DNS 验证需要设置 CF_Token"
    [[ -n "${CF_Zone_ID:-}" ]] || warn "未设置 CF_Zone_ID，acme.sh 将自动解析 Zone"
    [[ -n "${CF_Account_ID:-}" ]] || warn "未设置 CF_Account_ID，通常可继续，但建议显式提供"
    msg "申请 TLS 证书：$domain（Cloudflare DNS 验证，不占用 80 端口）"
    ensure_acme_account letsencrypt
    if ! CF_Token="${CF_Token}" \
         CF_Zone_ID="${CF_Zone_ID:-}" \
         CF_Account_ID="${CF_Account_ID:-}" \
         "$ACME_SH" --issue --dns dns_cf -d "$domain" \
           --server letsencrypt --force 2>&1 \
      && ! ensure_acme_account zerossl \
      && ! CF_Token="${CF_Token}" \
         CF_Zone_ID="${CF_Zone_ID:-}" \
         CF_Account_ID="${CF_Account_ID:-}" \
         "$ACME_SH" --issue --dns dns_cf -d "$domain" \
           --server zerossl --force 2>&1; then
      die "Cloudflare DNS 验证申请证书失败。请确认：1) CF_Token 权限正确 2) 域名在该 Zone 下"
    fi
  else
    local users
    users=$(port_users 80)
    if [[ -n "$users" && -z "${ACME_STOP_SERVICES:-}" ]]; then
      printf '%s\n%s\n' "80 端口已被占用：" "$users" >&2
      die "证书申请需要临时占用 80 端口。可先停 nginx，或用 ACME_STOP_SERVICES=nginx 让脚本临时停启。"
    fi
    stop_acme_services
    msg "申请 TLS 证书：$domain（Let's Encrypt standalone 模式，需要 80 端口空闲）"
    ensure_acme_account letsencrypt
    if ! "$ACME_SH" --issue -d "$domain" --standalone --httpport 80 \
        --server letsencrypt --force 2>&1 \
      && ! ensure_acme_account zerossl \
      && ! "$ACME_SH" --issue -d "$domain" --standalone --httpport 80 \
         --server zerossl --force 2>&1; then
      restart_acme_services
      die "证书申请失败。请确认：1) 域名 DNS A 记录指向本机 2) 80 端口未被占用"
    fi
    restart_acme_services
  fi

  "$ACME_SH" --install-cert -d "$domain" \
    --key-file        "$SSL_DIR/privkey.pem" \
    --fullchain-file  "$SSL_DIR/fullchain.pem" \
    --reloadcmd       "systemctl restart xray" 2>&1 \
  || die "证书安装失败"

  chmod 755 "$SSL_DIR"
  chmod 644 "$SSL_DIR/fullchain.pem"
  chmod 600 "$SSL_DIR/privkey.pem"
  chown nobody "$SSL_DIR/privkey.pem" 2>/dev/null || true
  ok "证书申请完成：$domain"
}

# ─────────────────────────── Config writers (read globals) ───────────────────────────
_common_outbounds() {
  cat <<'JSON'
  "outbounds":[
    {"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"UseIP"}},
    {"tag":"block","protocol":"blackhole"}
  ],
  "routing":{"domainStrategy":"AsIs","rules":[
    {"type":"field","ip":["geoip:private"],"outboundTag":"block"},
    {"type":"field","protocol":["bittorrent"],"outboundTag":"block"}
  ]}
JSON
}

_finalize_config() {
  chmod 600 "$XRAY_CONFIG"
  chown nobody "$XRAY_CONFIG" 2>/dev/null || true
}

write_config_reality() {
  install -d -m 755 "$XRAY_CONFIG_DIR"
  cat > "$XRAY_CONFIG" <<JSON
{
  "log":{"loglevel":"warning"},
  "inbounds":[{
    "listen":"0.0.0.0","port":${PORT},"protocol":"vless",
    "settings":{"clients":[{"id":"${UUID}","flow":"xtls-rprx-vision"}],"decryption":"none"},
    "streamSettings":{
      "network":"tcp","security":"reality",
      "realitySettings":{
        "show":false,"dest":"${DEST}:443","xver":0,
        "serverNames":["${SNI}"],"privateKey":"${PRIVKEY}","shortIds":["${SHORTID}"]
      }
    },
    "sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}
  }],
$(_common_outbounds)
}
JSON
  _finalize_config
}

write_config_ws_tls() {
  local base="${PROTO%%-ws-tls}"
  local clients
  case "$base" in
    vless)  clients='"clients":[{"id":"'"$UUID"'"}],"decryption":"none"' ;;
    vmess)  clients='"clients":[{"id":"'"$UUID"'","alterId":0}]' ;;
    trojan) clients='"clients":[{"password":"'"$PASSWORD"'"}]' ;;
  esac
  install -d -m 755 "$XRAY_CONFIG_DIR"
  cat > "$XRAY_CONFIG" <<JSON
{
  "log":{"loglevel":"warning"},
  "inbounds":[{
    "listen":"0.0.0.0","port":${PORT},"protocol":"${base}",
    "settings":{${clients}},
    "streamSettings":{
      "network":"ws","security":"tls",
      "tlsSettings":{
        "certificates":[{"certificateFile":"${SSL_DIR}/fullchain.pem","keyFile":"${SSL_DIR}/privkey.pem"}],
        "minVersion":"1.2"
      },
      "wsSettings":{"path":"/${WS_PATH}","headers":{"Host":"${DOMAIN}"}}
    },
    "sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}
  }],
$(_common_outbounds)
}
JSON
  _finalize_config
}

write_config_grpc_tls() {
  local base="${PROTO%%-grpc-tls}"
  local clients
  case "$base" in
    vless)  clients='"clients":[{"id":"'"$UUID"'"}],"decryption":"none"' ;;
    vmess)  clients='"clients":[{"id":"'"$UUID"'","alterId":0}]' ;;
    trojan) clients='"clients":[{"password":"'"$PASSWORD"'"}]' ;;
  esac
  install -d -m 755 "$XRAY_CONFIG_DIR"
  cat > "$XRAY_CONFIG" <<JSON
{
  "log":{"loglevel":"warning"},
  "inbounds":[{
    "listen":"0.0.0.0","port":${PORT},"protocol":"${base}",
    "settings":{${clients}},
    "streamSettings":{
      "network":"grpc","security":"tls",
      "tlsSettings":{
        "certificates":[{"certificateFile":"${SSL_DIR}/fullchain.pem","keyFile":"${SSL_DIR}/privkey.pem"}],
        "minVersion":"1.2"
      },
      "grpcSettings":{"serviceName":"${GRPC_SVC}"}
    },
    "sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}
  }],
$(_common_outbounds)
}
JSON
  _finalize_config
}

write_config_ss_ws_tls() {
  install -d -m 755 "$XRAY_CONFIG_DIR"
  cat > "$XRAY_CONFIG" <<JSON
{
  "log":{"loglevel":"warning"},
  "inbounds":[{
    "listen":"0.0.0.0","port":${PORT},"protocol":"shadowsocks",
    "settings":{"method":"${SS_METHOD}","password":"${PASSWORD}","network":"tcp,udp"},
    "streamSettings":{
      "network":"ws","security":"tls",
      "tlsSettings":{
        "certificates":[{"certificateFile":"${SSL_DIR}/fullchain.pem","keyFile":"${SSL_DIR}/privkey.pem"}],
        "minVersion":"1.2"
      },
      "wsSettings":{"path":"/${WS_PATH}","headers":{"Host":"${DOMAIN}"}}
    }
  }],
$(_common_outbounds)
}
JSON
  _finalize_config
}

_write_current_config() {
  case "$PROTO" in
    vless-reality)  write_config_reality ;;
    ss-ws-tls)      write_config_ss_ws_tls ;;
    *-ws-tls)       write_config_ws_tls ;;
    *-grpc-tls)     write_config_grpc_tls ;;
    *) die "未知协议：$PROTO" ;;
  esac
}

# ─────────────────────────── Share link builders (read globals) ───────────────────────────
_name_enc() { printf '%s' "$NAME" | tr ' ' '_'; }

link_vless_reality() {
  local host="$ADDR"; [[ "$ADDR" == *:*:* ]] && host="[$ADDR]"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s\n' \
    "$UUID" "$host" "$PORT" "$SNI" "$PUBKEY" "$SHORTID" "$(_name_enc)"
}

link_vless_ws() {
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%%2F%s#%s\n' \
    "$UUID" "$DOMAIN" "$PORT" "$DOMAIN" "$DOMAIN" "$WS_PATH" "$(_name_enc)"
}

link_vless_grpc() {
  printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=grpc&serviceName=%s#%s\n' \
    "$UUID" "$DOMAIN" "$PORT" "$DOMAIN" "$GRPC_SVC" "$(_name_enc)"
}

_vmess_b64() {
  local net=$1 extra_key=$2 extra_val=$3
  local json
  if [[ "$net" == "ws" ]]; then
    json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"%s","path":"/%s","tls":"tls","sni":"%s","alpn":"","fp":""}' \
      "$(_name_enc)" "$DOMAIN" "$PORT" "$UUID" "$DOMAIN" "$WS_PATH" "$DOMAIN")
  else
    json=$(printf '{"v":"2","ps":"%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"grpc","type":"gun","host":"","path":"%s","tls":"tls","sni":"%s","alpn":"","fp":""}' \
      "$(_name_enc)" "$DOMAIN" "$PORT" "$UUID" "$GRPC_SVC" "$DOMAIN")
  fi
  printf 'vmess://%s\n' "$(printf '%s' "$json" | base64 -w 0)"
}

link_vmess_ws()    { _vmess_b64 ws; }
link_vmess_grpc()  { _vmess_b64 grpc; }

link_trojan_ws() {
  printf 'trojan://%s@%s:%s?security=tls&sni=%s&type=ws&host=%s&path=%%2F%s#%s\n' \
    "$PASSWORD" "$DOMAIN" "$PORT" "$DOMAIN" "$DOMAIN" "$WS_PATH" "$(_name_enc)"
}

link_trojan_grpc() {
  printf 'trojan://%s@%s:%s?security=tls&sni=%s&type=grpc&serviceName=%s#%s\n' \
    "$PASSWORD" "$DOMAIN" "$PORT" "$DOMAIN" "$GRPC_SVC" "$(_name_enc)"
}

link_ss_ws() {
  local userinfo; userinfo=$(printf '%s:%s' "$SS_METHOD" "$PASSWORD" | base64 -w 0)
  # SIP002 URI with v2ray-plugin parameters (semicolons URL-encoded as %3B)
  local plugin="v2ray-plugin%3Bmode%3Dwebsocket%3Btls%3Bhost%3D${DOMAIN}%3Bpath%3D%2F${WS_PATH}"
  printf 'ss://%s@%s:%s?plugin=%s#%s\n' "$userinfo" "$DOMAIN" "$PORT" "$plugin" "$(_name_enc)"
}

_build_link() {
  case "$PROTO" in
    vless-reality)   link_vless_reality ;;
    ss-ws-tls)       link_ss_ws ;;
    vless-ws-tls)    link_vless_ws ;;
    vless-grpc-tls)  link_vless_grpc ;;
    vmess-ws-tls)    link_vmess_ws ;;
    vmess-grpc-tls)  link_vmess_grpc ;;
    trojan-ws-tls)   link_trojan_ws ;;
    trojan-grpc-tls) link_trojan_grpc ;;
    *)               cat "$XRAY_SHARE_FILE" 2>/dev/null ;;
  esac
}

# ─────────────────────────── Meta ───────────────────────────
save_meta() {
  install -d -m 755 "$XRAY_CONFIG_DIR"
  cat > "$XRAY_META_FILE" <<EOF
PROTO=${PROTO}
PORT=${PORT}
UUID=${UUID}
PASSWORD=${PASSWORD}
PRIVKEY=${PRIVKEY}
PUBKEY=${PUBKEY}
SHORTID=${SHORTID}
DEST=${DEST}
SNI=${SNI}
DOMAIN=${DOMAIN}
WS_PATH=${WS_PATH}
GRPC_SVC=${GRPC_SVC}
SS_METHOD=${SS_METHOD}
ADDR=${ADDR}
NAME=${NAME}
EOF
  chmod 600 "$XRAY_META_FILE"
}

_reload_meta() {
  [[ -r "$XRAY_META_FILE" ]] || die "未找到节点配置，请先执行安装。"
  # shellcheck disable=SC1090
  . "$XRAY_META_FILE"
  [[ -z "${PROTO:-}" ]] && PROTO="vless-reality"
  # Backward compat: old Reality installs without PRIVKEY
  if [[ "$PROTO" == "vless-reality" && -z "${PRIVKEY:-}" ]]; then
    PRIVKEY=$(grep '"privateKey"' "$XRAY_CONFIG" 2>/dev/null \
              | sed 's/.*"privateKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    [[ -n "$PRIVKEY" ]] || die "无法读取私钥，配置文件可能损坏"
  fi
}

_apply_changes() {
  _write_current_config
  save_meta
  local link; link=$(_build_link)
  printf '%s\n' "$link" > "$XRAY_SHARE_FILE"; chmod 600 "$XRAY_SHARE_FILE"
  systemctl restart xray; sleep 1
  systemctl is-active --quiet xray \
    && ok "Xray 已重启" \
    || warn "Xray 重启后未运行，执行 'xr logs' 查看"
}

# ─────────────────────────── Firewall ───────────────────────────
open_firewall() {
  local port=$1
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi active; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 && ok "ufw 已放行 ${port}/tcp"
  fi
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null \
      && firewall-cmd --reload >/dev/null && ok "firewalld 已放行 ${port}/tcp"
  fi
}

# ─────────────────────────── Print result ───────────────────────────
print_result() {
  local link="${1:-}"
  [[ -z "$link" && -r "$XRAY_SHARE_FILE" ]] && link=$(cat "$XRAY_SHARE_FILE")
  [[ -r "$XRAY_META_FILE" ]] && . "$XRAY_META_FILE" 2>/dev/null || true

  echo
  printf '%s══════════════════════════════════════════════════════════════════%s\n' "$G" "$N"
  printf '%s Xray 节点信息  %s%s\n' "$G" "${PROTO:-}" "$N"
  printf '%s══════════════════════════════════════════════════════════════════%s\n' "$G" "$N"

  case "${PROTO:-vless-reality}" in
    vless-reality)
      printf "  %-10s %s\n" "地址"   "${ADDR}"
      printf "  %-10s %s\n" "端口"   "${PORT}"
      printf "  %-10s %s\n" "UUID"   "${UUID}"
      printf "  %-10s %s\n" "公钥"   "${PUBKEY}"
      printf "  %-10s %s\n" "短 ID"  "${SHORTID}"
      printf "  %-10s %s\n" "SNI"    "${SNI}"
      printf "  %-10s %s\n" "Flow"   "xtls-rprx-vision"
      printf "  %-10s %s\n" "指纹"   "chrome"
      ;;
    vless-ws-tls|vless-grpc-tls)
      printf "  %-10s %s\n" "域名"   "${DOMAIN}"
      printf "  %-10s %s\n" "端口"   "${PORT}"
      printf "  %-10s %s\n" "UUID"   "${UUID}"
      [[ "$PROTO" == *ws* ]]   && printf "  %-10s /%s\n" "路径"     "${WS_PATH}"
      [[ "$PROTO" == *grpc* ]] && printf "  %-10s %s\n"  "gRPC服务" "${GRPC_SVC}"
      printf "  %-10s %s\n" "TLS"    "TLS 1.2+"
      ;;
    vmess-ws-tls|vmess-grpc-tls)
      printf "  %-10s %s\n" "域名"   "${DOMAIN}"
      printf "  %-10s %s\n" "端口"   "${PORT}"
      printf "  %-10s %s\n" "UUID"   "${UUID}"
      printf "  %-10s %s\n" "alterID" "0"
      [[ "$PROTO" == *ws* ]]   && printf "  %-10s /%s\n" "路径"     "${WS_PATH}"
      [[ "$PROTO" == *grpc* ]] && printf "  %-10s %s\n"  "gRPC服务" "${GRPC_SVC}"
      printf "  %-10s %s\n" "TLS"    "TLS 1.2+"
      ;;
    trojan-ws-tls|trojan-grpc-tls)
      printf "  %-10s %s\n" "域名"   "${DOMAIN}"
      printf "  %-10s %s\n" "端口"   "${PORT}"
      printf "  %-10s %s\n" "密码"   "${PASSWORD}"
      [[ "$PROTO" == *ws* ]]   && printf "  %-10s /%s\n" "路径"     "${WS_PATH}"
      [[ "$PROTO" == *grpc* ]] && printf "  %-10s %s\n"  "gRPC服务" "${GRPC_SVC}"
      printf "  %-10s %s\n" "TLS"    "TLS 1.2+"
      ;;
    ss-ws-tls)
      printf "  %-10s %s\n" "域名"   "${DOMAIN}"
      printf "  %-10s %s\n" "端口"   "${PORT}"
      printf "  %-10s %s\n" "密码"   "${PASSWORD}"
      printf "  %-10s %s\n" "加密"   "${SS_METHOD}"
      printf "  %-10s /%s\n" "路径"  "${WS_PATH}"
      printf "  %-10s %s\n" "TLS"    "TLS 1.2+"
      printf "  %-10s %s\n" "插件"   "v2ray-plugin (WebSocket+TLS)"
      ;;
  esac

  echo
  printf '%s── 分享链接 ────────────────────────────────────────────────────%s\n' "$B" "$N"
  printf '%s\n' "$link"
  echo
  printf '%s── 二维码 ──────────────────────────────────────────────────────%s\n' "$B" "$N"
  if command -v qrencode >/dev/null; then
    qrencode -t ANSIUTF8 -m 2 "$link"
  else
    printf '%s  （安装 qrencode 后重新运行可显示二维码）%s\n' "$D" "$N"
  fi
  printf '%s分享链接已保存至：%s%s\n' "$D" "$XRAY_SHARE_FILE" "$N"
}

# ─────────────────────────── Protocol selection ───────────────────────────
select_protocol() {
  echo >&2
  printf '%s请选择协议：%s\n' "$B" "$N" >&2
  printf '\n%s  ─── 无需域名 ──────────────────────────────────%s\n' "$D" "$N" >&2
  printf '  1. VLESS + TCP + Reality    %s← 推荐，最优秀的防封锁%s\n' "$G" "$N" >&2
  printf '\n%s  ─── 需要域名 + 自动申请 TLS 证书 ──────────%s\n' "$D" "$N" >&2
  printf '  2. Shadowsocks + WS + TLS   (SS 隐藏于 HTTPS，防主动探测)\n' >&2
  printf '  3. VLESS + WS  + TLS        (CDN 友好)\n' >&2
  printf '  4. VLESS + gRPC + TLS       (CDN 友好，低延迟)\n' >&2
  printf '  5. VMess + WS  + TLS        (兼容性最广)\n' >&2
  printf '  6. VMess + gRPC + TLS\n' >&2
  printf '  7. Trojan + WS  + TLS\n' >&2
  printf '  8. Trojan + gRPC + TLS\n' >&2
  echo >&2
  local choice
  while true; do
    read -r -p '  请输入选项 [1-8]: ' choice
    case "$choice" in
      1) printf '%s' "vless-reality";   return ;;
      2) printf '%s' "ss-ws-tls";       return ;;
      3) printf '%s' "vless-ws-tls";    return ;;
      4) printf '%s' "vless-grpc-tls";  return ;;
      5) printf '%s' "vmess-ws-tls";    return ;;
      6) printf '%s' "vmess-grpc-tls";  return ;;
      7) printf '%s' "trojan-ws-tls";   return ;;
      8) printf '%s' "trojan-grpc-tls"; return ;;
      *) warn "请输入 1-8" ;;
    esac
  done
}

# ─────────────────────────── Install sub-flows ───────────────────────────
_install_reality() {
  UUID=$(gen_uuid)
  local keys; keys=$(gen_keys)
  PRIVKEY="${keys%|*}"; PUBKEY="${keys#*|}"
  [[ -n "$PRIVKEY" && -n "$PUBKEY" ]] || die "解析 xray x25519 输出失败"
  SHORTID=$(gen_shortid)
  DEST="${REALITY_DEST:-$(pick_dest)}"
  SNI="$DEST"
  DOMAIN=""; WS_PATH=""; GRPC_SVC=""; SS_METHOD=""; PASSWORD=""
  write_config_reality
}

_install_tls() {
  local transport=$1  # "ws" or "grpc"
  DOMAIN="${XRAY_DOMAIN:-}"
  if [[ -z "$DOMAIN" ]]; then
    read -r -p "  请输入域名（DNS A 记录已指向本机）: " DOMAIN
    [[ -n "$DOMAIN" ]] || die "域名不能为空"
  fi
  get_cert "$DOMAIN"

  local base="${PROTO%%-${transport}-tls}"
  if [[ "$base" == "trojan" ]]; then
    PASSWORD=$(gen_password); UUID=""
  else
    UUID=$(gen_uuid); PASSWORD=""
  fi
  WS_PATH=$(gen_path)
  GRPC_SVC=$(gen_path)
  PRIVKEY=""; PUBKEY=""; SHORTID=""; DEST=""; SNI=""; SS_METHOD=""

  case "$transport" in
    ws)   write_config_ws_tls ;;
    grpc) write_config_grpc_tls ;;
  esac
}

_install_ss() {
  # Domain + cert (SS traffic must be hidden in HTTPS to avoid probing)
  DOMAIN="${XRAY_DOMAIN:-}"
  if [[ -z "$DOMAIN" ]]; then
    read -r -p "  请输入域名（DNS A 记录已指向本机）: " DOMAIN
    [[ -n "$DOMAIN" ]] || die "域名不能为空"
  fi
  get_cert "$DOMAIN"

  SS_METHOD="${XRAY_SS_METHOD:-}"
  if [[ -z "$SS_METHOD" && -t 0 ]]; then
    echo
    printf '  加密方式：\n'
    printf '  1. aes-256-gcm         %s(推荐，广泛兼容)%s\n' "$G" "$N"
    printf '  2. chacha20-poly1305   (适合低性能设备)\n'
    printf '  3. aes-128-gcm\n'
    local m; read -r -p '  请选择 [1]: ' m
    case "${m:-1}" in
      2) SS_METHOD="chacha20-poly1305" ;;
      3) SS_METHOD="aes-128-gcm" ;;
      *) SS_METHOD="aes-256-gcm" ;;
    esac
  fi
  [[ -z "$SS_METHOD" ]] && SS_METHOD="aes-256-gcm"
  PASSWORD=$(gen_password)
  WS_PATH=$(gen_path)
  UUID=""; PRIVKEY=""; PUBKEY=""; SHORTID=""; DEST=""; SNI=""; GRPC_SVC=""
  write_config_ss_ws_tls
}

# ─────────────────────────── Commands ───────────────────────────
cmd_install() {
  require_root
  if [[ -s "$XRAY_CONFIG" && -z "${FORCE:-}" ]]; then
    if [[ -r "$XRAY_META_FILE" ]]; then
      warn "已存在配置 —— 跳过。如需重建请传 FORCE=1"
      cmd_info; return
    fi
    warn "发现 Xray 配置但缺少节点信息，将继续重建。"
  fi
  install_deps
  [[ -x "$XRAY_BIN" ]] || install_xray

  PROTO="${PROTOCOL:-}"
  [[ -z "$PROTO" ]] && PROTO=$(select_protocol)
  echo

  # Port
  case "$PROTO" in
    ss-ws-tls|*-ws-tls|*-grpc-tls) PORT="${REALITY_PORT:-443}" ;;
    *)                              PORT=$(pick_port) ;;
  esac
  ensure_port_free "$PORT"

  ADDR="${REALITY_ADDR:-}"
  if [[ -z "$ADDR" ]]; then
    ADDR=$(get_public_ip)
    [[ -z "$ADDR" ]] && { warn "无法自动检测公网 IP"; ADDR="YOUR_SERVER"; }
  fi
  NAME="${REALITY_NAME:-${PROTO}-${ADDR}}"

  case "$PROTO" in
    vless-reality)   _install_reality ;;
    ss-ws-tls)       _install_ss ;;
    *-ws-tls)        _install_tls "ws" ;;
    *-grpc-tls)      _install_tls "grpc" ;;
    *)               die "未知协议：$PROTO" ;;
  esac

  open_firewall "$PORT"
  systemctl enable --now xray >/dev/null
  systemctl restart xray; sleep 1
  if ! systemctl is-active --quiet xray; then
    journalctl -u xray -n 30 --no-pager >&2 || true
    die "Xray 启动失败，请检查上方日志"
  fi
  ok "Xray 服务运行中"

  local link; link=$(_build_link)
  save_meta
  printf '%s\n' "$link" > "$XRAY_SHARE_FILE"; chmod 600 "$XRAY_SHARE_FILE"
  _self_install || true
  print_result "$link"
}

cmd_info() {
  [[ -r "$XRAY_META_FILE" ]] || die "未找到节点配置，请先执行安装。"
  _reload_meta
  print_result "$(_build_link)"
}

cmd_status()  { systemctl --no-pager --full status xray 2>&1 | sed -n '1,20p'; }
cmd_logs()    { journalctl -u xray -n "${1:-50}" --no-pager; }
cmd_restart() {
  require_root
  systemctl restart xray; sleep 1
  systemctl is-active --quiet xray && ok "Xray 已重启" || warn "重启失败，执行 'xr logs' 查看"
}
cmd_update() {
  require_root; install_xray; systemctl restart xray; ok "Xray 已升级并重启"
}
cmd_uninstall() {
  require_root
  read -r -p "确认卸载 Xray 并清除配置？[y/N] " ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]] || { msg "已取消"; return; }
  uninstall_xray
  rm -f "$SELF_CMD"
  ok "卸载完成"
}

# ─────────────────────────── Edit commands ───────────────────────────
cmd_edit_port() {
  require_root; _reload_meta
  printf "当前端口：${Y}%s${N}\n" "$PORT"
  local new; read -r -p "新端口（留空取消）: " new
  [[ -z "$new" ]] && { msg "已取消"; return; }
  [[ "$new" =~ ^[0-9]+$ ]] && (( new >= 1 && new <= 65535 )) || die "端口须为 1-65535"
  PORT="$new"; open_firewall "$PORT"; _apply_changes
  ok "端口已更新为 ${Y}$PORT${N}"
}

cmd_edit_uuid() {
  require_root; _reload_meta
  case "$PROTO" in
    trojan-*|ss-ws-tls)
      local old="$PASSWORD"; PASSWORD=$(gen_password)
      _apply_changes; ok "密码已重新生成"
      printf "  旧：%s\n  新：%s\n" "$old" "$PASSWORD" ;;
    *)
      local old="$UUID"; UUID=$(gen_uuid)
      _apply_changes; ok "UUID 已重新生成"
      printf "  旧：%s\n  新：%s\n" "$old" "$UUID" ;;
  esac
}

cmd_edit_dest() {
  require_root; _reload_meta
  if [[ "$PROTO" != "vless-reality" ]]; then
    warn "此选项仅适用于 Reality 协议（当前：$PROTO）"; return; fi
  printf "当前伪装目标：${Y}%s${N}\n\n候选：\n" "$DEST"
  local i=1; for d in "${DEFAULT_DESTS[@]}"; do printf "  %d. %s\n" "$((i++))" "$d"; done
  printf "  %d. 自定义\n\n" "$i"
  local choice new_dest=""
  read -r -p "序号或直接输入域名（留空取消）: " choice
  [[ -z "$choice" ]] && { msg "已取消"; return; }
  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    if (( choice >= 1 && choice <= ${#DEFAULT_DESTS[@]} )); then
      new_dest="${DEFAULT_DESTS[$((choice-1))]}"
    else
      read -r -p "自定义域名: " new_dest
    fi
  else
    new_dest="$choice"
  fi
  [[ -z "$new_dest" ]] && { msg "已取消"; return; }
  DEST="$new_dest"; SNI="$new_dest"; _apply_changes
  ok "伪装目标已更新为 ${Y}$DEST${N}"
}

cmd_edit_name() {
  require_root; _reload_meta
  printf "当前名称：${Y}%s${N}\n" "$NAME"
  local new; read -r -p "新名称（留空取消）: " new
  [[ -z "$new" ]] && { msg "已取消"; return; }
  NAME="$new"; _apply_changes; ok "节点名称已更新为 ${Y}$NAME${N}"
}

# ─────────────────────────── Interactive menu ───────────────────────────
cmd_menu() {
  require_root
  while true; do
    clear
    printf '%s╔══════════════════════════════════════════════════╗%s\n' "$B" "$N"
    printf '%s║  Xray 管理脚本 %-34s║%s\n' "$B" "v${SCRIPT_VERSION}" "$N"
    printf '%s╚══════════════════════════════════════════════════╝%s\n' "$B" "$N"
    echo

    if [[ -r "$XRAY_META_FILE" ]]; then
      # shellcheck disable=SC1090
      . "$XRAY_META_FILE" 2>/dev/null || true
      local svc_str
      systemctl is-active --quiet xray 2>/dev/null \
        && svc_str="${G}● 运行中${N}" || svc_str="${R}● 已停止${N}"
      local id_display="${UUID:-${PASSWORD:-—}}"
      printf "  协议：${Y}%-20s${N}  端口：${Y}%s${N}\n" "${PROTO:-—}" "${PORT:-—}"
      local loc_display="${DOMAIN:-${ADDR:-—}}"
      printf "  地址：${Y}%-20s${N}  状态：%b\n" "$loc_display" "$svc_str"
    else
      printf "  ${Y}未检测到节点配置，请先执行安装${N}\n"
    fi

    echo
    printf '%s  ─────── 节点管理 ────────────────────────────%s\n' "$D" "$N"
    printf '  1. 查看节点信息 + 二维码\n'
    printf '  2. 修改端口\n'
    case "${PROTO:-}" in
      trojan-*|ss-ws-tls) printf '  3. 重新生成密码\n' ;;
      *)                  printf '  3. 重新生成 UUID\n' ;;
    esac
    [[ "${PROTO:-}" == "vless-reality" ]] \
      && printf '  4. 修改伪装目标 (SNI)\n' \
      || printf '  4. 修改伪装目标 %s(当前协议不支持)%s\n' "$D" "$N"
    printf '  5. 修改节点名称\n'
    echo
    printf '%s  ─────── 服务管理 ────────────────────────────%s\n' "$D" "$N"
    printf '  6. 重启 Xray\n'
    printf '  7. 查看日志（最近 50 条）\n'
    printf '  8. 查看服务状态\n'
    echo
    printf '%s  ─────── 系统操作 ────────────────────────────%s\n' "$D" "$N"
    printf '  9. 升级 Xray\n'
    printf '  10. 卸载 Xray\n'
    echo
    printf '  0. 退出\n\n'

    local choice; read -r -p "  请输入选项: " choice; echo
    case "$choice" in
      1)  cmd_info ;;
      2)  cmd_edit_port ;;
      3)  cmd_edit_uuid ;;
      4)  cmd_edit_dest ;;
      5)  cmd_edit_name ;;
      6)  cmd_restart ;;
      7)  cmd_logs 50 ;;
      8)  cmd_status ;;
      9)  cmd_update ;;
      10) cmd_uninstall; return ;;
      0)  break ;;
      *)  warn "无效选项" ;;
    esac
    echo; read -r -p "  按 Enter 返回主菜单..." _
  done
}

# ─────────────────────────── Self install ───────────────────────────
_self_install() {
  local src="${BASH_SOURCE[0]:-}"
  if [[ -z "$src" || ! -f "$src" ]]; then
    warn "无法自我复制（请用 'curl ... -o /tmp/xr.sh && bash /tmp/xr.sh' 方式执行）"
    return
  fi
  install -m 755 "$src" "$SELF_CMD"
  ok "管理命令已安装：${Y}$SELF_CMD${N}  →  输入 ${B}xr${N} 打开管理菜单"
}
cmd_self_install() { require_root; _self_install; }

usage() {
  cat <<EOF
${B}${SCRIPT_NAME} v${SCRIPT_VERSION}${N}  —  多协议 Xray 一键脚本

支持协议:
  VLESS+Reality  SS/VLESS/VMess/Trojan + WS/gRPC + TLS（SS 走 WS+TLS 防主动探测）

用法 (首次安装):
  bash $0 [install]   交互式选择协议并安装（默认）
  bash $0 help        显示本帮助

管理命令 (安装后输入 xr):
  xr               打开交互式管理菜单
  xr info          节点信息 + 分享链接 + 二维码
  xr status        Xray 服务状态
  xr logs [N]      最近 N 条日志（默认 50）
  xr restart       重启 Xray
  xr update        升级 Xray
  xr uninstall     卸载 Xray
  xr edit-port     修改端口
  xr edit-uuid     重新生成 UUID / 密码
  xr edit-dest     修改伪装目标（仅 Reality）
  xr edit-name     修改节点名称

可选环境变量:
  PROTOCOL=vless-reality|ss-ws-tls|vless-ws-tls|vless-grpc-tls|
           vmess-ws-tls|vmess-grpc-tls|trojan-ws-tls|trojan-grpc-tls
  REALITY_PORT=443       端口（TLS 协议默认 443，Reality 默认随机）
  REALITY_DEST=…         Reality 伪装目标
  REALITY_ADDR=1.2.3.4   分享链接服务器地址
  REALITY_NAME=MyNode    节点名称
  XRAY_DOMAIN=my.domain  TLS 协议域名
  XRAY_SS_METHOD=…       Shadowsocks 加密方式
  XRAY_VERSION=v26.3.27  固定 Xray 版本
  XRAY_INSTALLER_SHA256= 钉住官方安装脚本 SHA256
  FORCE=1                已有配置时强制重建
EOF
}

main() {
  local default_cmd="install"
  [[ "$(basename "${0:-}")" == "xr" ]] && default_cmd="menu"
  case "${1:-$default_cmd}" in
    menu)             cmd_menu ;;
    install)          cmd_install ;;
    info|link|show)   cmd_info ;;
    status)           cmd_status ;;
    logs)             shift || true; cmd_logs "${1:-50}" ;;
    restart)          cmd_restart ;;
    update|upgrade)   cmd_update ;;
    uninstall|remove) cmd_uninstall ;;
    edit-port)        cmd_edit_port ;;
    edit-uuid)        cmd_edit_uuid ;;
    edit-dest)        cmd_edit_dest ;;
    edit-name)        cmd_edit_name ;;
    self-install)     cmd_self_install ;;
    help|-h|--help)   usage ;;
    *) usage; exit 1 ;;
  esac
}
main "$@"
