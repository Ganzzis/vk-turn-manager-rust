#!/usr/bin/env bash
# Run only inside the disposable QEMU VM. The HTTP peer is on the QEMU host.
set -euo pipefail
umask 077
scratch=$(mktemp -d)
ns=vk-ci-client
server_link=vk-ci-host
cleanup() {
  if [[ -n ${client_public:-} ]]; then
    sudo wg set wg-vk peer "$client_public" remove
  fi
  sudo ip link delete "$server_link" 2>/dev/null || true
  sudo ip netns delete "$ns" 2>/dev/null || true
  rm -rf "$scratch"
}
trap cleanup EXIT

wg genkey > "$scratch/client.key"
client_public=$(wg pubkey < "$scratch/client.key")
server_public=$(sudo wg show wg-vk public-key)
sudo wg set wg-vk peer "$client_public" allowed-ips 10.240.42.2/32
sudo ip netns add "$ns"
sudo ip link add "$server_link" type veth peer name vk-ci-peer netns "$ns"
sudo ip address add 192.0.2.1/30 dev "$server_link"
sudo ip link set "$server_link" up
sudo ip -n "$ns" address add 192.0.2.2/30 dev vk-ci-peer
sudo ip -n "$ns" link set vk-ci-peer up
sudo ip -n "$ns" link set lo up

sudo ip -n "$ns" link add vk-ci-wg type wireguard
sudo ip netns exec "$ns" wg set vk-ci-wg private-key "$scratch/client.key" \
  peer "$server_public" allowed-ips 10.0.2.2/32 endpoint 192.0.2.1:51820
sudo ip -n "$ns" address add 10.240.42.2/32 dev vk-ci-wg
sudo ip -n "$ns" link set vk-ci-wg up
sudo ip -n "$ns" route add 10.0.2.2/32 dev vk-ci-wg
reply=$(sudo ip netns exec "$ns" curl --noproxy '*' --fail --silent --show-error \
  --connect-timeout 10 --max-time 20 http://10.0.2.2:18080/nat-probe)
[[ $reply == 'vk-turn-manager-nat-probe' ]]
sudo nft list chain ip vk_turn_manager postrouting | grep -E 'counter packets [1-9][0-9]* bytes .* masquerade'
echo 'Isolated WireGuard client reached the HTTP peer through managed NAT.'
