use crate::{
    delete_file, lock, owns_unit, require_absent, systemctl, unit_path, write_new, Result,
};
use std::fs::{self, DirBuilder};
use std::io;
use std::net::Ipv4Addr;
use std::os::unix::fs::DirBuilderExt;
use std::path::Path;
use std::process::Command;

const TABLE: &str = "vk_turn_manager";
const UNIT: &str = "vk-turn-network.service";
const UNIT_TEXT: &str = include_str!("../units/vk-turn-network.service");
const STATE: &str = "/etc/vk-turn-network";
const MARKER: &str = "/etc/vk-turn-network/managed";
const VERSION: &[u8] = b"vk-turn-manager network v1\n";
const RULES: &str = "/etc/vk-turn-network/rules.nft";
const SNAPSHOT: &str = "/etc/vk-turn-network/loaded.nft";
const FORWARD: &str = "/proc/sys/net/ipv4/ip_forward";

fn read_command(program: &str, args: &[&str]) -> Result<String> {
    let result = Command::new(program).args(args).output()?;
    if !result.status.success() {
        return Err(format!(
            "{program} {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&result.stderr).trim()
        )
        .into());
    }
    Ok(String::from_utf8(result.stdout)?)
}

fn route_interface(route: &str) -> Result<&str> {
    let words: Vec<_> = route.split_whitespace().collect();
    let mut interfaces = words.windows(2).filter(|pair| pair[0] == "dev");
    let name = interfaces.next().ok_or("No outbound interface found")?[1];
    if interfaces.next().is_some()
        || ["lo", "wg-vk"].contains(&name)
        || name.len() > 15
        || !name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_.-".contains(&c))
    {
        return Err("Outbound interface is ambiguous or unsupported".into());
    }
    Ok(name)
}

fn cidr(value: &str) -> Result<(u32, u8)> {
    let (address, prefix) = value.split_once('/').ok_or("Expected an IPv4 CIDR")?;
    let prefix = prefix.parse::<u8>()?;
    if prefix > 32 {
        return Err("Invalid IPv4 prefix length".into());
    }
    Ok((u32::from(address.parse::<Ipv4Addr>()?), prefix))
}

fn client_subnet(addresses: &str, allowed_ips: &str) -> Result<String> {
    let words: Vec<_> = addresses.split_whitespace().collect();
    let mut addresses = words.windows(2).filter(|pair| pair[0] == "inet");
    let address = addresses.next().ok_or("wg-vk has no IPv4 address")?[1];
    let (host, prefix) = cidr(address)?;
    if addresses.next().is_some() || !(1..32).contains(&prefix) {
        return Err(
            "wg-vk needs exactly one IPv4 address with an unambiguous client subnet (/1–/31)"
                .into(),
        );
    }
    let mask = u32::MAX << (32 - prefix);
    let subnet = host & mask;
    // The first field on each line is a peer public key. Never print peer data.
    for line in allowed_ips.lines() {
        let (_, ranges) = line
            .split_once(char::is_whitespace)
            .ok_or("Invalid WireGuard AllowedIPs output")?;
        for range in ranges
            .split(|c: char| c.is_whitespace() || c == ',')
            .filter(|item| !item.is_empty())
        {
            if range == "(none)" || range.contains(':') {
                continue;
            }
            let (peer, peer_prefix) = cidr(range)?;
            if peer_prefix < prefix || peer & mask != subnet {
                return Err("A peer has IPv4 AllowedIPs outside the detected wg-vk subnet".into());
            }
        }
    }
    Ok(format!("{}/{prefix}", Ipv4Addr::from(subnet)))
}

fn topology() -> Result<(String, String)> {
    let route = read_command("ip", &["-4", "route", "get", "1.1.1.1"])?;
    let interface = route_interface(&route)?.to_owned();
    let addresses = read_command("ip", &["-4", "-o", "addr", "show", "dev", "wg-vk"])?;
    let peers = read_command("wg", &["show", "wg-vk", "allowed-ips"])?;
    let subnet = client_subnet(&addresses, &peers)?;
    Ok((interface, subnet))
}

