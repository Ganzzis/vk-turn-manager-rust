use crate::{lock_clients, output, Result, CONFIG};
use serde_json::{json, Value};
use std::fs::{self, DirBuilder, File};
use std::io::{self, Read, Write};
use std::net::{IpAddr, Ipv4Addr};
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use tempfile::NamedTempFile;

mod ios;

const PROFILES: &str = "/var/lib/vk-turn-clients";
const EXTERNAL_CONFIG: &str = "/etc/wireguard/wg-vk.conf";
const BEGIN: &str = "# vk-turn-manager client: ";
const END: &str = "# vk-turn-manager end client\n";

#[derive(Clone, Copy, PartialEq, Eq)]
struct Range {
    first: u32,
    last: u32,
}

fn ipv4_range(cidr: &str) -> Result<Option<Range>> {
    let (address, bits) = cidr.split_once('/').ok_or("Invalid peer network")?;
    let bits: u8 = bits.parse().map_err(|_| "Invalid peer prefix length")?;
    match address
        .parse::<IpAddr>()
        .map_err(|_| "Invalid peer address")?
    {
        IpAddr::V4(address) if bits <= 32 => {
            let mask = u32::MAX.checked_shl(32 - u32::from(bits)).unwrap_or(0);
            let first = u32::from(address) & mask;
            Ok(Some(Range {
                first,
                last: first | !mask,
            }))
        }
        IpAddr::V6(_) if bits <= 128 => Ok(None),
        _ => Err("Invalid peer prefix length".into()),
    }
}

pub(super) fn check_setup_subnet() -> Result<()> {
    let routes = output("ip", &["-j", "-4", "route", "show", "table", "all"])?;
    if !routes.status.success() {
        return Err("Не удалось проверить существующие IPv4-маршруты".into());
    }
    let routes: Vec<Value> = serde_json::from_slice(&routes.stdout)?;
    let candidate = ipv4_range("10.77.0.0/24")?.unwrap();
    for dst in routes.iter().filter_map(|route| route["dst"].as_str()) {
        if matches!(dst, "default" | "0.0.0.0/0") {
            continue;
        }
        let host;
        let cidr = if dst.contains('/') {
            dst
        } else {
            host = format!("{dst}/32");
            &host
        };
        if ipv4_range(cidr)?
            .is_some_and(|route| route.first <= candidate.last && candidate.first <= route.last)
        {
            return Err(
                "Подсеть 10.77.0.0/24 занята. Используйте install со своим wg-vk.conf".into(),
            );
        }
    }
    Ok(())
}

fn allocate(subnet: Range, server: Ipv4Addr, mut used: Vec<Range>) -> Result<Ipv4Addr> {
    let server = u32::from(server);
    used.push(Range {
        first: server,
        last: server,
    });
    used.sort_unstable_by_key(|range| range.first);
    let mut next = subnet
        .first
        .checked_add(1)
        .ok_or("Client subnet is exhausted")?;
    for range in used {
        if next < range.first {
            break;
        }
        if next <= range.last {
            next = range
                .last
                .checked_add(1)
                .ok_or("Client subnet is exhausted")?;
        }
    }
    if next >= subnet.last {
        return Err("Client subnet is exhausted".into());
    }
    Ok(Ipv4Addr::from(next))
}

fn validate_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name.len() > 32
        || !name.as_bytes()[0].is_ascii_lowercase() && !name.as_bytes()[0].is_ascii_digit()
        || !name
            .bytes()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'-')
    {
        return Err("Client name must be 1–32 lowercase letters, digits or hyphens, starting with a letter or digit".into());
    }
    Ok(())
}

fn valid_key(key: &str) -> bool {
    use base64::{engine::general_purpose::STANDARD, Engine};
    STANDARD.decode(key).is_ok_and(|data| data.len() == 32)
}

struct Peer {
    name: String,
    public: String,
    ip: Ipv4Addr,
}

impl Peer {
    fn block(&self) -> String {
        format!(
            "{BEGIN}{}\n[Peer]\nPublicKey = {}\nAllowedIPs = {}/32\n{END}",
            self.name, self.public, self.ip
        )
    }

    fn json(&self) -> Value {
        json!({"name": self.name, "public_key": self.public, "ipv4": self.ip})
    }
}

