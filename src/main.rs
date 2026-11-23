use std::env;
use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::process::{Command, ExitCode, Output};
use std::thread;
use std::time::Duration;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

const STATE: &str = "/etc/vk-turn-manager";
const MARKER: &str = "/etc/vk-turn-manager/managed";
const MARKER_CONTENT: &[u8] = b"vk-turn-manager installation\n";
const CONFIG: &str = "/etc/vk-turn-manager/wg-vk.conf";
const SERVER: &str = "/etc/vk-turn-manager/server";
const WG: &str = "vk-turn-wireguard.service";
const SRTP: &str = "vk-turn-srtp.service";
const RELEASE: &str = "https://github.com/anton48/vk-turn-proxy/releases/download/srtp-build478";

const WG_UNIT: &str = include_str!("../units/vk-turn-wireguard.service");
const SRTP_UNIT: &str = include_str!("../units/vk-turn-srtp.service");

fn output(program: &str, args: &[&str]) -> Result<Output> {
    Command::new(program)
        .args(args)
        .output()
        .map_err(|error| format!("Could not run {program}: {error}").into())
}

fn run(program: &str, args: &[&str]) -> Result<()> {
    let status = Command::new(program)
        .args(args)
        .status()
        .map_err(|error| format!("Could not run {program}: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{program} {} failed ({status})", args.join(" ")).into())
    }
}

fn systemctl(args: &[&str]) -> Result<()> {
    run("systemctl", args)
}

fn lock() -> Result<File> {
    if output("id", &["-u"])?.stdout != b"0\n" {
        return Err("Run install or uninstall with sudo".into());
    }
    let lock = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open("/run/vk-turn-manager.lock")?;
    lock.try_lock()
        .map_err(|error| format!("Could not lock installer: {error}"))?;
    Ok(lock)
}

fn validate_config(config: &str) -> Result<()> {
    let mut section = "";
    let mut interfaces = 0;
    let mut port = false;
    let mut table = false;
    for line in config.lines() {
        let line = line.split('#').next().unwrap_or("").trim();
        if line.starts_with('[') {
            if !line.eq_ignore_ascii_case("[Interface]") && !line.eq_ignore_ascii_case("[Peer]") {
                return Err("wg-vk.conf: expected an [Interface] or [Peer] section".into());
            }
            section = line;
            if line.eq_ignore_ascii_case("[Interface]") {
                interfaces += 1;
            }
        } else if let Some((key, value)) = line.split_once('=') {
            let key = key.trim().to_ascii_lowercase();
            if matches!(
                key.as_str(),
                "dns" | "preup" | "postup" | "predown" | "postdown" | "saveconfig"
            ) {
                return Err(format!("wg-vk.conf: {key} is unsupported").into());
            }
            if !section.eq_ignore_ascii_case("[Interface]") {
                continue;
            }
            match key.as_str() {
                "listenport" if !port && value.trim() == "51820" => port = true,
                "table" if !table && value.trim() == "off" => table = true,
                "listenport" | "table" => {
                    return Err("Set exactly one ListenPort = 51820 and Table = off".into());
                }
                _ => {}
            }
        }
    }
    if interfaces == 1 && port && table {
        Ok(())
    } else {
        Err("wg-vk.conf requires one [Interface] with ListenPort = 51820 and Table = off".into())
    }
}

fn release_asset(architecture: &str) -> Result<(&'static str, &'static str)> {
    match architecture {
        "x86_64" => Ok((
            "server-linux-amd64",
            "21b4c5e02c8b6658521d17ecbbc2f25487b2cd9f863a7ff70a0a66783af63e98",
        )),
        "aarch64" => Ok((
            "server-linux-arm64",
            "b06bf4c9f40dfd882d85234b85d26773d9503e00d58661fd3bb15d311678ec12",
        )),
        _ => Err(format!("Unsupported architecture: {architecture} (use amd64 or arm64)").into()),
    }
}

fn install_server(asset: &str, checksum: &str) -> Result<()> {
    run(
        "curl",
        &[
            "--disable",
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--connect-timeout",
            "15",
            "--max-time",
            "120",
            "--output",
            SERVER,
            &format!("{RELEASE}/{asset}"),
        ],
    )?;
    let digest = output("sha256sum", &[SERVER])?;
    verify_digest(&digest, checksum)?;
    fs::set_permissions(SERVER, fs::Permissions::from_mode(0o755))?;
    Ok(())
}

