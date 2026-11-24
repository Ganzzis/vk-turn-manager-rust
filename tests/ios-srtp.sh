#!/usr/bin/env bash
set -euo pipefail

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
revision=0fddeef5b70044a0cf9bcd9fe093edfc4956d8c6
release=https://github.com/anton48/vk-turn-proxy/releases/download/srtp-build478
digest=21b4c5e02c8b6658521d17ecbbc2f25487b2cd9f863a7ff70a0a66783af63e98

# Tie the probe to the installer and service contract. Only the listen IP is
# narrowed to loopback for isolation when launching the production binary.
grep -Fqx "const RELEASE: &str = \"$release\";" src/main.rs
grep -Fq "\"$digest\"" src/main.rs
grep -Fqx 'ExecStart=/etc/vk-turn-manager/server -srtp -listen 0.0.0.0:56004 -connect 127.0.0.1:51820' \
  units/vk-turn-srtp.service
curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
  --max-time 120 --output "$scratch/server" "$release/server-linux-amd64"
printf '%s  %s\n' "$digest" "$scratch/server" | sha256sum --check --status
chmod 0700 "$scratch/server"

git init -q "$scratch/ios"
git -C "$scratch/ios" fetch -q --depth 1 https://github.com/anton48/vk-turn-proxy-ios "$revision"
git -C "$scratch/ios" checkout -q --detach "$revision"
cp tests/fixtures/upstream-ios-srtp.go "$scratch/ios/compatibility_probe.go"
(cd "$scratch/ios" && go build -mod=readonly -o "$scratch/probe" compatibility_probe.go)

python3 - "$scratch" <<'PY'
import socket
import subprocess
import sys
from pathlib import Path

scratch = Path(sys.argv[1])
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as backend, (scratch / "server.log").open("w+") as log:
    backend.bind(("127.0.0.1", 51820))
    backend.settimeout(20)
    with subprocess.Popen(
        [scratch / "server", "-srtp", "-listen", "127.0.0.1:56004", "-connect", "127.0.0.1:51820"],
        stdout=log, stderr=subprocess.STDOUT,
    ) as server, subprocess.Popen([scratch / "probe"]) as probe:
        try:
            datagram, source = backend.recvfrom(2048)
            if datagram != b"\x01\x00\x00\x00" + b"\x35" * 144:
                raise RuntimeError("uplink lost datagram bytes or framing")
            backend.sendto(b"\x02\x00\x00\x00" + b"\x79" * 88, source)
            if probe.wait(timeout=10) != 0 or server.poll() is not None:
                raise RuntimeError("DTLS-SRTP loopback probe failed")
        except Exception:
            log.seek(0)
            print(log.read(), file=sys.stderr)
            raise
        finally:
            probe.kill()
            server.kill()
PY
