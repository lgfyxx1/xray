#!/usr/bin/env bash
# xray-reality.sh — Multi-protocol Xray one-click installer
# Protocols: VLESS+Reality, SS/VLESS/VMess/Trojan + WS/gRPC + TLS
# License: MIT
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_NAME="xray-reality"
SCRIPT_VERSION="3.0.0"

XRAY_BIN="/usr/local/bin/xray"
SELF_CMD="/usr/local/bin/xr"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
XRAY_SHARE_FILE="${XRAY_CONFIG_DIR}/.share.txt"
XRAY_META_FILE="${XRAY_CONFIG_DIR}/.meta.env"
SSL_DIR="${XRAY_CONFIG_DIR}/ssl"
CERT_HOOK="/etc/letsencrypt/renewal-hooks/deploy/xray-cert"
CF_CREDENTIALS="/etc/letsencrypt/xray-cloudflare.ini"
CERT_PRE_HOOK="/etc/letsencrypt/xray-standalone-pre"
CERT_POST_HOOK="/etc/letsencrypt/xray-standalone-post"
BBR_SYSCTL_CONF="/etc/sysctl.d/99-xray-bbr.conf"
BBR_MODULES_CONF="/etc/modules-load.d/bbr.conf"

# Audited official installer; never execute a moving branch as root.
OFFICIAL_INSTALLER_COMMIT="04e6f3bd9534811ed901a48c47b2c042dd64eb3a"
OFFICIAL_INSTALLER_SHA256="9706391b9f8fbad0f2f4bf39197c506d6f519529232fec3c53cf009334f4336e"
OFFICIAL_INSTALLER_URL="https://raw.githubusercontent.com/XTLS/Xray-install/${OFFICIAL_INSTALLER_COMMIT}/install-release.sh"
MIN_XRAY_VERSION="26.10.31"
WORK_DIR="" TRANSACTION="" WAS_ACTIVE=0 WAS_ENABLED=0
ACME_STOPPED_SERVICES=()

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

https_get() {
  curl -q --fail --silent --show-error --location --proto '=https' \
    --proto-redir '=https' --tlsv1.2 --retry 3 --connect-timeout 10 --max-time 180 "$@"
}
ensure_work() {
  [[ -n "$WORK_DIR" ]] || WORK_DIR=$(mktemp -d)
}
cleanup() {
  local rc=$?
  trap - EXIT ERR INT TERM
  if [[ -n "$TRANSACTION" ]]; then
    warn "操作失败，恢复更新前的核心、配置和服务文件。"
    systemctl stop xray >/dev/null 2>&1 || true
    local path
    while IFS= read -r path; do
      rm -rf -- "/${path:?}"
      if [[ -e "$TRANSACTION/root/$path" ]]; then
        mkdir -p "$(dirname "/$path")"
        cp -a -- "$TRANSACTION/root/$path" "/$path" || rc=1
      fi
    done < "$TRANSACTION/paths"
    systemctl daemon-reload || rc=1
    if (( WAS_ENABLED )); then systemctl enable xray >/dev/null 2>&1 || rc=1
    else systemctl disable xray >/dev/null 2>&1 || true; fi
    if (( WAS_ACTIVE )); then systemctl start xray || rc=1; fi
    rc=1
  fi
  restart_acme_services || rc=1
  [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

begin_transaction() {
  ensure_work
  [[ -z "$TRANSACTION" ]] || return 0
  local backup="$WORK_DIR/rollback" path
  mkdir -p "$backup/root"
  systemctl is-active --quiet xray && WAS_ACTIVE=1 || WAS_ACTIVE=0
  systemctl is-enabled --quiet xray && WAS_ENABLED=1 || WAS_ENABLED=0
  for path in usr/local/bin/xray usr/local/share/xray usr/local/etc/xray \
      etc/systemd/system/xray.service etc/systemd/system/xray@.service \
      etc/systemd/system/xray.service.d etc/systemd/system/xray@.service.d \
      etc/letsencrypt/renewal-hooks/deploy/xray-cert \
      etc/letsencrypt/xray-cloudflare.ini etc/letsencrypt/xray-standalone-pre \
      etc/letsencrypt/xray-standalone-post; do
    printf '%s\n' "$path" >> "$backup/paths"
    if [[ -e "/$path" ]]; then
      mkdir -p "$backup/root/$(dirname "$path")"
      cp -a -- "/$path" "$backup/root/$path"
    fi
  done
  TRANSACTION="$backup"
}
commit_transaction() { TRANSACTION=""; }

preflight() {
  [[ $(uname -s) == Linux && -d /run/systemd/system ]] || die "仅支持使用 systemd 的 Linux"
  (( BASH_VERSINFO[0] >= 4 )) || die "需要 Bash 4 或更新版本"
  # One writer at a time; keep the lock until process exit.
  command -v flock >/dev/null || die "请先安装 util-linux（flock）"
  exec 9>/run/lock/xray-manager.lock
  flock -n 9 || die "另一个 xr 管理进程正在运行"
  # Reject symlinks at managed paths before root opens predictable filenames.
  local path
  for path in "$XRAY_CONFIG_DIR" "$XRAY_CONFIG" "$XRAY_META_FILE" "$XRAY_SHARE_FILE" \
      "$SSL_DIR" "$SSL_DIR/privkey.pem" "$SSL_DIR/fullchain.pem" "$SELF_CMD" \
      "$CERT_HOOK" "$CF_CREDENTIALS" "$CERT_PRE_HOOK" "$CERT_POST_HOOK"; do
    [[ ! -L "$path" ]] || die "拒绝写入符号链接：$path"
  done
}


# ─────────────────────────── Preflight ───────────────────────────
require_root() { [[ $EUID -eq 0 ]] || die "请使用 root 权限执行（sudo bash $0）"; }

detect_pm() {
  if   command -v apt-get >/dev/null; then PM=apt
  elif command -v dnf     >/dev/null; then PM=dnf
  elif command -v yum     >/dev/null; then PM=yum
  elif command -v zypper  >/dev/null; then PM=zypper
  elif command -v pacman  >/dev/null; then PM=pacman
  else die "未检测到受支持的包管理器（apt/dnf/yum/zypper/pacman）"
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
    pacman) pacman -S --noconfirm --needed "${pkgs[@]}" >/dev/null ;;
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
    pacman) pacman -Si "$pkg" >/dev/null 2>&1 ;;
  esac
}

