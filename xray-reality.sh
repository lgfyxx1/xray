#!/usr/bin/env bash
# xray-reality.sh — Lightweight, official-aligned, secure Xray VLESS-Reality one-click installer.
#
# Upstream installer used (with SHA256 verification):
#   https://github.com/XTLS/Xray-install
#
# Goals: safer / smaller / faster / more anti-blocking / friendlier than 233boy/Xray.
# License: MIT
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_NAME="xray-reality"
SCRIPT_VERSION="1.1.0"

XRAY_BIN="/usr/local/bin/xray"
SELF_CMD="/usr/local/bin/xr"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
XRAY_SHARE_FILE="${XRAY_CONFIG_DIR}/.share.txt"
XRAY_META_FILE="${XRAY_CONFIG_DIR}/.meta.env"

OFFICIAL_INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# Curated SNI candidates — large TLS 1.3 + H2 sites known to behave well as Reality dest.
DEFAULT_DESTS=(
  "www.microsoft.com"
  "addons.mozilla.org"
  "www.lovelive-anime.jp"
  "swdist.apple.com"
  "www.tesla.com"
  "gateway.icloud.com"
  "www.cloudflare.com"
)

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
require_root() {
  [[ $EUID -eq 0 ]] || die "请使用 root 权限执行（例如：sudo bash $0 $*）"
}

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
  local pkgs="$*"
  case "$PM" in
    apt)    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $pkgs >/dev/null ;;
    dnf)    dnf install -y -q $pkgs >/dev/null ;;
    yum)    yum install -y -q $pkgs >/dev/null ;;
    zypper) zypper --non-interactive install -y $pkgs >/dev/null ;;
    pacman) pacman -Sy --noconfirm --needed $pkgs >/dev/null ;;
    apk)    apk add --no-cache $pkgs >/dev/null ;;
  esac
}

install_deps() {
  detect_pm
  local pkgs=""
  command -v curl     >/dev/null || pkgs+=" curl"
  command -v openssl  >/dev/null || pkgs+=" openssl"
  command -v ss       >/dev/null || case "$PM" in apt|zypper|pacman|apk) pkgs+=" iproute2";; *) pkgs+=" iproute";; esac
  command -v qrencode >/dev/null || pkgs+=" qrencode"
  command -v tar      >/dev/null || pkgs+=" tar"
  if [[ -n "$pkgs" ]]; then
    msg "安装依赖：$pkgs"
    pkg_install "$pkgs" || warn "部分依赖安装失败（如 qrencode 不影响主流程）"
  fi
}

# ─────────────────────────── Xray install via official script ───────────────────────────
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
      || { rm -f "$tmp"; die "官方安装脚本 SHA256 与 XRAY_INSTALLER_SHA256 不符（疑似中间人或上游变更）"; }
    ok "官方安装脚本 SHA256 校验通过"
  else
    warn "未提供 XRAY_INSTALLER_SHA256（脚本仍走 HTTPS+二进制 dgst 校验，但你可以钉住此值进一步加固）"
  fi
  # The official installer itself SHA256-verifies the Xray-core zip via the .dgst file.
  bash "$tmp" install ${XRAY_VERSION:+--version "$XRAY_VERSION"}
  rm -f "$tmp"
  [[ -x "$XRAY_BIN" ]] || die "Xray 安装后仍未找到 $XRAY_BIN"
  ok "Xray 已安装：$($XRAY_BIN version | head -n1)"
}

uninstall_xray() {
  local tmp; tmp=$(mktemp); chmod 600 "$tmp"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --max-time 30 \
       "$OFFICIAL_INSTALLER_URL" -o "$tmp" || die "无法下载官方卸载脚本"
  bash "$tmp" remove --purge || true
  rm -f "$tmp" "$XRAY_SHARE_FILE" "$XRAY_META_FILE"
}