fn rules(interface: &str, subnet: &str) -> String {
    format!(
        r#"create table ip {TABLE} {{ comment "vk-turn-manager network v1"; }}
add chain ip {TABLE} forward {{ type filter hook forward priority filter; policy accept; }}
add rule ip {TABLE} forward iifname "wg-vk" oifname "{interface}" ip saddr {subnet} ct state new,established,related accept
add rule ip {TABLE} forward iifname "{interface}" oifname "wg-vk" ip daddr {subnet} ct state established,related accept
add chain ip {TABLE} postrouting {{ type nat hook postrouting priority srcnat; policy accept; }}
add rule ip {TABLE} postrouting iifname "wg-vk" oifname "{interface}" ip saddr {subnet} counter masquerade
"#
    )
}

fn report_firewall(ruleset: &str) {
    if ruleset
        .lines()
        .any(|line| line.trim() == "table ip vkturn {")
    {
        println!("Legacy ip vkturn table detected; it can compete for NAT and is preserved.");
    }
    if has_foreign_forward_hook(ruleset) {
        println!(
            "Other nftables forward hooks detected; their policies can still drop VPN traffic."
        );
    }
    println!("Verify forwarding end to end. Other firewalls, routing policy and upstream filters may still block traffic.");
}

fn has_foreign_forward_hook(ruleset: &str) -> bool {
    let mut managed = false;
    for line in ruleset.lines() {
        if line.starts_with("table ") {
            managed = line.starts_with("table ip vk_turn_manager ");
        }
        if !managed && line.contains(" hook forward ") {
            return true;
        }
    }
    false
}

fn forwarding() -> Result<bool> {
    match fs::read_to_string(FORWARD)?.trim() {
        "0" => Ok(false),
        "1" => Ok(true),
        _ => Err("Unexpected IPv4 forwarding value".into()),
    }
}

fn table() -> Result<Option<String>> {
    let tables = read_command("nft", &["list", "tables"])?;
    if tables
        .lines()
        .any(|line| line.trim() == format!("table ip {TABLE}"))
    {
        return Ok(Some(read_command(
            "nft",
            &["-s", "list", "table", "ip", TABLE],
        )?));
    }
    Ok(None)
}

fn service_active(unit: &str) -> bool {
    Command::new("systemctl")
        .args(["is-active", "--quiet", unit])
        .status()
        .is_ok_and(|s| s.success())
}

pub fn status() -> Result<()> {
    match read_command("ip", &["-4", "route", "get", "1.1.1.1"]) {
        Ok(route) => println!(
            "Outbound interface: {}",
            route_interface(&route).unwrap_or("ambiguous")
        ),
        Err(_) => println!("Outbound interface: unavailable"),
    }
    match read_command("wg", &["show", "wg-vk", "listen-port"]) {
        Ok(port) => println!("WireGuard wg-vk: UDP {}", port.trim()),
        Err(_) => println!("WireGuard wg-vk: inactive or unavailable"),
    }
    println!(
        "SRTP service: {}",
        if service_active(crate::SRTP) {
            "active"
        } else {
            "inactive"
        }
    );
    println!(
        "IPv4 forwarding: {}",
        if forwarding()? { "enabled" } else { "disabled" }
    );
    println!(
        "Managed NAT service: {}",
        if service_active(UNIT) {
            "active"
        } else {
            "inactive"
        }
    );
    let ruleset = read_command("nft", &["-s", "list", "ruleset"])?;
    if let Some(current) = table()? {
        let matching = fs::read_to_string(SNAPSHOT).is_ok_and(|saved| current == saved);
        println!(
            "Managed table: {}",
            if matching {
                "matches saved rules"
            } else {
                "present; ownership or rules differ from saved state"
            }
        );
    } else {
        println!("Managed table: absent");
    }
    report_firewall(&ruleset);
    Ok(())
}