install_deps() {
  detect_pm
  local pkgs=()
  command -v curl     >/dev/null || pkgs+=("curl")
  command -v openssl  >/dev/null || pkgs+=("openssl")
  command -v ss       >/dev/null || case "$PM" in apt|zypper|pacman) pkgs+=("iproute2");; *) pkgs+=("iproute");; esac
  command -v python3  >/dev/null || pkgs+=("python3")
  command -v unzip    >/dev/null || pkgs+=("unzip")
  command -v sha256sum >/dev/null || pkgs+=("coreutils")
  command -v runuser  >/dev/null || pkgs+=("util-linux")
  [[ -s /etc/ssl/certs/ca-certificates.crt || -s /etc/pki/tls/certs/ca-bundle.crt ]] || pkgs+=("ca-certificates")
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

enable_bbr() {
  local available_cc current_cc current_qdisc
  available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  if [[ " $available_cc " != *" bbr "* ]]; then
    if modprobe tcp_bbr >/dev/null 2>&1; then
      available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    fi
  fi
  if [[ " $available_cc " != *" bbr "* ]]; then
    warn "当前内核未提供 BBR，跳过启用"
    return 0
  fi
  printf 'tcp_bbr\n' >"$BBR_MODULES_CONF"
  current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
  if [[ "$current_cc" == "bbr" && "$current_qdisc" == "fq" ]]; then
    ok "BBR 已启用"
    return 0
  fi
  cat >"$BBR_SYSCTL_CONF" <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl -p "$BBR_SYSCTL_CONF" >/dev/null 2>&1 || die "应用 BBR sysctl 配置失败"
  current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
  if [[ "$current_cc" == "bbr" && "$current_qdisc" == "fq" ]]; then
    ok "已启用 BBR 加速"
  else
    warn "已写入 BBR 配置，但当前未确认生效"
  fi
}

cmd_bbr_status() {
  local available_cc current_cc current_qdisc
  available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
  printf "可用拥塞控制：%s\n" "${available_cc:-unknown}"
  printf "当前拥塞控制：%s\n" "${current_cc:-unknown}"
  printf "当前队列调度：%s\n" "${current_qdisc:-unknown}"
  lsmod | grep -q '^tcp_bbr' \
    && printf "BBR 模块：已加载\n" \
    || printf "BBR 模块：未加载\n"
}

# ─────────────────────────── Xray core ───────────────────────────
download_installer() {
  ensure_work
  https_get "$OFFICIAL_INSTALLER_URL" -o "$WORK_DIR/install-release.sh"
  printf '%s  %s\n' "$OFFICIAL_INSTALLER_SHA256" "$WORK_DIR/install-release.sh" | sha256sum -c - >/dev/null \
    || die "官方安装器 SHA256 校验失败，拒绝执行"
}