struct Config {
    path: &'static str,
    text: String,
    peers: Vec<Peer>,
    ranges: Vec<Range>,
    addresses: Vec<String>,
    public_keys: Vec<String>,
}

fn private_file(path: &Path, root_owned: bool) -> Result<File> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || metadata.mode() & 0o077 != 0 || (root_owned && metadata.uid() != 0) {
        return Err("Expected a regular, owner-only file with the correct owner".into());
    }
    let file = File::open(path)?;
    let opened = file.metadata()?;
    if (metadata.dev(), metadata.ino()) != (opened.dev(), opened.ino()) {
        return Err("File changed while opening it".into());
    }
    Ok(file)
}

fn read_private(path: &Path, root_owned: bool) -> Result<String> {
    use std::io::Read;
    let mut text = String::new();
    private_file(path, root_owned)?.read_to_string(&mut text)?;
    Ok(text)
}

impl Config {
    fn load() -> Result<Self> {
        let mut found = Vec::new();
        for path in [CONFIG, EXTERNAL_CONFIG] {
            match fs::symlink_metadata(path) {
                Ok(_) => found.push(path),
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        }
        let [path] = found.as_slice() else {
            return Err("Expected exactly one persistent wg-vk.conf in /etc/vk-turn-manager or /etc/wireguard".into());
        };
        let dir = fs::metadata(Path::new(path).parent().unwrap())?;
        if dir.uid() != 0 || dir.mode() & 0o022 != 0 {
            return Err(
                "WireGuard config directory must be owned and writable only by root".into(),
            );
        }
        Self::parse(path, read_private(Path::new(path), true)?)
    }

    fn parse(path: &'static str, text: String) -> Result<Self> {
        let mut peers: Vec<Peer> = Vec::new();
        let mut ranges = Vec::new();
        let mut addresses = Vec::new();
        let mut public_keys = Vec::new();
        let mut section = "";
        let lines: Vec<_> = text.lines().collect();
        for (i, line) in lines.iter().enumerate() {
            if let Some(name) = line.strip_prefix(BEGIN) {
                validate_name(name)?;
                let block = lines.get(i..i + 5).ok_or("Incomplete managed peer block")?;
                let public = block[2]
                    .strip_prefix("PublicKey = ")
                    .filter(|key| valid_key(key))
                    .ok_or("Managed peer block has changed")?;
                let ip = block[3]
                    .strip_prefix("AllowedIPs = ")
                    .and_then(|x| x.strip_suffix("/32"))
                    .ok_or("Managed peer block has changed")?
                    .parse()?;
                let peer = Peer {
                    name: name.to_owned(),
                    public: public.to_owned(),
                    ip,
                };
                let trailing = lines[i + 5..]
                    .iter()
                    .map(|line| line.trim())
                    .take_while(|line| !line.starts_with('['));
                if block.concat() != peer.block().lines().collect::<String>()
                    || trailing
                        .into_iter()
                        .any(|line| !line.is_empty() && !line.starts_with('#'))
                    || !text.contains(&peer.block())
                    || peers
                        .iter()
                        .any(|p| p.name == name || p.public == public || p.ip == ip)
                {
                    return Err("Managed peer block has changed or is duplicated".into());
                }
                peers.push(peer);
            }
            let cleaned = line.split('#').next().unwrap_or("").trim();
            if cleaned.starts_with('[') {
                section = cleaned;
            }
            let Some((key, value)) = cleaned.split_once('=') else {
                continue;
            };
            let key = key.trim();
            if section.eq_ignore_ascii_case("[Interface]") {
                if key.eq_ignore_ascii_case("SaveConfig") {
                    return Err("Remove SaveConfig before managing peers; wg-quick can overwrite ownership markers".into());
                }
                if key.eq_ignore_ascii_case("Address") {
                    addresses.extend(value.split(',').map(|address| address.trim().to_owned()));
                }
            }
            if section.eq_ignore_ascii_case("[Peer]") {
                if key.eq_ignore_ascii_case("PublicKey") {
                    public_keys.push(value.trim().to_owned());
                }
                if key.eq_ignore_ascii_case("AllowedIPs") {
                    for cidr in value
                        .split(',')
                        .map(str::trim)
                        .filter(|cidr| !cidr.is_empty())
                    {
                        if let Some(range) = ipv4_range(cidr)? {
                            ranges.push(range);
                        }
                    }
                }
            }
        }
        for peer in &peers {
            if public_keys
                .iter()
                .filter(|key| *key == &peer.public)
                .count()
                != 1
            {
                return Err("Managed public key also appears in another peer block".into());
            }
        }
        Ok(Self {
            path,
            text,
            peers,
            ranges,
            addresses,
            public_keys,
        })
    }

    fn peer(&self, name: &str) -> Result<&Peer> {
        self.peers
            .iter()
            .find(|peer| peer.name == name)
            .ok_or_else(|| "Managed client not found".into())
    }
}

fn wg(args: &[&str]) -> Result<String> {
    let result = output("wg", args)?;
    if !result.status.success() {
        // wg errors can include config and key material. Never forward its stderr.
        return Err(format!("wg {} failed ({})", args[0], result.status).into());
    }
    Ok(String::from_utf8(result.stdout)?)
}

fn pubkey(private: &str) -> Result<String> {
    let mut command = Command::new("wg")
        .arg("pubkey")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    command
        .stdin
        .take()
        .ok_or("Could not open wg stdin")?
        .write_all(private.as_bytes())?;
    let result = command.wait_with_output()?;
    let key = String::from_utf8(result.stdout)?;
    if !result.status.success() || !valid_key(key.trim()) {
        return Err("wg pubkey failed".into());
    }
    Ok(key.trim().to_owned())
}

fn server_subnet(config: &Config) -> Result<(Ipv4Addr, Range)> {
    let result = output("ip", &["-4", "-o", "address", "show", "dev", "wg-vk"])?;
    if !result.status.success() {
        return Err("Could not read runtime IPv4 address for wg-vk".into());
    }
    let text = String::from_utf8(result.stdout)?;
    let fields: Vec<_> = text.split_whitespace().collect();
    let addresses: Vec<_> = fields
        .windows(2)
        .filter(|x| x[0] == "inet")
        .map(|x| x[1])
        .collect();
    let [address] = addresses.as_slice() else {
        return Err("wg-vk must have exactly one active IPv4 subnet".into());
    };
    let persistent: Vec<_> = config
        .addresses
        .iter()
        .filter(|x| !x.contains(':'))
        .collect();
    if persistent.len() != 1 || persistent[0] != address {
        return Err("The persistent and runtime IPv4 addresses of wg-vk differ".into());
    }
    let server = address.split('/').next().unwrap().parse()?;
    let range = ipv4_range(address)?.ok_or("No IPv4 subnet")?;
    if range.last.saturating_sub(range.first) < 3 || range.first == 0 && range.last == u32::MAX {
        return Err(
            "wg-vk subnet must have usable host addresses and cannot be the default route".into(),
        );
    }
    Ok((server, range))
}

fn runtime_peers() -> Result<Vec<(String, Vec<String>)>> {
    wg(&["show", "wg-vk", "allowed-ips"])?
        .lines()
        .map(|line| {
            let (public, ips) = line
                .split_once(char::is_whitespace)
                .ok_or("Invalid wg peer output")?;
            let ips = ips
                .split(|c: char| c.is_whitespace() || c == ',')
                .filter(|item| !item.is_empty() && *item != "(none)")
                .map(str::to_owned)
                .collect();
            Ok((public.to_owned(), ips))
        })
        .collect()
}

fn apply(peer: &Peer, add: bool) -> Result<()> {
    let cidr = format!("{}/32", peer.ip);
    let mut args = vec!["set", "wg-vk", "peer", &peer.public];
    if add {
        args.extend(["allowed-ips", &cidr]);
    } else {
        args.push("remove");
    }
    wg(&args)?;
    Ok(())
}

fn stage(path: &Path, content: &[u8]) -> Result<NamedTempFile> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let mut file = NamedTempFile::new_in(parent)?;
    file.write_all(content)?;
    file.as_file().sync_all()?;
    Ok(file)
}

