#!/usr/bin/env bash
# Run only inside the disposable QEMU VM. The HTTP peer is on the QEMU host.
set -euo pipefail
umask 077
scratch=$(mktemp -d)
root_scratch=
ns=vk-ci-client
server_link=vk-ci-host
cleanup() {
  if [[ -n ${client_public:-} ]]; then
    sudo wg set wg-vk peer "$client_public" remove
  fi
  sudo ip link delete "$server_link" 2>/dev/null || true
  sudo ip netns delete "$ns" 2>/dev/null || true
  if [[ -n $root_scratch ]]; then sudo rm -rf -- "$root_scratch"; fi
  rm -rf "$scratch"
}
trap cleanup EXIT

if [[ -n ${WG_CLIENT_CONF:-} ]]; then
  sudo awk -F ' = ' '$1 == "PrivateKey" { print $2 }' "$WG_CLIENT_CONF" > "$scratch/client.key"
  server_public=$(sudo awk -F ' = ' '$1 == "PublicKey" { print $2 }' "$WG_CLIENT_CONF")
  client_address=$(sudo awk -F ' = ' '$1 == "Address" { print $2 }' "$WG_CLIENT_CONF")
  endpoint=$(sudo awk -F ' = ' '$1 == "Endpoint" { print $2 }' "$WG_CLIENT_CONF")
else
  wg genkey > "$scratch/client.key"
  client_public=$(wg pubkey < "$scratch/client.key")
  server_public=$(sudo wg show wg-vk public-key)
  client_address=10.240.42.2/32
  endpoint=192.0.2.1:51820
  sudo wg set wg-vk peer "$client_public" allowed-ips "$client_address"
fi
sudo ip netns add "$ns"
sudo ip link add "$server_link" type veth peer name vk-ci-peer netns "$ns"
sudo ip address add 192.0.2.1/30 dev "$server_link"
sudo ip link set "$server_link" up
sudo ip -n "$ns" address add 192.0.2.2/30 dev vk-ci-peer
sudo ip -n "$ns" link set vk-ci-peer up
sudo ip -n "$ns" link set lo up

# Use the same wg-quick configuration path as the server, including its
# handling of private key input on Ubuntu 26.04.
{
  printf '[Interface]\nPrivateKey = '
  tr -d '\n' < "$scratch/client.key"
  printf '\nAddress = %s\nTable = off\n' "$client_address"
  printf '[Peer]\nPublicKey = %s\nAllowedIPs = 10.0.2.2/32\nEndpoint = %s\n' "$server_public" "$endpoint"
} > "$scratch/vk-ci-wg.conf"
root_scratch=$(sudo mktemp -d /run/vk-ci-wireguard.XXXXXXXX)
sudo install -m 0600 "$scratch/vk-ci-wg.conf" "$root_scratch/vk-ci-wg.conf"
sudo nsenter --net="/run/netns/$ns" -- /bin/bash /usr/bin/wg-quick up "$root_scratch/vk-ci-wg.conf"
sudo ip -n "$ns" route add 10.0.2.2/32 dev vk-ci-wg
if [[ ${WG_EXPECT_DENIED:-0} == 1 ]]; then
  if sudo nsenter --net="/run/netns/$ns" -- curl --noproxy '*' --fail --silent \
    --connect-timeout 3 --max-time 5 http://10.0.2.2:18080/nat-probe >/dev/null; then
    echo 'Revoked WireGuard client still reached the HTTP peer.' >&2
    exit 1
  fi
  echo 'Revoked WireGuard client could no longer reach the HTTP peer.'
  exit 0
fi
reply=$(sudo nsenter --net="/run/netns/$ns" -- curl --noproxy '*' --fail --silent --show-error \
  --connect-timeout 10 --max-time 20 http://10.0.2.2:18080/nat-probe)
[[ $reply == 'vk-turn-manager-nat-probe' ]]
sudo nft list chain ip vk_turn_manager postrouting | grep -E 'counter packets [1-9][0-9]* bytes .* masquerade'
echo 'Isolated WireGuard client reached the HTTP peer through managed NAT.'