install_xray() {
  ensure_work
  local machine release_url version url digest archive
  case $(uname -m) in
    x86_64|amd64) machine=64 ;;
    aarch64|arm64) machine=arm64-v8a ;;
    *) die "本管理脚本已验证的架构为 x86_64 和 aarch64" ;;
  esac
  release_url="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
  if [[ -n "${XRAY_VERSION:-}" ]]; then
    [[ "$XRAY_VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "XRAY_VERSION 格式无效"
    release_url="https://api.github.com/repos/XTLS/Xray-core/releases/tags/v${XRAY_VERSION#v}"
  fi
  https_get "$release_url" -o "$WORK_DIR/release.json"
  state_tool release "$WORK_DIR/release.json" "$machine" "$MIN_XRAY_VERSION" > "$WORK_DIR/release.txt"
  { IFS= read -r version; IFS= read -r url; IFS= read -r digest; } < "$WORK_DIR/release.txt"
  archive="$WORK_DIR/Xray-linux-$machine.zip"
  msg "下载官方稳定版 $version，校验 GitHub Release SHA256"
  https_get "$url" -o "$archive"
  printf '%s  %s\n' "$digest" "$archive" | sha256sum -c - >/dev/null || die "核心压缩包 SHA256 校验失败"
  # The pinned official installer also verifies this local digest.
  printf 'SHA256= %s\n' "$digest" > "$archive.dgst"
  download_installer
  # Candidate config check before touching the installed binary.
  mkdir -p "$WORK_DIR/candidate"
  unzip -q "$archive" -d "$WORK_DIR/candidate"
  chmod 755 "$WORK_DIR/candidate/xray"
  if [[ -s "$XRAY_CONFIG" ]]; then
    XRAY_LOCATION_ASSET="$WORK_DIR/candidate" "$WORK_DIR/candidate/xray" run -test -config "$XRAY_CONFIG"
  fi
  # This wrapper owns a single managed service, not third-party/multi-instance setups.
  if systemctl list-units --state=active --no-legend 'xray@*' | grep -q .; then
    die "检测到其他运行中的 Xray 实例，请分别维护，拒绝影响它们"
  fi
  begin_transaction
  # Explicit paths prevent caller environment from redirecting root writes.
  env -u JSONS_PATH JSON_PATH="$XRAY_CONFIG_DIR" DAT_PATH=/usr/local/share/xray \
    bash "$WORK_DIR/install-release.sh" install --local "$archive" --manually-restart-later
  [[ -x "$XRAY_BIN" ]] || die "官方安装后未找到核心"
  [[ $("$XRAY_BIN" version | awk 'NR==1 {print $2}') == "${version#v}" ]] || die "安装后的版本不符"
}

uninstall_xray() {
  download_installer
  env -u JSONS_PATH JSON_PATH="$XRAY_CONFIG_DIR" DAT_PATH=/usr/local/share/xray \
    bash "$WORK_DIR/install-release.sh" remove --purge
  remove_cert_automation
}

remove_cert_automation() {
  systemctl disable --now xray-cert-renew.timer >/dev/null 2>&1 || true
  rm -f "$CERT_HOOK" "$CF_CREDENTIALS" "$CERT_PRE_HOOK" "$CERT_POST_HOOK" \
    /etc/systemd/system/xray-cert-renew.service /etc/systemd/system/xray-cert-renew.timer
  systemctl daemon-reload
}


# ─────────────────────────── Network / Crypto ───────────────────────────
get_public_ip() {
  local ip
  for s in api.ipify.org ipv4.icanhazip.com ifconfig.me; do
    ip=$(curl -q -fsS --proto '=https' --tlsv1.2 --max-time 4 "https://${s}" 2>/dev/null | tr -d '[:space:]') || continue
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return; }
  done
  for s in api64.ipify.org ifconfig.co; do
    ip=$(curl -q -fsS --proto '=https' --tlsv1.2 --max-time 4 "https://${s}" 2>/dev/null | tr -d '[:space:]') || continue
    if python3 -c 'import ipaddress,sys; ipaddress.ip_address(sys.argv[1])' "$ip" 2>/dev/null; then echo "$ip"; return; fi
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

trim_spaces() {
  local s=${1-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

normalize_domain() {
  local domain
  domain=$(trim_spaces "${1-}")
  domain=${domain%.}
  state_tool domain "$domain" >/dev/null || die "域名格式无效"
  printf '%s' "$domain"
}

read_domain_or_die() {
  local domain="${XRAY_DOMAIN:-}"
  if [[ -z "$domain" ]]; then
    read -r -p "  请输入域名（DNS A 记录已指向本机）: " domain
  fi
  domain=$(normalize_domain "$domain")
  [[ -n "$domain" ]] || die "域名不能为空"
  printf '%s\n' "  即将申请并配置的域名: $domain" >&2
  if [[ -z "${XRAY_DOMAIN:-}" && -t 0 ]]; then
    local confirm
    read -r -p "  确认无误？[Y/n]: " confirm
    [[ "${confirm:-Y}" =~ ^[Yy]$ ]] || die "已取消，请重新执行并输入正确域名"
  fi
  state_tool domain "$domain" >/dev/null || die "域名格式无效"
  printf '%s' "$domain"
}

get_acme_email() {
  local acme_email="${ACME_EMAIL:-}"
  acme_email=$(trim_spaces "$acme_email")
  [[ -n "$acme_email" ]] || die "TLS 证书申请需要设置 ACME_EMAIL"
  [[ "$acme_email" == *"@"* && "$acme_email" == *.* ]] \
    || die "ACME_EMAIL 格式无效，请提供真实可用邮箱：${acme_email:-<empty>}"
  printf '%s' "$acme_email"
}

# ─────────────────────────── TLS certificates ───────────────────────────
# Certificates come from distro-packaged Certbot, not a downloaded shell pipeline.
stop_acme_services() {
  local svc services=()
  IFS=', ' read -r -a services <<< "${ACME_STOP_SERVICES:-}"
  for svc in "${services[@]}"; do
    [[ "$svc" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.@-]*$ && "$svc" != xray* ]] || die "ACME_STOP_SERVICES 包含无效服务名"
    if systemctl is-active --quiet "$svc"; then
      ACME_STOPPED_SERVICES+=("$svc")
      systemctl stop "$svc"
    fi
  done
}

write_standalone_hooks() {
  local svc
  install -d -m 700 /etc/letsencrypt
  cat > "$CERT_PRE_HOOK" <<'EOF'
#!/bin/sh
set -eu
umask 077
: > /run/xray-cert-stopped-services
EOF
  if [[ -n "${ACME_STOPPED_SERVICES[*]:-}" ]]; then
  for svc in "${ACME_STOPPED_SERVICES[@]}"; do
    # service names were validated before stopping them
    printf 'if systemctl is-active --quiet %s; then\n  printf "%%s\\n" %s >> /run/xray-cert-stopped-services\n  systemctl stop %s\nfi\n' \
      "$svc" "$svc" "$svc" >> "$CERT_PRE_HOOK"
  done
  fi
  cat > "$CERT_POST_HOOK" <<'EOF'
#!/bin/sh
set -eu
[ -f /run/xray-cert-stopped-services ] || exit 0
while IFS= read -r svc; do systemctl start "$svc"; done < /run/xray-cert-stopped-services
rm -f /run/xray-cert-stopped-services
EOF
  chmod 700 "$CERT_PRE_HOOK" "$CERT_POST_HOOK"
}
restart_acme_services() {
  local svc failed=0
  [[ -n "${ACME_STOPPED_SERVICES[*]:-}" ]] || return 0
  for svc in "${ACME_STOPPED_SERVICES[@]}"; do
    systemctl start "$svc" || { warn "服务恢复失败：$svc"; failed=1; }
  done
  ACME_STOPPED_SERVICES=()
  return "$failed"
}

get_cert() {
  local domain=$1 email
  state_tool domain "$domain" >/dev/null
  email=$(get_acme_email)
  if ! command -v certbot >/dev/null; then pkg_install certbot; fi
  local args=(certonly --non-interactive --agree-tos --email "$email" --cert-name "$domain" -d "$domain" --keep-until-expiring)
  case "${ACME_DNS:-}" in
    cloudflare)
      [[ -n "${CF_Token:-}" ]] || die "需要 CF_Token"
      [[ "$CF_Token" =~ ^[a-zA-Z0-9_-]+$ ]] || die "CF_Token 格式无效"
      case "$PM" in
        apt) pkg_install python3-certbot-dns-cloudflare ;;
        dnf|yum) pkg_install python3-certbot-dns-cloudflare ;;
        *) die "此系统请手动从发行版安装 certbot-dns-cloudflare；自动 DNS 安装支持 apt/dnf/yum" ;;
      esac
      install -d -m 700 /etc/letsencrypt
      printf 'dns_cloudflare_api_token = %s\n' "$CF_Token" > "$CF_CREDENTIALS"
      chmod 600 "$CF_CREDENTIALS"
      args+=(--dns-cloudflare --dns-cloudflare-credentials "$CF_CREDENTIALS" --dns-cloudflare-propagation-seconds 60)
      ;;
    '')
      stop_acme_services
      write_standalone_hooks
      ensure_port_free 80
      args+=(--standalone --http-01-port 80 --pre-hook "$CERT_PRE_HOOK" --post-hook "$CERT_POST_HOOK")
      ;;
    *) die "ACME_DNS 只支持 cloudflare 或留空" ;;
  esac
  certbot "${args[@]}"
  restart_acme_services
  install -d -m 750 -o root -g xray "$SSL_DIR"
  install -m 640 -o root -g xray "/etc/letsencrypt/live/$domain/privkey.pem" "$SSL_DIR/privkey.pem"
  install -m 640 -o root -g xray "/etc/letsencrypt/live/$domain/fullchain.pem" "$SSL_DIR/fullchain.pem"
  install -d -m 755 "$(dirname "$CERT_HOOK")"
  cat > "$CERT_HOOK" <<EOF