# ─────────────────────────── Network helpers ───────────────────────────
get_public_ip() {
  local ip srcs_v4=(api.ipify.org ipv4.icanhazip.com ifconfig.me)
  for s in "${srcs_v4[@]}"; do
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
  msg "对候选伪装目标做 TLS 握手测速…" >&2
  local best="" best_ms=999999 d t ms
  for d in "${DEFAULT_DESTS[@]}"; do
    t=$(curl -o /dev/null -s -w '%{time_appconnect}' --max-time 3 --connect-timeout 2 \
        --proto '=https' --tlsv1.2 "https://${d}/" 2>/dev/null || echo 0)
    ms=$(awk -v x="$t" 'BEGIN{printf "%d", x*1000}')
    if (( ms > 0 && ms < best_ms )); then best_ms=$ms; best=$d; fi
    printf "  %-28s %5d ms\n" "$d" "$ms" >&2
  done
  [[ -z "$best" ]] && { warn "全部候选目标均不可达，回退到 www.microsoft.com"; best=www.microsoft.com; best_ms=0; }
  ok "已选伪装目标：${best} (${best_ms} ms)" >&2
  echo "$best"
}

pick_port() {
  if [[ -n "${REALITY_PORT:-}" ]]; then echo "$REALITY_PORT"; return; fi
  local p
  for _ in $(seq 1 60); do
    p=$(( RANDOM % 20001 + 30000 ))
    ss -tlnH "sport = :$p" 2>/dev/null | grep -q . || { echo "$p"; return; }
  done
  echo 443
}

# ─────────────────────────── Crypto material ───────────────────────────
gen_keys() {
  "$XRAY_BIN" x25519 | awk '
    /[Pp]rivate.?[Kk]ey/ { priv=$NF }
    /Public.?key|Password/ { pub=$NF }
    END { printf "%s|%s", priv, pub }'
}
gen_shortid() { openssl rand -hex 8; }
gen_uuid()    { "$XRAY_BIN" uuid; }

# ─────────────────────────── Config render ───────────────────────────
write_config() {
  local port=$1 uuid=$2 priv=$3 sid=$4 dest=$5 sni=$6
  install -d -m 755 "$XRAY_CONFIG_DIR"
  cat > "$XRAY_CONFIG" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-reality",
      "listen": "0.0.0.0",
      "port": ${port},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${uuid}", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${dest}:443",
          "xver": 0,
          "serverNames": ["${sni}"],
          "privateKey": "${priv}",
          "shortIds": ["${sid}"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIP" } },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["geoip:private"],     "outboundTag": "block" },
      { "type": "field", "protocol": ["bittorrent"],  "outboundTag": "block" }
    ]
  }
}
JSON
  chmod 600 "$XRAY_CONFIG"
  # Match the user the official installer runs xray as (nobody by default).
  chown nobody "$XRAY_CONFIG" 2>/dev/null || true
}