fn write_export(path: &Path, content: &str) -> Result<()> {
    stage(path, content.as_bytes())?
        .persist_noclobber(path)
        .map_err(|error| error.error)?;
    Ok(())
}

fn profile(name: &str, create: bool) -> Result<PathBuf> {
    if create {
        match DirBuilder::new().mode(0o700).create(PROFILES) {
            Ok(()) => File::open(Path::new(PROFILES).parent().unwrap())?.sync_all()?,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
    }
    let directory = fs::symlink_metadata(PROFILES)?;
    if !directory.is_dir() || directory.uid() != 0 || directory.mode() & 0o077 != 0 {
        return Err("Client key directory must be root-owned and owner-only".into());
    }
    Ok(Path::new(PROFILES).join(name))
}

fn update(
    config: &Config,
    replacement: &str,
    peer: &Peer,
    add: bool,
    runtime_present: bool,
) -> Result<()> {
    let path = Path::new(config.path);
    let original = private_file(path, true)?.metadata()?;
    let staged = stage(path, replacement.as_bytes())?;
    std::os::unix::fs::chown(staged.path(), None, Some(original.gid()))?;
    use std::os::unix::fs::PermissionsExt;
    staged
        .as_file()
        .set_permissions(fs::Permissions::from_mode(original.mode() & 0o777))?;
    staged.as_file().sync_all()?;
    let changed_runtime = add || runtime_present;
    let attempt = (|| {
        if changed_runtime {
            apply(peer, add)?;
        }
        if read_private(path, true)? != config.text {
            return Err(
                "WireGuard config changed during the update; retry after reconciling".into(),
            );
        }
        staged.persist(path).map_err(|error| error.error)?;
        Ok(())
    })();
    if let Err(error) = attempt {
        if changed_runtime {
            if let Err(rollback) = apply(peer, !add) {
                return Err(format!("{error}; peer rollback failed: {rollback}").into());
            }
        }
        return Err(error);
    }
    File::open(path.parent().unwrap())?.sync_all()?;
    Ok(())
}

fn add(config: &Config, name: &str) -> Result<Value> {
    if config.peers.iter().any(|peer| peer.name == name) {
        return Err("Client name already exists".into());
    }
    let (server, subnet) = server_subnet(config)?;
    let runtime = runtime_peers()?;
    let mut ranges = config.ranges.clone();
    for (_, ips) in &runtime {
        for ip in ips {
            ranges.extend(ipv4_range(ip)?);
        }
    }
    let ip = allocate(subnet, server, ranges)?;
    let private = wg(&["genkey"])?;
    let public = pubkey(&private)?;
    if config.public_keys.contains(&public) || runtime.iter().any(|(key, _)| key == &public) {
        return Err("Generated public key already exists".into());
    }
    let peer = Peer {
        name: name.to_owned(),
        public,
        ip,
    };
    let key_path = profile(name, true)?;
    write_export(&key_path, &private)?;
    File::open(PROFILES)?.sync_all()?;
    if let Err(error) = update(
        config,
        &format!("{}\n\n{}", config.text, peer.block()),
        &peer,
        true,
        false,
    ) {
        // Preserve the key if the commit succeeded and only the directory sync failed.
        if read_private(Path::new(config.path), true).is_ok_and(|current| current == config.text) {
            if let Err(cleanup) = fs::remove_file(key_path) {
                return Err(
                    format!("{error}; could not remove the unused client key: {cleanup}").into(),
                );
            }
        }
        return Err(error);
    }
    Ok(peer.json())
}

fn remove(config: &Config, name: &str) -> Result<Value> {
    let peer = config.peer(name)?;
    let key_path = match fs::symlink_metadata(PROFILES) {
        Ok(_) => Some(profile(name, false)?),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(error.into()),
    };
    let runtime = runtime_peers()?;
    let present = runtime.iter().find(|(key, _)| key == &peer.public);
    if let Some((_, ips)) = present {
        if ips != &[format!("{}/32", peer.ip)] {
            return Err("Managed peer runtime AllowedIPs differ; reconcile before revoking".into());
        }
    }
    let replacement = config
        .text
        .replacen(&format!("\n\n{}", peer.block()), "", 1);
    if replacement == config.text {
        return Err("Managed peer block was moved or edited; reconcile before revoking".into());
    }
    update(config, &replacement, peer, false, present.is_some())?;
    if let Some(key_path) = key_path {
        match fs::remove_file(key_path) {
            Ok(()) => File::open(PROFILES)?.sync_all()?,
            Err(err) if err.kind() == io::ErrorKind::NotFound => {}
            Err(err) => {
                return Err(
                    format!("Peer revoked but retained key could not be deleted: {err}").into(),
                );
            }
        }
    }
    Ok(peer.json())
}

fn validate_endpoint(endpoint: &str) -> Result<()> {
    use std::net::SocketAddr;
    if endpoint
        .parse::<SocketAddr>()
        .is_ok_and(|addr| addr.port() > 0)
    {
        return Ok(());
    }
    let (host, port) = endpoint
        .rsplit_once(':')
        .ok_or("Endpoint must be host:port or [IPv6]:port")?;
    if host.len() > 253
        || host.split('.').any(|label| {
            label.is_empty()
                || label.len() > 63
                || label.starts_with('-')
                || label.ends_with('-')
                || !label
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        })
        || !port.parse::<u16>().is_ok_and(|port| port > 0)
    {
        return Err("Invalid endpoint".into());
    }
    Ok(())
}

fn export(
    config: &Config,
    name: &str,
    format: &str,
    endpoint: &str,
    link: Option<&Path>,
    target: &Path,
) -> Result<Value> {
    let peer = config.peer(name)?;
    validate_endpoint(endpoint)?;
    let private = read_private(&profile(name, false)?, true)?;
    if !valid_key(private.trim()) || pubkey(&private)? != peer.public {
        return Err("Stored client key does not match the managed peer".into());
    }
    let public = wg(&["show", "wg-vk", "public-key"])?;
    if !valid_key(public.trim()) {
        return Err("wg-vk does not have a valid server public key".into());
    }
    let content = if format == "wireguard" {
        format!("[Interface]\nPrivateKey = {}\nAddress = {}/32\n\n[Peer]\nPublicKey = {}\nEndpoint = {endpoint}\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n", private.trim(), peer.ip, public.trim())
    } else {
        let link = read_private(link.ok_or("Specify a protected VK link file")?, false)?;
        ios::link(peer, private.trim(), public.trim(), endpoint, link.trim())?
    };
    write_export(target, &content)?;
    Ok(json!({"name": name, "format": format, "written": true}))
}

pub(super) fn qr(source: &Path, target: &Path) -> Result<Value> {
    let mut link = String::new();
    private_file(source, false)?
        .take(4097)
        .read_to_string(&mut link)?;
    let payload = link.trim().strip_prefix("vkturnproxy://import?data=");
    if link.len() > 4096
        || !payload.is_some_and(|data| {
            !data.is_empty()
                && data
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte))
        })
    {
        return Err("Ожидается ссылка VK TURN Proxy, созданная командой client export".into());
    }
    let mut encoder = Command::new("qrencode")
        .args(["-t", "PNG", "-o", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let written = encoder
        .stdin
        .take()
        .ok_or("No QR input pipe")?
        .write_all(link.trim().as_bytes());
    let result = encoder.wait_with_output()?;
    written?;
    if !result.status.success() || !result.stdout.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Err("Не удалось создать QR-код. Проверьте ссылку и наличие qrencode".into());
    }
    stage(target, &result.stdout)?
        .persist_noclobber(target)
        .map_err(|error| error.error)?;
    Ok(json!({"format": "png", "written": true}))
}