#!/bin/sh
set -eu
[ "\$RENEWED_LINEAGE" = "/etc/letsencrypt/live/$domain" ] || exit 0
[ -d /usr/local/etc/xray/ssl ] || exit 0
install -m 640 -o root -g xray "\$RENEWED_LINEAGE/privkey.pem" /usr/local/etc/xray/ssl/privkey.pem
install -m 640 -o root -g xray "\$RENEWED_LINEAGE/fullchain.pem" /usr/local/etc/xray/ssl/fullchain.pem
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
if systemctl is-active --quiet xray; then systemctl restart xray; fi
EOF
  chmod 750 "$CERT_HOOK"
  # Use our own timer so renewal availability does not depend on distro defaults.
  cat > /etc/systemd/system/xray-cert-renew.service <<EOF
[Unit]
Description=Renew Xray TLS certificate with Certbot
[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --cert-name $domain
EOF
  cat > /etc/systemd/system/xray-cert-renew.timer <<'EOF'
[Unit]
Description=Check Xray TLS certificate renewal daily
[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now xray-cert-renew.timer
  ok "证书已安装，自动续期已启用。standalone 续期时需保持 80/tcp 可用。"
}

retire_legacy_acme() {
  # Match only the old script's exact install paths. Do not execute acme.sh or
  # its shell configs. Renaming .conf to .conf.removed is upstream's --remove.
  local domain=$1 root_home
  root_home=$(getent passwd root | cut -d: -f6)
  [[ -n "$root_home" ]] || return 0
  python3 - "$root_home/.acme.sh" "$domain" "$SSL_DIR" <<'PY'
import pathlib, sys
root=pathlib.Path(sys.argv[1]); domain=sys.argv[2]; ssl=sys.argv[3]
for dirname in (domain,domain+'_ecc'):
    conf=root/dirname/(domain+'.conf')
    if conf.is_symlink() or not conf.is_file(): continue
    text=conf.read_text()
    if ssl+'/privkey.pem' in text and ssl+'/fullchain.pem' in text:
        removed=conf.with_name(conf.name+'.removed')
        if removed.exists(): raise ValueError('legacy .removed backup exists; inspect before migrating')
        conf.rename(removed)
        print('Disabled legacy acme.sh renewal for '+domain)
PY
}

port_users() { ss -tlnpH "sport = :$1"; }
ensure_port_free() {
  state_tool port "$1" >/dev/null
  local users
  users=$(port_users "$1")
  [[ -z "$users" ]] || die "$1/tcp 已被占用，请选用其他端口或先停止占用服务"
}


# ─────────────────────────── Structured state, config and URI handling ─────
state_tool() {
  PROTO="$PROTO" PORT="$PORT" UUID="$UUID" PASSWORD="$PASSWORD" \
  PRIVKEY="$PRIVKEY" PUBKEY="$PUBKEY" SHORTID="$SHORTID" DEST="$DEST" SNI="$SNI" \
  DOMAIN="$DOMAIN" WS_PATH="$WS_PATH" GRPC_SVC="$GRPC_SVC" SS_METHOD="$SS_METHOD" \
  ADDR="$ADDR" NAME="$NAME" SSL_DIR="$SSL_DIR" python3 - "$@" <<'PY'
import base64, ipaddress, json, os, re, sys
from urllib.parse import quote
FIELDS = 'PROTO PORT UUID PASSWORD PRIVKEY PUBKEY SHORTID DEST SNI DOMAIN WS_PATH GRPC_SVC SS_METHOD ADDR NAME'.split()
PROTOCOLS = ['vless-reality', 'ss-ws-tls'] + [p+'-'+t+'-tls' for p in ('vless','vmess','trojan') for t in ('ws','grpc')]
def domain(v):
    if len(v)>253 or '.' not in v or not all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?',x) for x in v.split('.')):
        raise ValueError('invalid domain')
def port(v):
    if not re.fullmatch(r'[1-9][0-9]{0,4}',v) or not 1<=int(v)<=65535: raise ValueError('invalid port')
def validate(d):
    if set(d)!=set(FIELDS) or not all(isinstance(v,str) for v in d.values()): raise ValueError('invalid metadata fields')
    for v in d.values():
        if any(ord(c)<32 or ord(c)==127 for c in v): raise ValueError('control character in metadata')
    if d['PROTO'] not in PROTOCOLS: raise ValueError('invalid protocol')
    port(d['PORT'])
    try: ipaddress.ip_address(d['ADDR'])
    except ValueError: domain(d['ADDR'])
    if not 1<=len(d['NAME'])<=256: raise ValueError('invalid name length')
    if d['PROTO']=='vless-reality':
        domain(d['DEST']); domain(d['SNI'])
        for k in ('PRIVKEY','PUBKEY'):
            if not re.fullmatch(r'[A-Za-z0-9_-]{43}',d[k]) or len(base64.urlsafe_b64decode(d[k]+'='))!=32: raise ValueError('invalid X25519 key')
        if not re.fullmatch(r'(?:[0-9a-fA-F]{2}){1,8}',d['SHORTID']): raise ValueError('invalid short ID')
    else:
        domain(d['DOMAIN'])
        for k in ('WS_PATH','GRPC_SVC'):
            if not re.fullmatch(r'[A-Za-z0-9_-]{1,128}',d[k]): raise ValueError('invalid transport path')
    if d['PROTO'].startswith(('vless','vmess')):
        if not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}',d['UUID']): raise ValueError('invalid UUID')
    elif not re.fullmatch(r'[A-Za-z0-9_-]{16,128}',d['PASSWORD']): raise ValueError('invalid password')
    if d['PROTO']=='ss-ws-tls' and d['SS_METHOD'] not in ('aes-256-gcm','aes-128-gcm','chacha20-poly1305'): raise ValueError('invalid SS method')
def load(path, config):
    text=open(path).read()
    if text.lstrip().startswith('{'): d=json.loads(text)
    else:
        # Legacy KEY=value is DATA. Never source/eval it, even during migration.
        d={k:'' for k in FIELDS}
        for line in text.splitlines():
            if not line: continue
            k,sep,v=line.partition('=')
            if not sep or k not in FIELDS: raise ValueError('invalid legacy metadata')
            d[k]=v
        d['PROTO']=d['PROTO'] or 'vless-reality'
        if d['PROTO']=='vless-reality' and not d['PRIVKEY']:
            d['PRIVKEY']=json.load(open(config))['inbounds'][0]['streamSettings']['realitySettings']['privateKey']
    validate(d); return d
try:
    cmd=sys.argv[1]
    if cmd=='domain': domain(sys.argv[2]); sys.exit(0)
    if cmd=='port': port(sys.argv[2]); sys.exit(0)
    if cmd=='release':
        r=json.load(open(sys.argv[2])); tag=r['tag_name']
        if r.get('draft') or r.get('prerelease') or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+',tag): raise ValueError('not a stable release')
        if tuple(map(int,tag[1:].split('.')))<tuple(map(int,sys.argv[4].split('.'))): raise ValueError('version below security minimum')
        name='Xray-linux-'+sys.argv[3]+'.zip'
        a=next(a for a in r['assets'] if a['name']==name)
        url='https://github.com/XTLS/Xray-core/releases/download/'+tag+'/'+name
        if a['browser_download_url']!=url or not re.fullmatch(r'sha256:[0-9a-f]{64}',a.get('digest') or ''): raise ValueError('missing trusted release digest')
        print(tag); print(url); print(a['digest'][7:]); sys.exit(0)
    if cmd=='load':
        d=load(sys.argv[2],sys.argv[3])
        for k in FIELDS: sys.stdout.write(k+'\0'+d[k]+'\0')
        sys.exit(0)
    d={k:os.environ[k] for k in FIELDS}; validate(d)
    if cmd=='validate': sys.exit(0)
    if cmd=='save': print(json.dumps(d,ensure_ascii=False,indent=2)); sys.exit(0)
    proto=d['PROTO']; base=proto.split('-')[0]; is_ws='-ws-' in proto
    if cmd=='config':
        if proto=='vless-reality':
            settings={'clients':[{'id':d['UUID'],'flow':'xtls-rprx-vision'}],'decryption':'none'}
            stream={'network':'raw','security':'reality','realitySettings':{'show':False,'target':d['DEST']+':443','xver':0,'serverNames':[d['SNI']],'privateKey':d['PRIVKEY'],'shortIds':[d['SHORTID']]}}
        else:
            settings={'clients':[{'password':d['PASSWORD']}]} if base=='trojan' else {'clients':[{'id':d['UUID']}]}
            if base=='vless': settings['decryption']='none'
            if base=='ss': settings={'method':d['SS_METHOD'],'password':d['PASSWORD'],'network':'tcp'}
            stream={'network':'ws' if is_ws else 'grpc','security':'tls','tlsSettings':{'minVersion':'1.2','alpn':['http/1.1'] if is_ws else ['h2'],'certificates':[{'certificateFile':os.environ['SSL_DIR']+'/fullchain.pem','keyFile':os.environ['SSL_DIR']+'/privkey.pem'}]}}
            stream['wsSettings' if is_ws else 'grpcSettings']={'path':'/'+d['WS_PATH']} if is_ws else {'serviceName':d['GRPC_SVC']}
        inbound={'listen':'0.0.0.0','port':int(d['PORT']),'protocol':'shadowsocks' if base=='ss' else base,'settings':settings,'streamSettings':stream,'sniffing':{'enabled':True,'destOverride':['http','tls','quic'],'routeOnly':True}}
        private=['0.0.0.0/8','10.0.0.0/8','100.64.0.0/10','127.0.0.0/8','169.254.0.0/16','172.16.0.0/12','192.168.0.0/16','224.0.0.0/4','240.0.0.0/4','::/128','::1/128','fc00::/7','fe80::/10','ff00::/8']
        config={'log':{'loglevel':'warning'},'inbounds':[inbound],'outbounds':[{'tag':'direct','protocol':'freedom','settings':{'domainStrategy':'UseIP'}},{'tag':'block','protocol':'blackhole'}],'routing':{'domainStrategy':'IPOnDemand','rules':[{'type':'field','ip':private,'outboundTag':'block'},{'type':'field','protocol':['bittorrent'],'outboundTag':'block'}]}}
        print(json.dumps(config,ensure_ascii=False,indent=2)); sys.exit(0)
    if cmd=='link':
        enc=lambda v:quote(v,safe='')
        name=enc(d['NAME']); host=d['ADDR']; host='['+host+']' if ':' in host else host
        if proto=='vless-reality':
            print('vless://'+d['UUID']+'@'+host+':'+d['PORT']+'?encryption=none&flow=xtls-rprx-vision&security=reality&sni='+d['SNI']+'&fp=chrome&pbk='+d['PUBKEY']+'&sid='+d['SHORTID']+'&type=tcp&headerType=none#'+name)
        elif base=='vmess':
            v={'v':'2','ps':d['NAME'],'add':d['DOMAIN'],'port':d['PORT'],'id':d['UUID'],'aid':'0','scy':'auto','net':'ws' if is_ws else 'grpc','type':'none' if is_ws else 'gun','host':d['DOMAIN'] if is_ws else '', 'path':'/'+d['WS_PATH'] if is_ws else d['GRPC_SVC'],'tls':'tls','sni':d['DOMAIN'],'alpn':'http/1.1' if is_ws else 'h2'}
            print('vmess://'+base64.b64encode(json.dumps(v,ensure_ascii=False).encode()).decode())
        elif base=='ss':
            user=base64.urlsafe_b64encode((d['SS_METHOD']+':'+d['PASSWORD']).encode()).decode().rstrip('=')
            plugin='v2ray-plugin;mode=websocket;tls;host='+d['DOMAIN']+';path=/'+d['WS_PATH']
            print('ss://'+user+'@'+d['DOMAIN']+':'+d['PORT']+'?plugin='+enc(plugin)+'#'+name)
        else:
            user=d['UUID'] if base=='vless' else d['PASSWORD']
            query=('encryption=none&' if base=='vless' else '')+'security=tls&sni='+d['DOMAIN']+'&type='+('ws' if is_ws else 'grpc')
            query+=('&host='+d['DOMAIN']+'&path='+enc('/'+d['WS_PATH'])) if is_ws else '&serviceName='+d['GRPC_SVC']
            print(base+'://'+user+'@'+d['DOMAIN']+':'+d['PORT']+'?'+query+'#'+name)
        sys.exit(0)
    raise ValueError('unknown operation')
except (ValueError,KeyError,StopIteration,OSError,TypeError) as e:
    print('Invalid Xray state/input: '+str(e),file=sys.stderr); sys.exit(1)
PY
}