pub fn plan() -> Result<()> {
    let (interface, subnet) = topology()?;
    println!("Outbound interface: {interface}\nWireGuard client subnet: {subnet}");
    println!(
        "Planned resources: ip {TABLE}, {UNIT}; enable IPv4 forwarding when the service starts."
    );
    status()
}

fn state_exists() -> Result<bool> {
    match fs::symlink_metadata(STATE) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Ok(metadata) if metadata.is_dir() && fs::read(MARKER).as_deref().ok() == Some(VERSION) => {
            Ok(true)
        }
        Ok(_) => Err(format!("Unrecognized ownership at {STATE}").into()),
        Err(e) => Err(e.into()),
    }
}

fn check_saved_table(current: &str) -> Result<()> {
    if fs::read_to_string(SNAPSHOT).is_ok_and(|saved| saved == current) {
        return Ok(());
    }
    Err(
        format!("ip {TABLE} differs from its recorded rules; reconcile it before changing state")
            .into(),
    )
}

fn stop_unit() -> Result<()> {
    systemctl(&["stop", UNIT])?;
    systemctl(&["disable", UNIT])?;
    Ok(())
}

fn remove_files() -> Result<()> {
    for file in [RULES, SNAPSHOT, MARKER] {
        delete_file(file)?;
    }
    fs::remove_dir(STATE)?;
    Ok(())
}

pub fn enable() -> Result<()> {
    let _lock = lock()?;
    let (interface, subnet) = topology()?;
    let desired = rules(&interface, &subnet);
    let current = table()?;
    if state_exists()? {
        let current = current
            .as_deref()
            .ok_or("Managed table is missing; disable and re-enable to repair")?;
        check_saved_table(current)?;
        if !owns_unit(UNIT, UNIT_TEXT)?
            || fs::read_to_string(RULES)? != desired
            || !forwarding()?
            || !service_active(UNIT)
            || !Command::new("systemctl")
                .args(["is-enabled", "--quiet", UNIT])
                .status()?
                .success()
        {
            return Err("Managed network state or detected topology changed; inspect, disable and re-enable".into());
        }
        println!("Managed NAT is already enabled.");
        report_firewall(&read_command("nft", &["-s", "list", "ruleset"])?);
        return Ok(());
    }
    if current.is_some() {
        return Err(format!("ip {TABLE} already exists without manager ownership").into());
    }
    require_absent(&unit_path(UNIT))?;
    let unit = crate::output(
        "systemctl",
        &["show", "--property=LoadState", "--value", UNIT],
    )?;
    if unit.stdout != b"not-found\n" {
        return Err("Managed service name is already in use or systemd cannot be inspected".into());
    }
    let prior_forwarding = forwarding()?;
    let existing_rules = read_command("nft", &["-s", "list", "ruleset"])?;
    DirBuilder::new().mode(0o700).create(STATE)?;
    let mut installed = false;
    let mut starting = false;
    let attempt = (|| {
        write_new(MARKER, 0o600, VERSION)?;
        write_new(RULES, 0o600, desired.as_bytes())?;
        read_command("nft", &["-c", "-f", RULES])?;
        let path = unit_path(UNIT);
        // A failed write may leave a partial file. Open exclusively before taking ownership.
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut unit = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o644)
            .open(path)?;
        installed = true;
        unit.write_all(UNIT_TEXT.as_bytes())?;
        systemctl(&["daemon-reload"])?;
        starting = true;
        systemctl(&["enable", "--now", UNIT])?;
        if !service_active(UNIT) || !forwarding()? {
            return Err(format!(
                "{UNIT} failed to activate NAT and forwarding; inspect its journal"
            )
            .into());
        }
        let loaded = table()?.ok_or("Managed NAT table did not load")?;
        write_new(SNAPSHOT, 0o600, loaded.as_bytes())
    })();
    if let Err(error) = attempt {
        let rollback: Result<()> = (|| {
            if starting {
                stop_unit()?;
                if let Some(loaded) = table()? {
                    if !loaded
                        .lines()
                        .any(|line| line.trim() == r#"comment "vk-turn-manager network v1""#)
                    {
                        return Err(
                            "Cannot establish ownership of the table during rollback".into()
                        );
                    }
                    read_command("nft", &["delete", "table", "ip", TABLE])?;
                    // Immediately undo a transition during an unsuccessful enable.
                    if !prior_forwarding && forwarding()? {
                        fs::write(FORWARD, b"0\n")?;
                    }
                }
            }
            if installed {
                delete_file(&unit_path(UNIT))?;
                systemctl(&["daemon-reload"])?;
            }
            remove_files()
        })();
        return match rollback {
            Ok(()) => Err(error),
            Err(cleanup) => Err(format!("{error}; rollback incomplete: {cleanup}").into()),
        };
    }
    println!("Enabled managed IPv4 NAT from {subnet} on wg-vk via {interface}.");
    report_firewall(&existing_rules);
    Ok(())
}

