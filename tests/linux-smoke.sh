#!/usr/bin/env bash
# Run only on an isolated disposable Linux/systemd CI runner, as root.
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_work=$(mktemp -d)
client_pid=""
trap '[[ -z "$client_pid" ]] || kill "$client_pid" 2>/dev/null || true; systemctl stop xray >/dev/null 2>&1 || true; rm -rf "$test_work"' EXIT
export XRAY_VERSION=v26.10.31 ENABLE_BBR=0
export PROTOCOL=vless-reality REALITY_PORT=44443
export REALITY_DEST=www.microsoft.com REALITY_ADDR=203.0.113.10
# Intentional literal command substitution exercises safe metadata handling.
# shellcheck disable=SC2016
export REALITY_NAME='CI node "quoted" # & $(literal)'

if ! bash "$repo/xray-reality.sh" install > "$test_work/install.log" 2>&1; then
  cat "$test_work/install.log"; exit 1
fi
systemctl is-active --quiet xray
[[ $(systemctl show xray -p User --value) == xray ]]
[[ $(stat -c '%U:%G:%a' /usr/local/etc/xray/config.json) == root:xray:640 ]]
[[ $(stat -c '%U:%G:%a' /usr/local/etc/xray/.meta.env) == root:root:600 ]]
runuser -u xray -- /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
if runuser -u xray -- test -w /usr/local/etc/xray/config.json; then
  echo 'Service user must not be able to modify its configuration'; exit 1
fi
ss -tlnH 'sport = :44443' | grep -q .

# An actual REALITY/Vision client must fetch public HTTPS through this node.
python3 - "$test_work/client.json" <<'PY'
import json, sys
d=json.load(open('/usr/local/etc/xray/.meta.env'))
c={'log':{'loglevel':'warning'},'inbounds':[{'listen':'127.0.0.1','port':10808,'protocol':'socks','settings':{'auth':'noauth'}}],
   'outbounds':[{'protocol':'vless','settings':{'vnext':[{'address':'127.0.0.1','port':int(d['PORT']),'users':[{'id':d['UUID'],'encryption':'none','flow':'xtls-rprx-vision'}]}]},
   'streamSettings':{'network':'raw','security':'reality','realitySettings':{'fingerprint':'chrome','serverName':d['SNI'],'password':d['PUBKEY'],'shortId':d['SHORTID']}}}]}
with open(sys.argv[1],'w') as f: json.dump(c,f)
PY
/usr/local/bin/xray run -config "$test_work/client.json" > "$test_work/client.log" 2>&1 &
client_pid=$!
sleep 1
if ! curl -q --fail --silent --show-error --socks5-hostname 127.0.0.1:10808 \
  --connect-timeout 15 --max-time 45 https://example.com -o "$test_work/page.html"; then
  cat "$test_work/client.log"
  journalctl -u xray -n 30 --no-pager
  exit 1
fi
grep -q 'Example Domain' "$test_work/page.html"
kill "$client_pid"; wait "$client_pid" || true; client_pid=""

cp /usr/local/etc/xray/.meta.env "$test_work/old-meta"
sha256sum /usr/local/bin/xray /usr/local/etc/xray/config.json \
  /etc/systemd/system/xray.service > "$test_work/before.sha"

# Exercise rollback after the new official binary and service have been installed.
if bash -c 'source "$1/xray-reality.sh"; restart_checked() { die "intentional CI restart failure"; }; cmd_update' \
  _ "$repo" > "$test_work/failure.log" 2>&1; then
  echo 'Injected update failure unexpectedly succeeded'; exit 1
fi
grep -q 'intentional CI restart failure' "$test_work/failure.log"
sha256sum -c "$test_work/before.sha"
cmp "$test_work/old-meta" /usr/local/etc/xray/.meta.env
systemctl is-active --quiet xray

# A normal repeat install upgrades without regenerating UUID or private key.
if ! bash "$repo/xray-reality.sh" install > "$test_work/update.log" 2>&1; then
  cat "$test_work/update.log"; exit 1
fi
cmp "$test_work/old-meta" /usr/local/etc/xray/.meta.env
systemctl is-active --quiet xray
echo 'Linux official install, REALITY HTTPS proxy, permissions, rollback and repeat upgrade passed.'