_write_current_config() {
  state_tool validate
  install -d -m 750 -o root -g xray "$XRAY_CONFIG_DIR"
  ensure_work
  state_tool config > "$WORK_DIR/config.json"
  "$XRAY_BIN" run -test -config "$WORK_DIR/config.json"
  # Stage in the destination filesystem for atomic replacement.
  install -m 640 -o root -g xray "$WORK_DIR/config.json" "$XRAY_CONFIG.new"
  mv -f -- "$XRAY_CONFIG.new" "$XRAY_CONFIG"
}
_build_link() { state_tool link; }
save_meta() {
  ensure_work
  state_tool save > "$WORK_DIR/meta.json"
  install -m 600 -o root -g root "$WORK_DIR/meta.json" "$XRAY_META_FILE.new"
  mv -f -- "$XRAY_META_FILE.new" "$XRAY_META_FILE"
}
_reload_meta() {
  [[ -r "$XRAY_META_FILE" ]] || die "未找到节点信息，请先安装"
  ensure_work
  state_tool load "$XRAY_META_FILE" "$XRAY_CONFIG" > "$WORK_DIR/meta.values" || die "节点信息不合法，拒绝加载"
  local key value
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    printf -v "$key" '%s' "$value"
  done < "$WORK_DIR/meta.values"
}
prepare_service() {
  install -d -m 750 -o root -g xray "$XRAY_CONFIG_DIR"
  chown root:xray "$XRAY_CONFIG"
  chmod 640 "$XRAY_CONFIG"
  if [[ -d "$SSL_DIR" ]]; then
    chown root:xray "$SSL_DIR"; chmod 750 "$SSL_DIR"
    local f
    for f in "$SSL_DIR/privkey.pem" "$SSL_DIR/fullchain.pem"; do
      [[ ! -f "$f" ]] || { chown root:xray "$f"; chmod 640 "$f"; }
    done
  fi
  install -d -m 755 /etc/systemd/system/xray.service.d
  cat > /etc/systemd/system/xray.service.d/99-xray-manager.conf <<'EOF'
[Service]
User=xray
Group=xray
Environment=GODEBUG=multipathtcp=0
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadWritePaths=-/var/log/xray
CapabilityBoundingSet=
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=
AmbientCapabilities=CAP_NET_BIND_SERVICE
UMask=0077
EOF
  systemctl daemon-reload
  runuser -u xray -- "$XRAY_BIN" run -test -config "$XRAY_CONFIG"
}
restart_checked() {
  systemctl restart xray
  sleep 2
  systemctl is-active --quiet xray || die "Xray 启动失败，将回滚；请检查日志"
}
_apply_changes() {
  begin_transaction
  _write_current_config
  prepare_service
  restart_checked
  save_meta
  state_tool link > "$XRAY_SHARE_FILE"
  chmod 600 "$XRAY_SHARE_FILE"; chown root:root "$XRAY_SHARE_FILE"
  commit_transaction
  ok "配置已验证并生效"
}


