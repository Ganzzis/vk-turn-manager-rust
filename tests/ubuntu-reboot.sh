#!/usr/bin/env bash
set -euo pipefail

manager=$(realpath "${1:?Supply the release binary path}")
scratch=$(mktemp -d)
version=${2:-24.04}
case "$version" in
  24.04) series=noble ;;
  26.04) series=resolute ;;
  *) echo 'Expected Ubuntu 24.04 or 26.04' >&2; exit 2 ;;
esac
image=ubuntu-$version-server-cloudimg-amd64.img
release=https://cloud-images.ubuntu.com/releases/$series/release
root=$(cd "$(dirname "$0")/.." && pwd)
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
  local vm_pid
  if vm_pid=$(sudo cat "$scratch/qemu.pid" 2>/dev/null) && [[ $vm_pid =~ ^[0-9]+$ ]]; then
    sudo kill "$vm_pid" 2>/dev/null || true
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT

download=(curl --fail --silent --show-error --location --retry 2 --connect-timeout 15
  --max-time 150 --retry-max-time 330 --speed-time 30 --speed-limit 10240)
echo "Downloading Ubuntu $version cloud image"
"${download[@]}" "$release/SHA256SUMS" -o "$scratch/SHA256SUMS"
"${download[@]}" "$release/$image" -o "$scratch/$image"
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
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$scratch/OVMF_VARS.fd"
sudo qemu-system-x86_64 -daemonize -pidfile "$scratch/qemu.pid" \
  -machine accel=kvm:tcg -cpu max -smp 2 -m 2048 -display none \
  -serial "file:$scratch/serial.log" \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
  -drive "if=pflash,format=raw,file=$scratch/OVMF_VARS.fd" \
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

echo "Waiting for first boot of Ubuntu $version"
before=$(wait_for_boot)
remote "cloud-init status --wait && grep -x 'VERSION_ID=\"$version\"' /etc/os-release"
if [[ -n ${VK_MANAGER_FIXTURE_BUNDLE:-} ]]; then
  # Only the ephemeral localhost VM uses these synthetic login credentials.
  scp "${ssh_opts[@]}" -P "$port" "$root/tests/network-dataplane.sh" ubuntu@127.0.0.1:~/network-dataplane.sh
  password=$(openssl rand -hex 24)
  {
    printf 'password=%s\n' "$password"
    cat <<'FIXTURE'
printf "ubuntu:%s\nroot:%s\n" "$password" "$password" | chpasswd
printf 'PasswordAuthentication yes\nPermitRootLogin yes\nHostKey /etc/ssh/ssh_host_ed25519_key\n' > /etc/ssh/sshd_config.d/00-vk-ci.conf
# A non-interactive login may write a message before SSH command output.
# Exercise noisy command sessions without injecting bytes into the SFTP protocol.
sed -i '1i case "$BASH_EXECUTION_STRING" in */sftp-server*) ;; *) echo "synthetic shell banner";; esac' /root/.bashrc
systemctl reload ssh
printf 'ubuntu ALL=(ALL) ALL\n' > /etc/sudoers.d/91-vk-ci
chmod 0440 /etc/sudoers.d/91-vk-ci
rm -f /etc/sudoers.d/90-cloud-init-users
FIXTURE
  } | remote 'sudo -n /bin/bash -se'
  pin=$(remote 'cat /etc/ssh/ssh_host_ed25519_key.pub' | ssh-keygen -lf - | awk 'NR==1 {print $2}')
  if ! VK_MANAGER_FIXTURE_PORT="$port" VK_MANAGER_FIXTURE_PASSWORD="$password" VK_MANAGER_FIXTURE_PIN="$pin" \
    VK_MANAGER_FIXTURE_KEY="$scratch/id_ed25519" swift test --package-path "$root/ios-manager" --filter testDisposableUbuntuOverSSH; then
    printf '%s\n' "$password" | remote 'sudo -S -p "" journalctl -u ssh -n 25 --no-pager' || true
    exit 1
  fi
  exit 0