pub fn command(args: &[std::ffi::OsString]) -> Result<()> {
    println!("{}", execute(args)?);
    Ok(())
}

pub(super) fn execute(args: &[std::ffi::OsString]) -> Result<Value> {
    if let [cmd, source, flag, target] = args {
        if cmd == "qr" && flag == "--output" {
            return qr(Path::new(source), Path::new(target));
        }
    }
    let _lock = lock_clients()?;
    fn argument(arg: &std::ffi::OsStr) -> std::result::Result<&str, &'static str> {
        arg.to_str().ok_or("Expected a UTF-8 command argument")
    }
    let config = Config::load()?;
    let result = match args {
        [cmd] if cmd == "list" => json!(config.peers.iter().map(Peer::json).collect::<Vec<_>>()),
        [cmd, name] if cmd == "add" || cmd == "remove" => {
            let name = argument(name)?;
            validate_name(name)?;
            if cmd == "add" {
                add(&config, name)?
            } else {
                remove(&config, name)?
            }
        }
        [cmd, name, flag, endpoint, out, path]
            if cmd == "export" && flag == "--wg-endpoint" && out == "--output" =>
        {
            let name = argument(name)?;
            validate_name(name)?;
            export(
                &config,
                name,
                "wireguard",
                argument(endpoint)?,
                None,
                Path::new(path),
            )?
        }
        [cmd, name, flag, endpoint, vk, link, out, path]
            if cmd == "export"
                && flag == "--srtp-endpoint"
                && vk == "--vk-link-file"
                && out == "--output" =>
        {
            let name = argument(name)?;
            validate_name(name)?;
            export(
                &config,
                name,
                "ios",
                argument(endpoint)?,
                Some(Path::new(link)),
                Path::new(path),
            )?
        }
        _ => return Err("Invalid client command; see vk-turn-manager --help".into()),
    };
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allocation_skips_disk_runtime_and_server_ranges_and_exhausts() {
        let subnet = ipv4_range("172.21.7.1/29").unwrap().unwrap();
        let server = "172.21.7.1".parse().unwrap();
        let range = |cidr| ipv4_range(cidr).unwrap().unwrap();
        let occupied = vec![range("172.21.7.2/31"), range("172.21.7.4/32")];
        assert_eq!(
            allocate(subnet, server, occupied).unwrap().to_string(),
            "172.21.7.5"
        );
        assert!(allocate(subnet, server, vec![range("0.0.0.0/0")]).is_err());
        assert!(ipv4_range("fd00::/64").unwrap().is_none());
        assert!(ipv4_range("172.21.7.2/99").is_err());
    }

    fn synthetic() -> Peer {
        Peer {
            name: "demo".to_owned(),
            public: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=".to_owned(),
            ip: Ipv4Addr::new(172, 21, 7, 2),
        }
    }

    #[test]
    fn parser_preserves_unmanaged_entries_and_rejects_drift() {
        let peer = synthetic();
        let original =
            "[Interface]\nAddress = 172.21.7.1/29\n[Peer]\n# unowned\nAllowedIPs = 172.21.7.4/31\n";
        let text = format!("{original}\n\n{}", peer.block());
        let config = Config::parse(CONFIG, text.clone()).unwrap();
        assert_eq!(config.peers.len(), 1);
        assert_eq!(config.ranges.len(), 2);
        assert_eq!(
            config.text.replace(&format!("\n\n{}", peer.block()), ""),
            original
        );
        assert!(Config::parse(CONFIG, format!("{text}PresharedKey = fixture\n")).is_err());
        assert!(Config::parse(CONFIG, format!("{text}{}", peer.block())).is_err());
        assert!(Config::parse(
            CONFIG,
            text.replace("AllowedIPs = 172.21.7.2/32", "AllowedIPs = 172.21.7.2/24")
        )
        .is_err());
        assert!(Config::parse(CONFIG, "[Interface]\nSaveConfig = true\n".into()).is_err());
    }

    #[test]
    fn validates_cli_names_and_endpoints() {
        for name in ["demo", "demo-2", "123"] {
            assert!(validate_name(name).is_ok());
        }
        for name in ["", "../demo", "Demo", "-test", "foo\nbar"] {
            assert!(validate_name(name).is_err());
        }
        for endpoint in ["wg.example:51820", "203.0.113.1:56004", "[2001:db8::1]:443"] {
            assert!(validate_endpoint(endpoint).is_ok());
        }
        for endpoint in ["", "a:0", "x:99999", "x:1\nAllowedIPs=x", "https://x:1"] {
            assert!(validate_endpoint(endpoint).is_err());
        }
    }

    #[test]
    fn protected_output_is_exclusive_and_rejects_symlinks() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("profile");
        write_export(&path, "fixture").unwrap();
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
        assert!(write_export(&path, "different").is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "fixture");
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(write_export(&link, "different").is_err());
    }

    #[test]
    fn ios_payload_matches_upstream_connection_link_fields() {
        let peer = synthetic();
        let link = ios::link(
            &peer,
            "ERERERERERERERERERERERERERERERERERERERERERE=",
            "HR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0=",
            "srtp.example:56004",
            "https://vk.ru/call/join/synthetic",
        )
        .unwrap();
        assert_eq!(
            link,
            include_str!("../tests/fixtures/upstream-ios-import.url")
        );
        assert!(ios::link(
            &peer,
            "fixture-private",
            "fixture-public",
            "srtp.example:56004",
            "https://other.test/secret"
        )
        .is_err());
    }
}
