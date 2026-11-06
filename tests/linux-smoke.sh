#!/usr/bin/env bash
# Run only on an isolated disposable Linux/systemd CI runner, as root.
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
test_work=$(mktemp -d)
trap 'systemctl stop xray >/dev/null 2>&1 || true; rm -rf "$test_work"' EXIT
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
echo 'Linux official install, permissions, rollback and repeat upgrade passed.'