fi

cli_version=$("$manager" --version)
archive="vk-turn-manager-v${cli_version##* }-linux-amd64"
mkdir "$scratch/$archive"
install -m 0755 "$manager" "$scratch/$archive/vk-turn-manager"
tar -czf "$scratch/$archive.tar.gz" -C "$scratch" "$archive"
(cd "$scratch" && sha256sum "$archive.tar.gz" > SHA256SUMS)
scp "${ssh_opts[@]}" -P "$port" "$scratch/$archive.tar.gz" "$scratch/SHA256SUMS" "$root/install.sh" \
  "$root/tests/network-integration.sh" "$root/tests/network-dataplane.sh" "$root/tests/client-lifecycle.sh" ubuntu@127.0.0.1:~/
remote 'bash -se' <<'GUEST'
sudo bash install.sh install v0.3.0 "$PWD"
ln -s /usr/local/bin/vk-turn-manager vk-turn-manager
sudo ./vk-turn-manager status
sudo ./vk-turn-manager connections
sudo ./vk-turn-manager logs
sudo systemctl is-enabled --quiet vk-turn-srtp.service
sudo systemctl is-active --quiet vk-turn-network.service
sudo ./vk-turn-manager network disable
sudo sysctl -q -w net.ipv4.ip_forward=0
sudo apt-get install -y --no-install-recommends zbar-tools

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
WG_TEST_NETWORK=10.77.0 WG_TEST_QR=1 bash client-lifecycle.sh prepare

wg_invocation=$(systemctl show -p InvocationID --value vk-turn-wireguard.service)
sudo sha256sum /etc/vk-turn-manager/wg-vk.conf /var/lib/vk-turn-clients/ci-alpha > before-update.sha256
sudo bash install.sh update v0.3.0 "$PWD"
sudo sha256sum --status -c before-update.sha256
test "$(systemctl show -p InvocationID --value vk-turn-wireguard.service)" = "$wg_invocation"

mkdir update-fixture
cat > update-fixture/systemctl <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
if [[ $* == 'restart vk-turn-srtp.service' && ! -e $VK_RESTART_FIXTURE ]]; then
  touch "$VK_RESTART_FIXTURE"
  exit 42
fi
exec /usr/bin/systemctl "$@"
WRAPPER
chmod 0755 update-fixture/systemctl
server=/etc/vk-turn-manager/server
before=$(stat -c %i "$server")
if sudo env "PATH=$PWD/update-fixture:$PATH" "VK_RESTART_FIXTURE=$PWD/update-fixture/failed" ./vk-turn-manager reinstall; then
  echo 'Injected SRTP restart failure was ignored.' >&2
  exit 1
fi
sudo test -f update-fixture/failed
test "$(stat -c %i "$server")" = "$before"
sudo sha256sum --status -c before-update.sha256
sudo systemctl is-active --quiet vk-turn-srtp.service
printf '3\n0\n' | sudo ./vk-turn-manager menu | grep 'ci-alpha'

GUEST

echo "Rebooting Ubuntu VM, original boot ID: $before"
# Flush the disposable guest's disk and reboot without waiting for unrelated
# cloud-image services to shut down. The new boot ID still verifies a real reboot.
remote 'sudo sync && sudo systemctl reboot --force --no-block' || [[ $? == 255 ]]
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

echo "Verifying WireGuard traffic and client revocation after reboot"
remote 'timeout 90s bash client-lifecycle.sh finish'
echo "Verifying NAT persistence and uninstall"
remote 'timeout 90s bash network-integration.sh finish && sudo systemctl is-active --quiet vkturn-nft.service'
remote 'sudo ./vk-turn-manager network enable && sudo ./vk-turn-manager uninstall &&
  sudo test ! -e /etc/vk-turn-network && sudo systemctl is-active --quiet vkturn-nft.service &&
  sudo nft list table ip vkturn >/dev/null'
