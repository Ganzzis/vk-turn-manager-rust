# VK TURN Manager (Rust)

Minimal **experimental** Ubuntu 24.04 CLI for managing WireGuard and an **already built** SRTP executable.

## Current scope

- Installs WireGuard packages via apt.
- Copies a supplied WireGuard config to `/etc/wireguard/wg-vk.conf` (mode 0600).
- Registers an existing SRTP binary and its command-line arguments as a systemd service.
- Starts both services; provides `status` and `uninstall`.
- Refuses to overwrite an existing WireGuard config or SRTP unit.
- Uninstall leaves VPN configuration and SRTP binary intact.

**Not yet a complete one-command VK TURN installer.** It does not build or download SRTP, generate WireGuard keys, create firewall rules, or configure the required VK TURN/SRTP relay settings. Those depend on validating the upstream `anton48/vk-turn-proxy` build and its actual CLI. Do not run this on a production VPN without reviewing the configuration.

## Build

```bash
sudo apt-get update
sudo apt-get install -y cargo
cargo build --release
```

## Usage

```bash
sudo ./target/release/vk-turn-manager install ./wg-vk.conf /absolute/path/to/srtp-binary [srtp-arguments...]
sudo ./target/release/vk-turn-manager status
sudo ./target/release/vk-turn-manager uninstall
```

**Caution:** `install` modifies system services and `/etc/wireguard`. The supplied WireGuard config must already be valid. Use a disposable Ubuntu 24.04 VM for first tests.

## Target topology (not automatically configured)

- WireGuard interface: `wg-vk`
- WireGuard UDP port: `51820`
- SRTP UDP port: `56004`
- Target forwarding endpoint: `127.0.0.1:51820`

License: MIT.
