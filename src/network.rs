use std::fs;
use std::io;
use std::process::Command;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn read_command(program: &str, args: &[&str]) -> Result<String> {
    let result = Command::new(program).args(args).output()?;
    if !result.status.success() {
        return Err(format!(
            "{program} failed: {}",
            String::from_utf8_lossy(&result.stderr).trim()
        )
        .into());
    }
    Ok(String::from_utf8(result.stdout)?)
}

fn route_interface(route: &str) -> Option<&str> {
    let words: Vec<_> = route.split_whitespace().collect();
    words
        .windows(2)
        .find(|pair| pair[0] == "dev")
        .map(|pair| pair[1])
}

pub fn plan() -> Result<()> {
    println!("VK TURN network plan (read-only)");
    let route = read_command("ip", &["-4", "route", "get", "1.1.1.1"])?;
    let interface = route_interface(&route)
        .ok_or("Could not determine outbound interface; no changes can be planned")?;
    println!("Outbound interface: {interface}");

    let addresses = read_command("ip", &["-4", "-o", "addr", "show", "dev", "wg-vk"])?;
    let subnet = addresses
        .split_whitespace()
        .collect::<Vec<_>>()
        .windows(2)
        .find(|pair| pair[0] == "inet")
        .map(|pair| pair[1])
        .ok_or("No IPv4 address found on wg-vk")?;
    println!("WireGuard interface address: {subnet}");
    println!("Note: interface address is not necessarily the full VPN client subnet.");

    let forwarding = fs::read_to_string("/proc/sys/net/ipv4/ip_forward")?;
    println!(
        "IPv4 forwarding: {}",
        if forwarding.trim() == "1" {
            "enabled"
        } else {
            "disabled; would require enabling"
        }
    );

    match Command::new("nft")
        .args(["list", "table", "ip", "vkturn"])
        .output()
    {
        Ok(result) if result.status.success() => {
            println!("Existing ip vkturn table: present (ownership unknown)");
            println!("Action: preserve existing rules; refuse automatic takeover");
        }
        Ok(result) => {
            let error = String::from_utf8_lossy(&result.stderr);
            if error.contains("No such file or directory") {
                println!("Existing ip vkturn table: absent");
                println!("Action: a new, separately owned table may be provisioned after validation");
            } else {
                return Err(format!("Cannot safely inspect nftables: {}", error.trim()).into());
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            println!("nftables: not installed; provisioning would require installation");
        }
        Err(error) => return Err(format!("Cannot inspect nftables: {error}").into()),
    }

    println!("No changes made. NAT subnet, firewall chain policies and ownership require validation before network enable.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::route_interface;

    #[test]
    fn parses_outbound_interface() {
        assert_eq!(
            route_interface("1.1.1.1 via 10.0.0.1 dev ens3 src 192.0.2.1"),
            Some("ens3")
        );
        assert_eq!(route_interface("1.1.1.1 dev eth0 src 192.0.2.1"), Some("eth0"));
        assert_eq!(route_interface("unreachable 1.1.1.1"), None);
    }
}
