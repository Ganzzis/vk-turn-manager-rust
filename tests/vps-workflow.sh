#!/usr/bin/env bash
set -euo pipefail

mode=${1:?Specify smoke or integration}
scratch=$(mktemp -d)
chmod 700 "$scratch"
remote_dir=
opts=(-F /dev/null -i "$scratch/key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$scratch/known_hosts" -o BatchMode=yes -o ConnectTimeout=5)
target="$VPS_USER@$VPS_HOST"
remote() { ssh "${opts[@]}" "$target" "$@"; }
cleanup() {
  local result=$?
  if [[ -n $remote_dir ]]; then
    if [[ $mode == integration && $result != 0 ]]; then
      remote "if test -f '$remote_dir/cleanup-allowed'; then
        sudo -n '$remote_dir/vk-turn-manager' network disable
      fi" || echo 'Remote cleanup could not be confirmed; inspect the disposable VPS.'
    fi
    remote "rm -rf -- '$remote_dir'" || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT

test -n "$VPS_HOST" && test -n "$VPS_USER" && test -n "$VPS_SSH_KEY" && test -n "$VPS_KNOWN_HOSTS"
umask 077
printf '%s\n' "$VPS_SSH_KEY" > "$scratch/key"
printf '%s\n' "$VPS_KNOWN_HOSTS" > "$scratch/known_hosts"
# Keep the payload across reboot even if /tmp is mounted as tmpfs.
created=$(remote 'mktemp -d "$HOME/.vk-turn-ci.XXXXXXXX"')
[[ $created =~ ^/[[:alnum:]_./-]+/\.vk-turn-ci\.[[:alnum:]]{8}$ ]]
remote_dir=$created
scp "${opts[@]}" target/release/vk-turn-manager "$target:$remote_dir/vk-turn-manager"
remote "chmod 700 '$remote_dir/vk-turn-manager'"

if [[ $mode == smoke ]]; then
  remote "sudo -n '$remote_dir/vk-turn-manager' network status &&
    sudo -n '$remote_dir/vk-turn-manager' network plan"
  exit
fi
[[ $mode == integration ]]
scp "${opts[@]}" tests/network-integration.sh "$target:$remote_dir/network-integration.sh"
remote "bash '$remote_dir/network-integration.sh' prepare"
remote 'sudo -n systemctl reboot --no-block'
for ((attempt=0; attempt<72; attempt++)); do
  if remote "test \"\$(cat /proc/sys/kernel/random/boot_id)\" != \"\$(cat '$remote_dir/before-boot')\"" 2>/dev/null; then
    remote "bash '$remote_dir/network-integration.sh' finish"
    exit
  fi
  sleep 5
done
echo 'The test VPS was not reachable with a new boot ID.' >&2
exit 1
