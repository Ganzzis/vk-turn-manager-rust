#!/usr/bin/env bash
set -euo pipefail

manager=$(realpath "${1:?Supply the release binary path}")
scratch=$(mktemp -d)
image=noble-server-cloudimg-amd64.img
release=https://cloud-images.ubuntu.com/noble/current
port=2222
ssh_opts=(-i "$scratch/id_ed25519" -o BatchMode=yes -o ConnectTimeout=5
  -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$scratch/known_hosts")
remote() {
  ssh "${ssh_opts[@]}" -p "$port" ubuntu@127.0.0.1 "$@"
}

cleanup() {
  local result=$?
  if (( result != 0 )) && [[ -f $scratch/serial.log ]]; then
    tail -n 100 "$scratch/serial.log"
  fi
  if [[ -n ${http_pid:-} ]]; then
    kill "$http_pid" 2>/dev/null || true
  fi
  if [[ -s $scratch/qemu.pid ]]; then
    sudo kill "$(cat "$scratch/qemu.pid")" 2>/dev/null || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT

curl --fail --silent --show-error --location --retry 2 "$release/SHA256SUMS" -o "$scratch/SHA256SUMS"
curl --fail --silent --show-error --location --retry 2 "$release/$image" -o "$scratch/$image"
(
  cd "$scratch"
  awk -v target="$image" '{name=$2; sub(/^\*/, "", name); if (name==target) print $1 "  " target}' SHA256SUMS |
    sha256sum --check
  qemu-img resize "$image" 10G
)

ssh-keygen -q -t ed25519 -N '' -f "$scratch/id_ed25519"
{
  printf '#cloud-config\nssh_pwauth: false\nssh_authorized_keys:\n  - '
  cat "$scratch/id_ed25519.pub"
} > "$scratch/user-data"
printf 'instance-id: vk-turn-reboot\nlocal-hostname: vk-turn-reboot\n' > "$scratch/meta-data"
cloud-localds "$scratch/seed.img" "$scratch/user-data" "$scratch/meta-data"

mkdir "$scratch/http"
printf '%s\n' 'vk-turn-manager-nat-probe' > "$scratch/http/nat-probe"
python3 -m http.server 18080 --bind 127.0.0.1 --directory "$scratch/http" > "$scratch/http.log" 2>&1 &
http_pid=$!
touch "$scratch/serial.log"
sudo qemu-system-x86_64 -daemonize -pidfile "$scratch/qemu.pid" \
  -machine accel=kvm:tcg -cpu max -smp 2 -m 2048 -display none \
  -serial "file:$scratch/serial.log" \
  -drive "if=virtio,format=qcow2,file=$scratch/$image" \
  -drive "if=virtio,format=raw,readonly=on,file=$scratch/seed.img" \
  -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$port-:22"

wait_for_boot() {
  local previous=${1:-} boot
  for ((attempt=0; attempt<90; attempt++)); do
    if boot=$(remote cat /proc/sys/kernel/random/boot_id 2>/dev/null) \
      && [[ -n $boot && $boot != "$previous" ]]; then
      printf '%s\n' "$boot"
      return 0
    fi
    sleep 5
  done
  echo 'Timed out waiting for a new VM boot ID' >&2
  return 1
}

before=$(wait_for_boot)
remote 'cloud-init status --wait && grep -x VERSION_ID=\"24.04\" /etc/os-release'
scp "${ssh_opts[@]}" -P "$port" "$manager" ubuntu@127.0.0.1:vk-turn-manager
scp "${ssh_opts[@]}" -P "$port" "$(dirname "$0")/network-integration.sh"   "$(dirname "$0")/network-dataplane.sh" ubuntu@127.0.0.1:~/
remote 'bash -se' <<'GUEST'
sudo apt-get update
sudo apt-get install -y --no-install-recommends wireguard-tools nftables
sudo modprobe wireguard
umask 077
{
  printf '[Interface]\nPrivateKey = '
  wg genkey
  printf 'Address = 10.240.42.1/24\nListenPort = 51820\nTable = off\n'
} > wg-vk.conf
chmod +x vk-turn-manager
sudo ./vk-turn-manager install wg-vk.conf
sudo ./vk-turn-manager status
sudo systemctl is-enabled --quiet vk-turn-srtp.service

# Test VM only: a persistent legacy table with its own forwarding hook.
sudo tee /etc/vk-ci-legacy.nft >/dev/null <<'RULES'
table ip vkturn {
  chain foreign_forward {
    type filter hook forward priority 10; policy accept;
  }
}
RULES
sudo tee /etc/systemd/system/vkturn-nft.service >/dev/null <<'UNIT'
[Unit]
Description=Legacy table fixture

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/vk-ci-legacy.nft

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now vkturn-nft.service
bash network-integration.sh prepare
GUEST

echo "Rebooting Ubuntu VM, original boot ID: $before"
remote 'sudo systemctl reboot --no-block'
after=$(wait_for_boot "$before")
echo "Ubuntu VM rebooted, new boot ID: $after"

remote 'bash -se' <<'GUEST'
# SSH can be reachable before the two services finish starting at boot.
for ((attempt=0; attempt<60; attempt++)); do
  if systemctl is-active --quiet vk-turn-wireguard.service &&
    systemctl is-active --quiet vk-turn-srtp.service &&
    [[ $(sudo wg show wg-vk listen-port 2>/dev/null) == 51820 ]] &&
    [[ -n $(sudo ss -Hlun 'sport = :56004') ]]; then
    sudo ./vk-turn-manager status
    exit 0
  fi
  sleep 2
done
sudo journalctl -b -u vk-turn-wireguard.service -u vk-turn-srtp.service --no-pager
exit 1
GUEST

remote 'bash network-dataplane.sh && bash network-integration.sh finish && sudo systemctl is-active --quiet vkturn-nft.service'
remote 'sudo ./vk-turn-manager network enable && sudo ./vk-turn-manager uninstall &&
  sudo test ! -e /etc/vk-turn-network && sudo systemctl is-active --quiet vkturn-nft.service &&
  sudo nft list table ip vkturn >/dev/null'