fn verify_digest(result: &Output, expected: &str) -> Result<()> {
    if result.status.success()
        && String::from_utf8_lossy(&result.stdout)
            .split_whitespace()
            .next()
            == Some(expected)
    {
        Ok(())
    } else {
        Err("SRTP download failed SHA-256 verification".into())
    }
}

fn require_absent(path: &str) -> Result<()> {
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Ok(_) => {
            Err(format!("Already exists: {path}. Resolve the conflict before installing.").into())
        }
        Err(error) => Err(format!("{path}: {error}").into()),
    }
}

fn unit_path(unit: &str) -> String {
    format!("/etc/systemd/system/{unit}")
}

fn check_unit_free(unit: &str) -> Result<()> {
    require_absent(&unit_path(unit))?;
    let info = output(
        "systemctl",
        &["show", "--property=LoadState", "--value", unit],
    )?;
    if info.stdout == b"not-found\n" {
        Ok(())
    } else if info.status.success() {
        Err(format!("systemd already knows about {unit}").into())
    } else {
        Err(format!(
            "Could not check {unit}: {}",
            String::from_utf8_lossy(&info.stderr).trim()
        )
        .into())
    }
}

fn sockets(filter: &str, processes: bool) -> Result<String> {
    let flags = if processes { "-Haunp" } else { "-Haun" };
    let result = output("ss", &[flags, filter])?;
    if !result.status.success() {
        return Err(format!(
            "Could not inspect UDP sockets: {}",
            String::from_utf8_lossy(&result.stderr).trim()
        )
        .into());
    }
    Ok(String::from_utf8(result.stdout)?)
}

fn check_network_free() -> Result<()> {
    require_absent("/sys/class/net/wg-vk")?;
    let listeners = sockets("( sport = :51820 or sport = :56004 )", false)?;
    if !listeners.trim().is_empty() {
        return Err(
            format!("Required UDP ports 51820 and 56004 must be free:\n{listeners}").into(),
        );
    }
    Ok(())
}

fn write_new(path: &str, mode: u32, bytes: &[u8]) -> Result<()> {
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(path)?
        .write_all(bytes)?;
    Ok(())
}

fn enable_and_verify() -> Result<()> {
    systemctl(&["daemon-reload"])?;
    systemctl(&["enable", "--now", SRTP])?;
    let port = output("wg", &["show", "wg-vk", "listen-port"])?;
    if !port.status.success() || port.stdout != b"51820\n" {
        return Err("WireGuard wg-vk did not start on UDP 51820".into());
    }
    for _ in 0..25 {
        let main = output(
            "systemctl",
            &["show", "--property=MainPID", "--value", SRTP],
        )?;
        let pid = String::from_utf8(main.stdout)?;
        if main.status.success()
            && pid.trim().parse::<u32>().is_ok_and(|value| value > 0)
            && sockets("sport = :56004", true)?.contains(&format!("pid={},", pid.trim()))
        {
            return systemctl(&["is-active", "--quiet", SRTP]);
        }
        thread::sleep(Duration::from_millis(200));
    }
    Err(format!("SRTP did not bind UDP 56004. See journalctl -u {SRTP}.").into())
}

