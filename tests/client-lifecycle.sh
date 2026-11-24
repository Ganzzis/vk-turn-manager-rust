#!/usr/bin/env bash
# VM-only fault injection and synthetic peers. Keep all key material off stdout.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
binary=$PWD/vk-turn-manager
scratch=$PWD/.client-test
config=/etc/vk-turn-manager/wg-vk.conf
network=${WG_TEST_NETWORK:-10.240.42}
client() { sudo -n "$binary" client "$@"; }

case "${1:?prepare or finish}" in
  prepare)
    mkdir "$scratch"
    sudo wg genkey | wg pubkey > "$scratch/unmanaged.pub"
    pub=$(cat "$scratch/unmanaged.pub")
    printf '\n[Peer]\n# Synthetic unmanaged peer\nPublicKey = %s\nAllowedIPs = %s.2/31\n' "$pub" "$network" |
      sudo tee -a "$config" >/dev/null
    sudo wg set wg-vk peer "$pub" allowed-ips "$network.2/31"
    sudo sha256sum "$config" > "$scratch/baseline"
    sudo wg show wg-vk allowed-ips > "$scratch/runtime-baseline"

    # A file bind mount allows staging but makes the final rename fail after
    # the real kernel peer has been added.
    sudo mount --bind "$config" "$config"
    trap 'sudo umount "$config"' EXIT
    if client add write-failure > "$scratch/error" 2>&1; then
      echo 'Expected a write failure' >&2
      exit 1
    fi
    grep -q 'Device or resource busy' "$scratch/error"
    sudo umount "$config"
    trap - EXIT
    sudo sha256sum --status -c "$scratch/baseline"
    sudo wg show wg-vk allowed-ips | cmp -s - "$scratch/runtime-baseline"
    sudo test ! -e /var/lib/vk-turn-clients/write-failure
    echo 'Atomic config write failure rolled back the real runtime peer.'

    # Simulate a runtime command reporting failure after the netlink mutation.
    mkdir "$scratch/bin"
    cat > "$scratch/bin/wg" <<'WG'
#!/usr/bin/env bash
set -euo pipefail
/usr/bin/wg "$@"
if [[ ${1:-} == set && ${5:-} == allowed-ips ]]; then
  exit 42
fi
WG
    chmod 700 "$scratch/bin/wg"
    if sudo env PATH="$scratch/bin:$PATH" "$binary" client add runtime-failure > "$scratch/error" 2>&1; then
      echo 'Expected a WireGuard runtime failure' >&2
      exit 1
    fi
    grep -q 'wg set failed (exit status: 42)' "$scratch/error"
    sudo sha256sum --status -c "$scratch/baseline"
    sudo wg show wg-vk allowed-ips | cmp -s - "$scratch/runtime-baseline"
    sudo test ! -e /var/lib/vk-turn-clients/runtime-failure
    echo 'Partial runtime failure rolled back with the persistent config unchanged.'

    wg genkey | wg pubkey > "$scratch/runtime-only.pub"
    runtime_only=$(cat "$scratch/runtime-only.pub")
    sudo wg set wg-vk peer "$runtime_only" allowed-ips "$network.4/32"

    client add ci-alpha > "$scratch/alpha.json" &
    alpha=$!
    client add ci-beta > "$scratch/beta.json" &
    beta=$!
    wait "$alpha"
    wait "$beta"
    if client add ci-alpha > "$scratch/error" 2>&1; then
      echo 'Duplicate client name was accepted' >&2
      exit 1
    fi
    grep -q 'Client name already exists' "$scratch/error"
    client list > "$scratch/list.json"
    python3 - "$scratch/list.json" "$network" <<'PY'
import json, sys
with open(sys.argv[1]) as f: peers = json.load(f)
assert {peer['name'] for peer in peers} == {'ci-alpha', 'ci-beta'}
assert {peer['ipv4'] for peer in peers} == {f'{sys.argv[2]}.5', f'{sys.argv[2]}.6'}
assert all(set(peer) == {'name', 'ipv4', 'public_key'} for peer in peers)
PY
    sudo wg set wg-vk peer "$runtime_only" remove
    client export ci-alpha --wg-endpoint 192.0.2.1:51820 --output "$scratch/client.conf" >/dev/null
    printf 'https://vk.ru/call/join/synthetic\n' > "$scratch/join"
    client export ci-alpha --srtp-endpoint 192.0.2.1:56004 --vk-link-file "$scratch/join" --output "$scratch/import.url" >/dev/null
    test "$(sudo stat -c %a "$scratch/client.conf")" = 600
    test "$(sudo stat -c %a "$scratch/import.url")" = 600
    sudo python3 - "$scratch/import.url" <<'PY'
import base64, json, sys
with open(sys.argv[1]) as f: url = f.read().strip()
prefix = 'vkturnproxy://import?data='
if not url.startswith(prefix):
    raise SystemExit('Unexpected import URL scheme')
encoded = url[len(prefix):]
p = json.loads(base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4)))
assert p['version'] == 1 and p['type'] == 'connection'
assert p['settings']['peerAddress'] == '192.0.2.1:56004' and p['settings']['useSrtp'] is True
PY
    if [[ ${WG_TEST_QR:-0} == 1 ]]; then
      client qr "$scratch/import.url" --output "$scratch/import.png" >/dev/null
      test "$(sudo stat -c %a "$scratch/import.png")" = 600
      sudo zbarimg --quiet --raw "$scratch/import.png" > "$scratch/decoded"
      sudo python3 - "$scratch/import.url" "$scratch/decoded" <<'PY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_bytes().rstrip(b"\n") == Path(sys.argv[2]).read_bytes().rstrip(b"\n")
PY
      if client qr "$scratch/import.url" --output "$scratch/import.png" >/dev/null 2>&1; then
        echo 'QR export overwrote an existing file' >&2
        exit 1
      fi
      sudo rm "$scratch/import.png"
      rm "$scratch/decoded"
    fi
    sudo rm "$scratch/import.url"
    echo 'Concurrent allocations, duplicate handling, unmanaged reservations and protected exports passed.'
    ;;
  finish)
    client list > "$scratch/reboot.json"
    cmp -s "$scratch/list.json" "$scratch/reboot.json"
    alpha=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["public_key"])' "$scratch/alpha.json")
    sudo wg show wg-vk peers | grep -Fxq "$alpha"
    sudo mount --bind "$config" "$config"
    trap 'sudo umount "$config"' EXIT
    if client remove ci-alpha > "$scratch/error" 2>&1; then
      echo 'Expected a revocation write failure' >&2
      exit 1
    fi
    grep -q 'Device or resource busy' "$scratch/error"
    sudo umount "$config"
    trap - EXIT
    client list | cmp -s - "$scratch/list.json"
    WG_CLIENT_CONF="$scratch/client.conf" bash network-dataplane.sh
    client remove ci-alpha >/dev/null
    if sudo wg show wg-vk peers | grep -Fxq "$alpha"; then
      echo 'Revoked peer is still active' >&2
      exit 1
    fi
    sudo test ! -e /var/lib/vk-turn-clients/ci-alpha
    WG_CLIENT_CONF="$scratch/client.conf" WG_EXPECT_DENIED=1 bash network-dataplane.sh
    client remove ci-beta >/dev/null
    sudo sha256sum --status -c "$scratch/baseline"
    sudo wg show wg-vk allowed-ips | cmp -s - "$scratch/runtime-baseline"
    sudo rm "$scratch/client.conf"
    rm -rf "$scratch"
    echo 'Managed peers survived reboot, carried traffic, and revocation preserved the unmanaged peer.'
    ;;
  *) exit 2 ;;
esac