pub fn disable() -> Result<()> {
    let _lock = lock()?;
    disable_locked()
}

pub fn disable_locked() -> Result<()> {
    if !state_exists()? {
        println!("Managed NAT is not configured.");
        return Ok(());
    }
    for entry in fs::read_dir(STATE)? {
        let entry = entry?;
        if ![RULES, SNAPSHOT, MARKER]
            .iter()
            .any(|path| Path::new(path) == entry.path())
            || !entry.file_type()?.is_file()
        {
            return Err(format!("Unmanaged files in {STATE}; refusing cleanup").into());
        }
    }
    let owned_unit = owns_unit(UNIT, UNIT_TEXT)?;
    let current = table()?;
    if let Some(current) = &current {
        check_saved_table(current)?;
    }
    if owned_unit {
        stop_unit()?;
    }
    if current.is_some() {
        read_command("nft", &["delete", "table", "ip", TABLE])?;
    }
    if owned_unit {
        delete_file(&unit_path(UNIT))?;
    }
    systemctl(&["daemon-reload"])?;
    remove_files()?;
    println!("Removed managed NAT and its boot-time forwarding setting. Live global forwarding was left alone for other workloads.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_egress_and_rejects_invalid_or_ambiguous_routes() {
        assert_eq!(
            route_interface("1.1.1.1 via 192.0.2.1 dev enp1s0").unwrap(),
            "enp1s0"
        );
        for route in [
            "unreachable 1.1.1.1",
            "dev eth0 dev eth1",
            "dev wg-vk",
            "dev bad\"name",
        ] {
            assert!(route_interface(route).is_err(), "{route}");
        }
    }

    #[test]
    fn normalizes_subnet_and_validates_ipv4_peer_ranges() {
        let address = "4: wg-vk inet 172.30.5.8/23 scope global wg-vk";
        assert_eq!(
            client_subnet(address, "key\t172.30.5.9/32,fd00::1/128").unwrap(),
            "172.30.4.0/23"
        );
        assert!(client_subnet(address, "key\t0.0.0.0/0").is_err());
        assert!(client_subnet(address, "key\t172.30.6.9/32").is_err());
        assert!(client_subnet(&format!("{address}\n{address}"), "").is_err());
        assert!(client_subnet("inet 172.30.5.8/32", "").is_err());
    }

    #[test]
    fn rules_are_scoped_and_use_an_exclusive_table() {
        let proposed = rules("enp1s0", "172.30.4.0/23");
        assert!(proposed.starts_with("create table ip vk_turn_manager "));
        assert!(proposed.contains(
            r#"iifname "wg-vk" oifname "enp1s0" ip saddr 172.30.4.0/23 counter masquerade"#
        ));
        assert!(!proposed.contains("flush"));
    }

    #[test]
    fn detects_forward_hooks_in_other_families_and_tables() {
        let own = "table ip vk_turn_manager {\n type filter hook forward priority filter; policy accept;\n}\n";
        assert!(!has_foreign_forward_hook(own));
        assert!(has_foreign_forward_hook(&format!("{own}table inet foreign {{\n type filter hook forward priority filter; policy drop;\n}}")));
    }
}
