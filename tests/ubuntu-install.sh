#!/usr/bin/env bash
set -euo pipefail

manager=$(realpath "${1:?Supply the release binary path}")
scratch=$(mktemp -d)
config=$scratch/wg-vk.conf
existing=/etc/wireguard/wg-vk.conf
foreign_config=/etc/wireguard/vk-ci-foreign.conf
foreign_unit=vk-ci-foreign.service
foreign_file=/etc/systemd/system/$foreign_unit
dropin=/etc/systemd/system/vk-turn-srtp.service.d
wg_unit=vk-turn-wireguard.service
srtp_unit=vk-turn-srtp.service
created_existing=false
created_foreign_config=false
created_foreign_unit=false
created_dropin=false
installation_attempted=false

cleanup() {
  if "$installation_attempted"; then
    sudo "$manager" uninstall || true
  fi
  if "$created_dropin"; then
    sudo rm -f "$dropin/10-ci-fail.conf"
    sudo rmdir "$dropin"
  fi
  if "$created_existing"; then
    sudo rm -f "$existing"
  fi
  if "$created_foreign_unit"; then
    sudo systemctl disable --now "$foreign_unit"
    sudo rm -f "$foreign_file"
    sudo systemctl daemon-reload
  fi
  if "$created_foreign_config"; then
    sudo rm -f "$foreign_config"
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT

write_fixture() {
  sudo bash -c 'set -o noclobber; umask 022; cat > "$1"' _ "$1"
}

expect_failure() {
  local expected=$1
  shift
  if "$@" > "$scratch/failure.log" 2>&1; then
    echo "Expected failure: $expected" >&2
    exit 1
  fi
  cat "$scratch/failure.log"
  grep -Eq "$expected" "$scratch/failure.log"
  if grep -Fq 'Cleanup failed:' "$scratch/failure.log"; then
    exit 1
  fi
}

assert_removed() {
  for path in /etc/vk-turn-manager /sys/class/net/wg-vk \
    "/etc/systemd/system/$wg_unit" "/etc/systemd/system/$srtp_unit" \
    "/etc/systemd/system/multi-user.target.wants/$srtp_unit"; do
    test ! -e "$path" && test ! -L "$path" || return 1
  done
  if systemctl is-active --quiet "$wg_unit" || systemctl is-active --quiet "$srtp_unit"; then
    return 1
  fi
  test -z "$(sudo ss -Haun '( sport = :51820 or sport = :56004 )')"
}

assert_foreign_untouched() {
  sudo sha256sum --check "$scratch/foreign.sha256"
  sudo systemctl is-enabled --quiet "$foreign_unit"
  sudo systemctl is-active --quiet "$foreign_unit"
  test "$(systemctl show --property=InvocationID --value "$foreign_unit")" = "$foreign_invocation"
}

sudo apt-get update
sudo apt-get install -y --no-install-recommends wireguard-tools
sudo modprobe wireguard

(
  umask 077
  {
    printf '[Interface]\nPrivateKey = '
    wg genkey
    printf 'Address = 10.240.42.1/24\nListenPort = 51820\nTable = off\n'
  } > "$config"
)
sha256sum "$config" > "$scratch/source.sha256"

printf '%s\n' 'unrelated WireGuard config' | write_fixture "$foreign_config"
created_foreign_config=true
write_fixture "$foreign_file" <<'UNIT'
[Unit]
Description=Unrelated CI sentinel

[Service]
ExecStart=/usr/bin/sleep infinity

[Install]
WantedBy=multi-user.target
UNIT
created_foreign_unit=true
sudo systemctl daemon-reload
sudo systemctl enable --now "$foreign_unit"
foreign_invocation=$(systemctl show --property=InvocationID --value "$foreign_unit")
test -n "$foreign_invocation"
sudo sha256sum "$foreign_config" "$foreign_file" > "$scratch/foreign.sha256"

echo 'Existing WireGuard config is preserved'
printf '%s\n' 'existing configuration' | write_fixture "$existing"
created_existing=true
expect_failure "Already exists: $existing" sudo "$manager" install "$config"
printf '%s\n' 'existing configuration' | sudo cmp - "$existing"
sudo rm "$existing"
created_existing=false
assert_removed
assert_foreign_untouched

echo 'SRTP download failure rolls back the partial install'
mkdir "$scratch/bin"
cat > "$scratch/bin/curl" <<'CURL'
#!/usr/bin/env bash
# Scope the failure to the download, leaving apt and systemd untouched.
exec env HTTPS_PROXY=http://127.0.0.1:1 https_proxy=http://127.0.0.1:1 \
  NO_PROXY= no_proxy= /usr/bin/curl "$@"
CURL
chmod +x "$scratch/bin/curl"
installation_attempted=true
expect_failure 'exit status: 7\)' sudo env PATH="$scratch/bin:$PATH" "$manager" install "$config"
grep -F 'curl: (7)' "$scratch/failure.log"
assert_removed
assert_foreign_untouched

echo 'A systemd start failure rolls back the enabled unit and its running dependency'
sudo mkdir "$dropin"
created_dropin=true
write_fixture "$dropin/10-ci-fail.conf" <<'UNIT'
[Service]
ExecStartPre=/usr/bin/false
UNIT
expect_failure 'systemctl enable --now .* failed|SRTP did not bind UDP 56004' sudo "$manager" install "$config"
sudo journalctl -b -u "$srtp_unit" --no-pager | grep -F 'Failed to start'
sudo journalctl -b -u "$wg_unit" --no-pager | grep -F 'ip link add wg-vk type wireguard'
assert_removed
assert_foreign_untouched
printf '[Service]\nExecStartPre=/usr/bin/false\n' | sudo cmp - "$dropin/10-ci-fail.conf"
sudo rm "$dropin/10-ci-fail.conf"
sudo rmdir "$dropin"
created_dropin=false
sudo systemctl daemon-reload

echo 'Repeat install leaves the running services and installed files unchanged'
sudo "$manager" install "$config"
sudo "$manager" status
test "$(sudo wg show wg-vk listen-port)" = 51820
test -n "$(sudo ss -Hlun 'sport = :56004')"
test "$(sudo stat -c '%a' /etc/vk-turn-manager/wg-vk.conf)" = 600
sudo cmp "$config" /etc/vk-turn-manager/wg-vk.conf
sudo sha256sum /etc/vk-turn-manager/{wg-vk.conf,server,managed} \
  "/etc/systemd/system/$wg_unit" "/etc/systemd/system/$srtp_unit" > "$scratch/managed.sha256"
service_identity() {
  systemctl show --property=Id,InvocationID,MainPID,ActiveEnterTimestampMonotonic "$wg_unit" "$srtp_unit"
}
before=$(service_identity)
expect_failure 'Already exists: /etc/vk-turn-manager' sudo "$manager" install "$config"
test "$(service_identity)" = "$before"
sudo sha256sum --check "$scratch/managed.sha256"
sudo systemctl is-active --quiet "$wg_unit" "$srtp_unit"
assert_foreign_untouched

echo 'Uninstall and repeat uninstall preserve the source and unrelated services'
sudo "$manager" uninstall
installation_attempted=false
sudo "$manager" uninstall
assert_removed
assert_foreign_untouched
sha256sum --check "$scratch/source.sha256"
