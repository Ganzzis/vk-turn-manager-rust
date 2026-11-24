#!/usr/bin/env bash
set -euo pipefail

binary=${1:?Specify the release binary}
[[ $MANAGER_SHA256 =~ ^[a-f0-9]{64}$ ]]
[[ $VPS_USER =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]]
[[ $VPS_HOST =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]*$ || $VPS_HOST =~ ^::[a-fA-F0-9:]+$ ]]
[[ -n $VPS_SSH_KEY && -n $VPS_KNOWN_HOSTS ]]

umask 077
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$VPS_SSH_KEY" > "$scratch/key"
printf '%s\n' "$VPS_KNOWN_HOSTS" > "$scratch/known_hosts"
unset VPS_SSH_KEY VPS_KNOWN_HOSTS

# Quote the checked-in script for the login shell. SSH stdin carries only the binary.
script=$(cat -- "$(dirname -- "${BASH_SOURCE[0]}")/deploy-manager-install.sh")
script=${script//\'/\'\\\'\'}
ssh -T -F /dev/null -i "$scratch/key" \
  -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o "UserKnownHostsFile=$scratch/known_hosts" -o GlobalKnownHostsFile=/dev/null \
  -o UpdateHostKeys=no -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
  -- "$VPS_USER@$VPS_HOST" \
  "sudo -n -u root -g root -- /bin/bash -c '$script' deploy-manager /usr/local/bin '$MANAGER_SHA256'" \
  < "$binary"
