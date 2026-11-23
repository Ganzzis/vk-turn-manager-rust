#!/usr/bin/env bash
set -euo pipefail

manager=$(realpath "${1:?Supply the release binary path}")
config=$(mktemp)
existing=/etc/wireguard/wg-vk.conf
created_existing=false
installation_attempted=false

cleanup() {
  if "$installation_attempted"; then
    sudo "$manager" uninstall || true
  fi
  if "$created_existing"; then
    sudo rm -f "$existing"
  fi
  rm -f "$config"
}
trap cleanup EXIT

sudo apt-get update
sudo apt-get install -y --no-install-recommends wireguard-tools
sudo modprobe wireguard

{
  printf '[Interface]\nPrivateKey = '
  wg genkey
  printf 'Address = 10.240.42.1/24\nListenPort = 51820\nTable = off\n'
} > "$config"

# Reserve the conventional path without overwriting a config on the runner.
sudo bash -c 'set -o noclobber; umask 077; printf "%s\n" "existing configuration" > "$1"' _ "$existing"
created_existing=true
if sudo "$manager" install "$config" > /tmp/vk-turn-conflict.log 2>&1; then
  installation_attempted=true
  echo "Install unexpectedly accepted an existing WireGuard config" >&2
  exit 1
fi
grep -F "Already exists: $existing" /tmp/vk-turn-conflict.log
printf '%s\n' 'existing configuration' | sudo cmp - "$existing"
sudo rm "$existing"
created_existing=false

installation_attempted=true
sudo "$manager" install "$config"
sudo "$manager" status
test "$(sudo wg show wg-vk listen-port)" = 51820
test -n "$(sudo ss -Hlun 'sport = :56004')"
test "$(sudo stat -c '%a' /etc/vk-turn-manager/wg-vk.conf)" = 600
sudo cmp "$config" /etc/vk-turn-manager/wg-vk.conf
sudo "$manager" uninstall
installation_attempted=false
sudo "$manager" uninstall
test -s "$config"
test ! -e /etc/vk-turn-manager
test ! -e /sys/class/net/wg-vk
test ! -e /etc/systemd/system/vk-turn-wireguard.service
test ! -e /etc/systemd/system/vk-turn-srtp.service
test ! -e /etc/systemd/system/multi-user.target.wants/vk-turn-srtp.service
test -z "$(sudo ss -Hlun 'sport = :56004')"