# ─────────────────────────── Firewall ───────────────────────────
open_firewall() {
  local port=$1
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi '^Status: active'; then
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
  [[ ! -r "$XRAY_META_FILE" ]] || _reload_meta

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
  printf '  1. VLESS + TCP + Reality    %s← 推荐，推荐使用%s\n' "$G" "$N" >&2
  printf '\n%s  ─── 需要域名 + 自动申请 TLS 证书 ──────────%s\n' "$D" "$N" >&2
  printf '  2. Shadowsocks + WS + TLS   (需兼容 v2ray-plugin 的客户端)\n' >&2
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
}

_install_tls() {
  local transport=$1  # "ws" or "grpc"
  DOMAIN=$(read_domain_or_die)
  get_cert "$DOMAIN"

  local base="${PROTO%%-"${transport}"-tls}"
  if [[ "$base" == "trojan" ]]; then
    PASSWORD=$(gen_password); UUID=""
  else
    UUID=$(gen_uuid); PASSWORD=""
  fi
  WS_PATH=$(gen_path)
  GRPC_SVC=$(gen_path)
  PRIVKEY=""; PUBKEY=""; SHORTID=""; DEST=""; SNI=""; SS_METHOD=""

}

_install_ss() {
  # Domain + cert (SS traffic must be hidden in HTTPS to avoid probing)
  DOMAIN=$(read_domain_or_die)
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
  UUID=""; PRIVKEY=""; PUBKEY=""; SHORTID=""; DEST=""; SNI=""; GRPC_SVC=$(gen_path)
}