# save_meta PORT UUID PRIVKEY PUBKEY SHORTID DEST SNI ADDR NAME
save_meta() {
  install -d -m 755 "$XRAY_CONFIG_DIR"
  cat > "$XRAY_META_FILE" <<EOF
PORT=$1
UUID=$2
PRIVKEY=$3
PUBKEY=$4
SHORTID=$5
DEST=$6
SNI=$7
ADDR=$8
NAME=$9
EOF
  chmod 600 "$XRAY_META_FILE"
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

# ─────────────────────────── Share link / print ───────────────────────────
share_link() {
  local addr=$1 port=$2 uuid=$3 pub=$4 sid=$5 sni=$6 name=$7
  local host=$addr
  [[ "$addr" == *:*:* ]] && host="[$addr]"   # IPv6
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s\n' \
    "$uuid" "$host" "$port" "$sni" "$pub" "$sid" "$(printf '%s' "$name" | tr ' ' '_')"
}

print_result() {
  local link=$1
  echo
  printf '%s\n' "${G}══════════════════════════════════════════════════════════════════${N}"
  printf '%s\n' "${G} Xray VLESS-Reality 节点信息${N}"
  printf '%s\n' "${G}══════════════════════════════════════════════════════════════════${N}"
  if [[ -r "$XRAY_META_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$XRAY_META_FILE"
    printf "  %-9s %s\n" "地址"   "${ADDR:-}"
    printf "  %-9s %s\n" "端口"   "${PORT:-}"
    printf "  %-9s %s\n" "UUID"   "${UUID:-}"
    printf "  %-9s %s\n" "公钥"   "${PUBKEY:-}"
    printf "  %-9s %s\n" "短 ID"  "${SHORTID:-}"
    printf "  %-9s %s\n" "SNI"    "${SNI:-}"
    printf "  %-9s %s\n" "Flow"   "xtls-rprx-vision"
    printf "  %-9s %s\n" "指纹"   "chrome"
    echo
  fi
  printf '%s\n' "${B}── 分享链接 ─────────────────────────────────────────────────────${N}"
  printf '%s\n' "$link"
  echo
  printf '%s\n' "${B}── 二维码 ───────────────────────────────────────────────────────${N}"
  if command -v qrencode >/dev/null; then
    qrencode -t ANSIUTF8 -m 2 "$link"
  else
    printf '%s  （安装 qrencode 后重新运行可显示二维码）%s\n' "$D" "$N"
  fi
  printf '%s分享链接已保存至：%s%s\n' "$D" "$XRAY_SHARE_FILE" "$N"
}

# ─────────────────────────── Meta helpers ───────────────────────────
_reload_meta() {
  [[ -r "$XRAY_META_FILE" ]] || die "未找到节点配置（$XRAY_META_FILE），请先执行安装。"
  # shellcheck disable=SC1090
  . "$XRAY_META_FILE"
  # Backward compat: old meta files lack PRIVKEY; extract from config.json.
  if [[ -z "${PRIVKEY:-}" ]]; then
    PRIVKEY=$(grep '"privateKey"' "$XRAY_CONFIG" 2>/dev/null \
              | sed 's/.*"privateKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    [[ -n "$PRIVKEY" ]] || die "无法读取私钥，配置文件可能损坏"
  fi
}

_apply_changes() {
  write_config "$PORT" "$UUID" "$PRIVKEY" "$SHORTID" "$DEST" "$SNI"
  save_meta "$PORT" "$UUID" "$PRIVKEY" "$PUBKEY" "$SHORTID" "$DEST" "$SNI" "$ADDR" "$NAME"
  local link; link=$(share_link "$ADDR" "$PORT" "$UUID" "$PUBKEY" "$SHORTID" "$SNI" "$NAME")
  printf '%s\n' "$link" > "$XRAY_SHARE_FILE"; chmod 600 "$XRAY_SHARE_FILE"
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray \
    && ok "Xray 已重启" \
    || warn "Xray 重启后未运行，请执行 'xr logs' 查看日志"
}

# ─────────────────────────── Commands ───────────────────────────
cmd_install() {
  require_root
  if [[ -s "$XRAY_CONFIG" && -z "${FORCE:-}" ]]; then
    warn "已存在 $XRAY_CONFIG —— 跳过初始化。如需重建请先 'uninstall' 或传 FORCE=1"
    cmd_info
    return
  fi
  install_deps
  [[ -x "$XRAY_BIN" ]] || install_xray

  local port uuid keys priv pub sid dest sni addr name link
  port=$(pick_port)
  uuid=$(gen_uuid)
  keys=$(gen_keys); priv=${keys%|*}; pub=${keys#*|}
  [[ -n "$priv" && -n "$pub" ]] || die "解析 xray x25519 输出失败"
  sid=$(gen_shortid)
  dest=$(pick_dest)
  sni="$dest"

  if [[ -n "${REALITY_ADDR:-}" ]]; then
    addr="$REALITY_ADDR"
  else
    addr=$(get_public_ip)
    [[ -z "$addr" ]] && { warn "无法自动检测公网 IP，请用 REALITY_ADDR=… 指定"; addr="YOUR_SERVER"; }
  fi
  name="${REALITY_NAME:-Reality-${addr}}"

  write_config "$port" "$uuid" "$priv" "$sid" "$dest" "$sni"
  open_firewall "$port"

  systemctl enable --now xray >/dev/null
  systemctl restart xray
  sleep 1
  if ! systemctl is-active --quiet xray; then
    journalctl -u xray -n 30 --no-pager >&2 || true
    die "Xray 启动失败，请检查上方日志"
  fi
  ok "Xray 服务运行中"

  link=$(share_link "$addr" "$port" "$uuid" "$pub" "$sid" "$sni" "$name")
  save_meta "$port" "$uuid" "$priv" "$pub" "$sid" "$dest" "$sni" "$addr" "$name"
  printf '%s\n' "$link" > "$XRAY_SHARE_FILE"; chmod 600 "$XRAY_SHARE_FILE"
  _self_install || true
  print_result "$link"
}

cmd_info() {
  [[ -r "$XRAY_SHARE_FILE" ]] || die "未找到现有节点（$XRAY_SHARE_FILE）。先执行：$0 install"
  print_result "$(cat "$XRAY_SHARE_FILE")"
}

cmd_status() {
  systemctl --no-pager --full status xray 2>&1 | sed -n '1,20p'
}

cmd_logs() { journalctl -u xray -n "${1:-50}" --no-pager; }

cmd_restart() {
  require_root
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray \
    && ok "Xray 已重启" \
    || warn "Xray 重启失败，请执行 'xr logs' 查看日志"
}

cmd_update() {
  require_root
  install_xray
  systemctl restart xray
  ok "Xray 已升级并重启"
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
  local new_port
  printf "当前端口：${Y}%s${N}\n" "$PORT"
  read -r -p "新端口（留空取消）: " new_port
  [[ -z "$new_port" ]] && { msg "已取消"; return; }
  [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1 && new_port <= 65535 )) \
    || die "端口须为 1-65535 的整数"
  PORT="$new_port"
  open_firewall "$PORT"
  _apply_changes
  ok "端口已更新为 ${Y}$PORT${N}"
}

cmd_edit_uuid() {
  require_root; _reload_meta
  local old_uuid="$UUID"
  UUID=$(gen_uuid)
  _apply_changes
  ok "UUID 已重新生成"
  printf "  旧：%s\n  新：%s\n" "$old_uuid" "$UUID"
}

cmd_edit_dest() {
  require_root; _reload_meta
  printf "当前伪装目标：${Y}%s${N}\n\n候选目标：\n" "$DEST"
  local i=1
  for d in "${DEFAULT_DESTS[@]}"; do
    printf "  %d. %s\n" "$((i++))" "$d"
  done
  printf "  %d. 自定义输入\n\n" "$i"
  local choice new_dest=""
  read -r -p "输入序号或直接输入域名（留空取消）: " choice
  [[ -z "$choice" ]] && { msg "已取消"; return; }
  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    if (( choice >= 1 && choice <= ${#DEFAULT_DESTS[@]} )); then
      new_dest="${DEFAULT_DESTS[$((choice-1))]}"
    else
      read -r -p "输入自定义域名: " new_dest
    fi
  else
    new_dest="$choice"
  fi
  [[ -z "$new_dest" ]] && { msg "已取消"; return; }
  DEST="$new_dest"; SNI="$new_dest"
  _apply_changes
  ok "伪装目标已更新为 ${Y}$DEST${N}"
}

cmd_edit_name() {
  require_root; _reload_meta
  printf "当前节点名称：${Y}%s${N}\n" "$NAME"
  local new_name
  read -r -p "新名称（留空取消）: " new_name
  [[ -z "$new_name" ]] && { msg "已取消"; return; }
  NAME="$new_name"
  _apply_changes
  ok "节点名称已更新为 ${Y}$NAME${N}"
}

# ─────────────────────────── Interactive menu ───────────────────────────
cmd_menu() {
  require_root
  local choice
  while true; do
    clear
    # Header
    printf '%s╔══════════════════════════════════════════════════╗%s\n' "$B" "$N"
    printf '%s║  Xray Reality 管理脚本 %-26s║%s\n' "$B" "v${SCRIPT_VERSION}" "$N"
    printf '%s╚══════════════════════════════════════════════════╝%s\n' "$B" "$N"
    echo

    # Current node summary
    if [[ -r "$XRAY_META_FILE" ]]; then
      # shellcheck disable=SC1090
      . "$XRAY_META_FILE" 2>/dev/null || true
      local svc_str
      systemctl is-active --quiet xray 2>/dev/null \
        && svc_str="${G}● 运行中${N}" \
        || svc_str="${R}● 已停止${N}"
      printf "  节点：${Y}%s${N}   端口：${Y}%s${N}   SNI：${Y}%s${N}\n" \
        "${NAME:-—}" "${PORT:-—}" "${SNI:-—}"
      printf "  服务状态：%b\n" "$svc_str"
    else
      printf "  ${Y}未检测到节点配置，请先执行安装${N}\n"
    fi

    echo
    printf '%s  ─────── 节点管理 ────────────────────────────%s\n' "$D" "$N"
    printf '  1. 查看节点信息 + 二维码\n'
    printf '  2. 修改端口\n'
    printf '  3. 重新生成 UUID\n'
    printf '  4. 修改伪装目标 (SNI)\n'
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
    printf '  0. 退出\n'
    echo
    read -r -p "  请输入选项: " choice
    echo

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
      10) cmd_uninstall; [[ $? -eq 0 ]] && break || true ;;
      0)  break ;;
      *)  warn "无效选项，请重新输入" ;;
    esac

    if [[ "$choice" != "0" ]]; then
      echo
      read -r -p "  按 Enter 返回主菜单..." _
    fi
  done
}

# ─────────────────────────── Self install ───────────────────────────
_self_install() {
  # Works when script is run as `bash /tmp/xr.sh` (BASH_SOURCE[0] is a real file).
  # Does not work when piped via stdin — use `curl ... -o /tmp/xr.sh && bash /tmp/xr.sh`.
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
${B}${SCRIPT_NAME} v${SCRIPT_VERSION}${N}  —  贴近官方的 Xray VLESS-Reality 一键脚本

用法:
  bash $0 [install]    安装节点（默认），成功后可用 xr 管理
  bash $0 info         显示节点信息 + 分享链接 + 二维码
  bash $0 status       Xray systemd 状态
  bash $0 logs [N]     最近 N 条 Xray 日志（默认 50）
  bash $0 restart      重启 Xray
  bash $0 update       升级 Xray 到最新稳定版
  bash $0 uninstall    卸载 Xray 并清除配置
  bash $0 help         显示本帮助

安装后管理命令 (xr):
  xr               打开交互式管理菜单（含节点编辑）
  xr info          显示节点信息 + 分享链接 + 二维码
  xr status        Xray systemd 状态
  xr logs [N]      最近 N 条日志
  xr restart       重启 Xray
  xr update        升级 Xray
  xr uninstall     卸载 Xray
  xr edit-port     修改端口
  xr edit-uuid     重新生成 UUID
  xr edit-dest     修改伪装目标 (SNI)
  xr edit-name     修改节点名称

可选环境变量:
  REALITY_PORT=443                    指定端口（默认随机 30000-50000，避开占用）
  REALITY_DEST=www.apple.com          指定伪装目标（不指定则自动测速选最快）
  REALITY_ADDR=1.2.3.4 或 my.domain   分享链接里的服务器地址（默认自动获取公网 IP）
  REALITY_NAME=MyNode                 节点名称（默认 Reality-<addr>）
  XRAY_VERSION=v26.3.27               固定 Xray 版本（默认装最新）
  XRAY_INSTALLER_SHA256=<hex>         钉住官方 install-release.sh SHA256（强烈建议）
  FORCE=1                             已有配置时也重建

安全说明:
  * 底层调用 XTLS 官方 install-release.sh（自带 SHA256 dgst 校验二进制）
  * 全程 HTTPS + TLS1.2+，不写 ~/.bashrc，不安装 jq，不动 NTP
  * Xray 以 nobody 运行（官方默认），配置 600 权限
  * 分享链接中含 UUID/公钥，文件已设 600

灵感来源: github.com/XTLS/Xray-install (官方) — 避开 233boy/Xray 的几个隐患。
EOF
}

main() {
  # When invoked as `xr`, default to interactive menu; otherwise default to install.
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