fn install(source: &Path) -> Result<()> {
    let _lock = lock()?;
    let config = fs::read_to_string(source)
        .map_err(|err| format!("Could not read {}: {err}", source.display()))?;
    validate_config(&config)?;
    let (asset, checksum) = release_asset(env::consts::ARCH)?;
    require_absent(STATE)?;
    require_absent("/etc/wireguard/wg-vk.conf")?;
    check_unit_free("vk-srtp.service")?;
    check_unit_free(WG)?;
    check_unit_free(SRTP)?;
    require_absent("/sys/class/net/wg-vk")?;

    run("apt-get", &["update"])?;
    run(
        "apt-get",
        &[
            "install",
            "-y",
            "--no-install-recommends",
            "wireguard-tools",
            "iproute2",
            "curl",
            "ca-certificates",
        ],
    )?;
    check_network_free()?;

    DirBuilder::new().mode(0o755).create(STATE)?;
    let mut installed = Vec::new();
    let mut starting = false;
    let result = (|| {
        fs::set_permissions(STATE, fs::Permissions::from_mode(0o755))?;
        write_new(MARKER, 0o644, MARKER_CONTENT)?;
        write_new(CONFIG, 0o600, config.as_bytes())?;
        install_server(asset, checksum)?;
        for (unit, text) in [(WG, WG_UNIT), (SRTP, SRTP_UNIT)] {
            let path = unit_path(unit);
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o644)
                .open(&path)?;
            if let Err(error) = file.write_all(text.as_bytes()) {
                delete_file(&path)?;
                return Err(error.into());
            }
            installed.push(unit);
        }
        starting = true;
        enable_and_verify()
    })();
    if let Err(error) = result {
        if let Err(cleanup) = remove_installation(&installed, starting) {
            return Err(format!("{error}. Cleanup failed: {cleanup}. Retry uninstall.").into());
        }
        return Err(error);
    }
    println!("Installed: wg-vk UDP 51820, SRTP UDP 56004 -> 127.0.0.1:51820");
    Ok(())
}

fn delete_file(path: &str) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("Could not remove {path}: {error}").into()),
    }
}

fn owns_unit(unit: &str, text: &str) -> Result<bool> {
    let path = unit_path(unit);
    match fs::symlink_metadata(&path) {
        Ok(metadata) if metadata.is_file() && fs::read(&path)? == text.as_bytes() => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        _ => Err(format!("Refusing to touch an unmanaged unit: {path}").into()),
    }
}

fn remove_installation(installed: &[&str], started: bool) -> Result<()> {
    if started {
        if installed.contains(&SRTP) {
            systemctl(&["stop", SRTP])?;
        }
        if installed.contains(&WG) {
            systemctl(&["stop", WG])?;
        }
        if installed.contains(&SRTP) {
            systemctl(&["disable", SRTP])?;
        }
    }
    for unit in installed {
        delete_file(&unit_path(unit))?;
    }
    if !installed.is_empty() {
        systemctl(&["daemon-reload"])?;
    }
    for path in [SERVER, CONFIG, MARKER] {
        delete_file(path)?;
    }
    fs::remove_dir(STATE)?;
    Ok(())
}

fn uninstall() -> Result<()> {
    let _lock = lock()?;
    match fs::symlink_metadata(STATE) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            println!("VK TURN Manager is not installed");
            return Ok(());
        }
        Ok(metadata) if metadata.is_dir() => {}
        Ok(_) => return Err(format!("Unexpected file at {STATE}").into()),
        Err(error) => return Err(error.into()),
    }
    if fs::read(MARKER).as_deref().ok() != Some(MARKER_CONTENT) {
        return Err(
            format!("Refusing to remove unrecognized installation directory: {STATE}").into(),
        );
    }
    let mut installed = Vec::new();
    for (unit, text) in [(WG, WG_UNIT), (SRTP, SRTP_UNIT)] {
        if owns_unit(unit, text)? {
            installed.push(unit);
        }
    }
    // Do not remove any unexpected files, including an operator's backups.
    for entry in fs::read_dir(STATE)? {
        let entry = entry?;
        match entry.file_name().to_str() {
            Some("server" | "wg-vk.conf" | "managed") if entry.file_type()?.is_file() => {}
            _ => {
                return Err(
                    format!("Unexpected file in {STATE}: {}", entry.path().display()).into(),
                )
            }
        }
    }
    remove_installation(&installed, true)?;
    println!("Removed managed services and configuration copy. The source file and system packages were retained.");
    Ok(())
}

