#!/usr/bin/env bash
set -euo pipefail

phase=${1:?Specify prepare or finish}
cd "$(dirname "$0")"
manager=$PWD/vk-turn-manager
unit=vk-turn-network.service
state=/etc/vk-turn-network
unit_path=/etc/systemd/system/$unit
enabled=/etc/systemd/system/multi-user.target.wants/$unit
dropin=$unit_path.d

network() { sudo -n "$manager" network "$@"; }
forwarding() { cat /proc/sys/net/ipv4/ip_forward; }
foreign_rules() {
  local rules
  rules=$(sudo -n nft -s list ruleset)
  awk '
    /^table / { owned = ($0 == "table ip vk_turn_manager {") }
    !owned { print }
  ' <<< "$rules"
}
unchanged() {
  foreign_rules > actual-nft
  if ! cmp -s foreign-nft actual-nft; then
    echo 'Non-managed nftables rules changed' >&2
    return 1
  fi
}
assert_clean() {
  local tables path
  tables=$(sudo -n nft list tables)
  if grep -qx 'table ip vk_turn_manager' <<< "$tables"; then
    echo 'Managed nftables table still present' >&2
    return 1
  fi
  for path in "$state" "$unit_path" "$enabled"; do
    sudo -n test ! -e "$path"
    sudo -n test ! -L "$path"
  done
  if systemctl is-active --quiet "$unit"; then
    echo 'Managed service still active' >&2
    return 1
  fi
}
assert_enabled() {
  sudo -n systemctl is-active --quiet "$unit"
  sudo -n systemctl is-enabled --quiet "$unit"
  sudo -n nft list table ip vk_turn_manager >/dev/null
  [[ $(forwarding) == 1 ]]
}
repeat_enable() {
  local before
  before=$(systemctl show --property=InvocationID --value "$unit")
  test -n "$before"
  network enable
  [[ $(systemctl show --property=InvocationID --value "$unit") == "$before" ]]
  assert_enabled
  unchanged
}

case "$phase" in
  prepare)
    assert_clean
    network plan
    touch cleanup-allowed
    foreign_rules > foreign-nft
    forwarding > baseline-forwarding
    cat /proc/sys/kernel/random/boot_id > before-boot

    # Fail after both ExecStart commands, so rollback must remove a loaded table
    # and restore the original runtime forwarding value.
    sudo -n mkdir "$dropin"
    trap 'sudo -n rm -f "$dropin/90-test-failure.conf"; sudo -n rmdir "$dropin"; sudo -n systemctl daemon-reload' EXIT
    printf '[Service]\nExecStartPost=/usr/bin/false\n' | sudo -n tee "$dropin/90-test-failure.conf" >/dev/null
    if network enable; then
      echo 'Fault injection did not cause network enable to fail' >&2
      exit 1
    fi
    assert_clean
    [[ $(forwarding) == "$(cat baseline-forwarding)" ]]
    unchanged
    sudo -n test -f "$dropin/90-test-failure.conf"
    sudo -n rm "$dropin/90-test-failure.conf"
    sudo -n rmdir "$dropin"
    trap - EXIT
    sudo -n systemctl daemon-reload
    echo 'Rollback restored forwarding and preserved foreign nftables rules.'

    network enable
    assert_enabled
    repeat_enable
    echo 'Managed NAT is ready for reboot.'
    ;;
  finish)
    [[ $(cat /proc/sys/kernel/random/boot_id) != "$(cat before-boot)" ]]
    for ((i=0; i<60; i++)); do
      if systemctl is-active --quiet "$unit"; then
        break
      fi
      sleep 2
    done
    assert_enabled
    unchanged
    repeat_enable
    echo 'Managed NAT and forwarding survived reboot.'
    network disable
    assert_clean
    network disable
    assert_clean
    unchanged
    [[ $(forwarding) == 1 ]]
    network enable
    assert_enabled
    network disable
    assert_clean
    unchanged
    echo 'Repeat disable and re-enable preserved all foreign nftables rules.'
    ;;
  *) exit 2 ;;
esac