# ─────────────────────────── Commands ───────────────────────────
cmd_install() {
  require_root
  install_deps
  if [[ -s "$XRAY_CONFIG" && "${FORCE:-0}" != 1 ]]; then
    [[ -r "$XRAY_META_FILE" ]] || die "存在非本脚本管理的配置，拒绝覆盖；请先备份并人工迁移"
    msg "保留现有节点参数并升级官方核心"
    cmd_update
    _self_install
    cmd_info
    return
  fi
  PROTO="${PROTOCOL:-}"
  [[ -n "$PROTO" ]] || PROTO=$(select_protocol)
  case "$PROTO" in
    vless-reality|ss-ws-tls|vless-ws-tls|vless-grpc-tls|vmess-ws-tls|vmess-grpc-tls|trojan-ws-tls|trojan-grpc-tls) ;;
    *) die "未知协议：$PROTO" ;;
  esac
  case "$PROTO" in
    *-tls) PORT="${REALITY_PORT:-443}" ;;
    *) PORT=$(pick_port) ;;
  esac
  ensure_port_free "$PORT"
  ADDR="${REALITY_ADDR:-}"
  [[ -n "$ADDR" ]] || ADDR=$(get_public_ip)
  [[ -n "$ADDR" ]] || die "无法检测公网 IP，请设置 REALITY_ADDR"
  NAME="${REALITY_NAME:-${PROTO}-${ADDR}}"
  # Validate user controlled fields before any downloads or writes.
  state_tool port "$PORT"
  install_xray
  case "$PROTO" in
    vless-reality) _install_reality ;;
    ss-ws-tls) _install_ss ;;
    *-ws-tls) _install_tls ws ;;
    *-grpc-tls) _install_tls grpc ;;
  esac
  _write_current_config
  prepare_service
  open_firewall "$PORT"
  systemctl enable xray >/dev/null
  restart_checked
  save_meta
  state_tool link > "$XRAY_SHARE_FILE"
  chmod 600 "$XRAY_SHARE_FILE"; chown root:root "$XRAY_SHARE_FILE"
  commit_transaction
  if [[ "$PROTO" != vless-reality ]]; then retire_legacy_acme "$DOMAIN"; fi
  if [[ "${ENABLE_BBR:-1}" == 1 ]]; then enable_bbr; fi
  _self_install
  print_result "$(_build_link)"
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
  "$XRAY_BIN" run -test -config "$XRAY_CONFIG"
  restart_checked
  ok "Xray 已重启"
}
cmd_update() {
  require_root
  install_deps
  [[ -r "$XRAY_META_FILE" ]] || die "只升级本脚本管理的节点；缺少节点信息，拒绝更改"
  _reload_meta
  install_xray
  # Existing UUID, password and REALITY keys are retained; only config schema changes.
  _write_current_config
  prepare_service
  restart_checked
  save_meta
  state_tool link > "$XRAY_SHARE_FILE"
  chmod 600 "$XRAY_SHARE_FILE"; chown root:root "$XRAY_SHARE_FILE"
  commit_transaction
  ok "官方核心已升级，节点参数保留"
  if [[ "$PROTO" != vless-reality && ! -f "$CERT_HOOK" ]]; then
    warn "旧 TLS 节点的续期方式尚未迁移；请带 ACME_EMAIL（DNS 模式另带 CF_Token）执行 xr migrate-cert"
  fi
}
cmd_migrate_cert() {
  require_root
  install_deps
  _reload_meta
  [[ "$PROTO" != vless-reality ]] || die "Reality 不需要证书迁移"
  begin_transaction
  get_cert "$DOMAIN"
  prepare_service
  restart_checked
  commit_transaction
  retire_legacy_acme "$DOMAIN"
  ok "证书已迁移至发行版 Certbot；旧 acme.sh 若用于其他域名，请继续独立维护"
}
cmd_enable_bbr() {
  require_root
  enable_bbr
  cmd_bbr_status
}
cmd_delete_node() {
  require_root
  [[ -r "$XRAY_META_FILE" || -s "$XRAY_CONFIG" ]] || { warn "未检测到节点配置"; return; }
  read -r -p "确认删除当前节点配置并停止 Xray？[y/N] " ans
  [[ "${ans:-N}" =~ ^[Yy]$ ]] || { msg "已取消"; return; }
  systemctl stop xray >/dev/null 2>&1 || true
  rm -f "$XRAY_CONFIG" "$XRAY_META_FILE" "$XRAY_SHARE_FILE"
  rm -f "$SSL_DIR/privkey.pem" "$SSL_DIR/fullchain.pem"
  remove_cert_automation
  rmdir "$SSL_DIR" 2>/dev/null || true
  ok "当前节点已删除，Xray 程序仍保留"
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
  state_tool port "$new" || die "端口须为 1-65535（不含前导零）"
  [[ "$new" == "$PORT" ]] && { msg "端口未变化"; return; }
  ensure_port_free "$new"
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
  state_tool domain "$new_dest"
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
      _reload_meta
      local svc_str
      systemctl is-active --quiet xray 2>/dev/null \
        && svc_str="${G}● 运行中${N}" || svc_str="${R}● 已停止${N}"
      printf "  协议：${Y}%-20s${N}  端口：${Y}%s${N}\n" "${PROTO:-—}" "${PORT:-—}"
      local loc_display="${DOMAIN:-${ADDR:-—}}"
      printf "  地址：${Y}%-20s${N}  状态：%b\n" "$loc_display" "$svc_str"
    else
      printf '  %s未检测到节点配置，请先执行安装%s\n' "$Y" "$N"
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
    printf '  9. 查看 BBR 状态\n'
    printf '  10. 启用 BBR\n'
    printf '  11. 升级 Xray\n'
    printf '  12. 删除当前节点\n'
    printf '  13. 卸载 Xray\n'
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
      9)  cmd_bbr_status ;;
      10) cmd_enable_bbr ;;
      11) cmd_update ;;
      12) cmd_delete_node ;;
      13) cmd_uninstall; return ;;
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
  VLESS+Reality  SS/VLESS/VMess/Trojan + WS/gRPC + TLS（SS 需客户端插件）