fn network_status() -> Result<()> {
    let route = output("ip", &["-4", "route", "get", "1.1.1.1"])?;
    if route.status.success() {
        println!("Outbound route: {}", String::from_utf8_lossy(&route.stdout).trim());
    } else {
        println!("Outbound route: unavailable");
    }

    let forwarding = fs::read_to_string("/proc/sys/net/ipv4/ip_forward")?;
    println!("IPv4 forwarding: {}", if forwarding.trim() == "1" { "enabled" } else { "disabled" });

    let wg = output("wg", &["show", "wg-vk", "listen-port"])?;
    println!("WireGuard wg-vk: {}", if wg.status.success() {
        format!("UDP {}", String::from_utf8_lossy(&wg.stdout).trim())
    } else {
        "not active".to_string()
    });

    let srtp = output("systemctl", &["is-active", SRTP])?;
    println!("SRTP service: {}", if srtp.status.success() { "active" } else { "inactive" });

    match Command::new("nft").args(["list", "table", "ip", "vkturn"]).output() {
        Ok(result) if result.status.success() => {
            let rules = String::from_utf8_lossy(&result.stdout);
            println!("VK TURN nftables table: present");
            println!("Masquerade rule: {}", if rules.contains("masquerade") { "present" } else { "missing" });
            println!("Forward chain: {}", if rules.contains("hook forward") { "present" } else { "missing" });
        }
        Ok(_) => println!("VK TURN nftables table: absent or inaccessible"),
        Err(error) if error.kind() == io::ErrorKind::NotFound => println!("nftables: command not installed"),
        Err(error) => return Err(format!("Could not inspect nftables: {error}").into()),
    }
    println!("Note: this is a read-only diagnostic; other firewall chains may still block traffic.");
    Ok(())
}

fn main() -> ExitCode {
    let args: Vec<_> = env::args_os().skip(1).collect();
    let result = match args.as_slice() {
        [command, source] if command == "install" => install(Path::new(source)),
        [command] if command == "status" => {
            systemctl(&["--no-pager", "--full", "status", WG, SRTP])
        }
        [command] if command == "uninstall" => uninstall(),
        [command, subcommand] if command == "network" && subcommand == "status" => network_status(),
        [command] if command == "--help" || command == "-h" => {
            usage();
            return ExitCode::SUCCESS;
        }
        _ => {
            usage();
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Error: {error}");
            ExitCode::FAILURE
        }
    }
}

fn usage() {
    eprintln!("Usage:\n  vk-turn-manager install <wg-config-file>\n  vk-turn-manager status\n  vk-turn-manager uninstall");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::process::ExitStatusExt;
    use std::process::ExitStatus;

    const CONFIG: &str = "[Interface]\nListenPort = 51820\nTable = off\n";

    #[test]
    fn accepts_fixed_wireguard_settings_and_peer() {
        let config = format!("{}[Peer]\nAllowedIPs = 10.0.0.2/32\n", CONFIG);
        assert!(validate_config(&config).is_ok());
        assert!(
            validate_config("[Interface]\n ListenPort = 51820 # wireguard\nTable = off\n").is_ok()
        );
    }

    #[test]
    fn rejects_wrong_missing_or_duplicate_settings() {
        for config in [
            "[Interface]\nListenPort = 51820\n",
            "[Interface]\nListenPort = 51821\nTable = off\n",
            "[Interface]\nListenPort = 51820\nTable = auto\n",
            "[Peer]\nListenPort = 51820\nTable = off\n",
            &format!("{CONFIG}ListenPort = 51820\n"),
            &format!("{CONFIG}[Interface]\n"),
            &format!("{CONFIG}[Interface] = invalid\n"),
        ] {
            assert!(validate_config(config).is_err(), "{config}");
        }
    }

    #[test]
    fn rejects_wireguard_quick_host_side_effects() {
        for key in [
            "DNS",
            "PreUp",
            "PostUp",
            "PreDown",
            "PostDown",
            "SaveConfig",
        ] {
            assert!(validate_config(&format!("{CONFIG}{key} = anything\n")).is_err());
        }
    }

    #[test]
    fn selects_pinned_release_assets_for_supported_architectures() {
        assert_eq!(release_asset("x86_64").unwrap().0, "server-linux-amd64");
        assert_eq!(release_asset("aarch64").unwrap().0, "server-linux-arm64");
        assert!(release_asset("riscv64").is_err());
    }

    #[test]
    fn rejects_wrong_or_failed_checksum() {
        let mut result = Output {
            status: ExitStatus::from_raw(0),
            stdout: b"digest  /path\n".to_vec(),
            stderr: vec![],
        };
        assert!(verify_digest(&result, "digest").is_ok());
        assert!(verify_digest(&result, "other").is_err());
        result.status = ExitStatus::from_raw(1 << 8);
        assert!(verify_digest(&result, "digest").is_err());
    }
}
