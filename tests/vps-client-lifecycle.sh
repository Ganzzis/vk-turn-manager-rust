#!/usr/bin/env bash
# Manually gated, disposable VPS only. No reboot or firewall changes here.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
binary=$PWD/vk-turn-manager
name="ci-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
client() { sudo -n "$binary" client "$@"; }
created=false
cleanup() {
  if "$created"; then
    client remove "$name" >/dev/null || echo "Temporary client $name needs manual revocation." >&2
  fi
  sudo -n rm -f "$PWD/test.conf"
}
trap cleanup EXIT

for path in /etc/vk-turn-manager/wg-vk.conf /etc/wireguard/wg-vk.conf; do
  if sudo -n test -f "$path"; then
    sudo -n sha256sum "$path"
  fi
done > config-before
[[ $(wc -l < config-before) == 1 ]]
sudo -n wg show wg-vk allowed-ips | sort > peers-before
client list > clients-before
client add "$name" > added.json
created=true
client export "$name" --wg-endpoint 192.0.2.1:51820 --output "$PWD/test.conf" >/dev/null
[[ $(sudo -n stat -c %a "$PWD/test.conf") == 600 ]]
peer=$(python3 -c 'import json; print(json.load(open("added.json"))["public_key"])')
sudo -n wg show wg-vk peers | grep -Fxq "$peer"
client remove "$name" >/dev/null
created=false
client list | cmp -s - clients-before
sudo -n wg show wg-vk allowed-ips | sort | cmp -s - peers-before
sudo -n sha256sum --status -c config-before
echo 'Temporary peer created, exported and revoked. Existing peers and configuration are unchanged.'