用法 (首次安装):
  bash $0 [install]   交互式选择协议并安装（默认）
  bash $0 help        显示本帮助

管理命令 (安装后输入 xr):
  xr               打开交互式管理菜单
  xr info          节点信息 + 分享链接 + 二维码
  xr status        Xray 服务状态
  xr logs [N]      最近 N 条日志（默认 50）
  xr bbr           查看 BBR 状态
  xr enable-bbr    启用 BBR
  xr restart       重启 Xray
  xr update        升级 Xray
  xr migrate-cert  将旧 TLS 节点证书续期迁移到 Certbot
  xr delete-node   删除当前节点配置
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
  XRAY_VERSION=v26.10.31  固定 Xray 版本
  ENABLE_BBR=0            不修改系统拥塞控制
  FORCE=1                已有配置时强制重建

系统优化:
  默认尝试启用 BBR；若内核不支持则自动跳过
EOF
}

main() {
  local default_cmd="install"
  [[ "$(basename "${0:-}")" == "xr" ]] && default_cmd="menu"
  case "${1:-$default_cmd}" in help|-h|--help) usage; return;; esac
  require_root
  preflight
  case "${1:-$default_cmd}" in
    menu)             cmd_menu ;;
    install)          cmd_install ;;
    info|link|show)   cmd_info ;;
    status)           cmd_status ;;
    logs)             shift || true; cmd_logs "${1:-50}" ;;
    bbr)              cmd_bbr_status ;;
    enable-bbr)       cmd_enable_bbr ;;
    restart)          cmd_restart ;;
    update|upgrade)   cmd_update ;;
    migrate-cert)     cmd_migrate_cert ;;
    delete-node)      cmd_delete_node ;;
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
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi

