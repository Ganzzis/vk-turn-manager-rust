use base64::{engine::general_purpose, Engine};
use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use serde::{Deserialize, Serialize};
use std::ffi::{c_char, CStr, CString};
use std::net::{Ipv4Addr, SocketAddr};
use std::ptr;

mod relay;

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Profile {
    name: String,
    address: String,
    private_key: String,
    peer_public_key: String,
    preshared_key: Option<String>,
    endpoint: String,
    #[serde(rename = "allowedIPs")]
    allowed_ips: String,
    dns: Option<String>,
    transport: Transport,
    vk_link: Option<String>,
    relay: Option<relay::Credentials>,
}

#[derive(Clone, Copy, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
enum Transport {
    Direct,
    Srtp,
}

#[derive(Deserialize)]
struct Link {
    version: u32,
    #[serde(rename = "type")]
    kind: String,
    settings: LinkSettings,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LinkSettings {
    server_name: Option<String>,
    private_key: String,
    peer_public_key: String,
    preshared_key: Option<String>,
    tunnel_address: String,
    #[serde(rename = "allowedIPs")]
    allowed_ips: Option<String>,
    dns_servers: Option<String>,
    peer_address: String,
    vk_link: String,
    use_srtp: Option<bool>,
    use_wrap: Option<bool>,
    use_wrap_a: Option<bool>,
    use_wrap_s: Option<bool>,
    use_csqtt: Option<bool>,
}

fn key(text: &str) -> Option<[u8; 32]> {
    let key: [u8; 32] = general_purpose::STANDARD
        .decode(text)
        .ok()?
        .try_into()
        .ok()?;
    (key != [0; 32]).then_some(key)
}

fn cidr(text: &str) -> Option<(Ipv4Addr, u8)> {
    let (address, prefix) = text.split_once('/')?;
    let prefix = prefix.parse().ok()?;
    (prefix <= 32).then_some((address.parse().ok()?, prefix))
}

fn endpoint(text: &str) -> bool {
    if let Ok(address) = text.parse::<SocketAddr>() {
        return address.port() > 0
            && !address.ip().is_unspecified()
            && !address.ip().is_multicast();
    }
    let Some((host, port)) = text.rsplit_once(':') else {
        return false;
    };
    port.parse::<u16>().is_ok_and(|p| p > 0)
        && host.len() <= 253
        && host.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        })
}

fn vk_link(text: &str) -> bool {
    ["https://vk.ru/call/join/", "https://vk.com/call/join/"]
        .iter()
        .find_map(|prefix| text.strip_prefix(prefix))
        .is_some_and(|token| {
            !token.is_empty()
                && token.len() <= 512
                && token
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"_-".contains(&c))
        })
}

fn ipv4_routes(text: &str) -> Option<Vec<(u32, u32)>> {
    if text.len() > 1024 {
        return None;
    }
    text.split(',')
        .map(|part| {
            let (address, prefix) = cidr(part.trim())?;
            let mask = u32::MAX.checked_shl(32 - u32::from(prefix)).unwrap_or(0);
            Some((u32::from(address) & mask, mask))
        })
        .collect()
}

fn validate(p: &Profile) -> bool {
    !p.name.trim().is_empty()
        && p.name.chars().count() <= 64
        && !p.name.chars().any(char::is_control)
        && cidr(&p.address).is_some_and(|(ip, prefix)| {
            prefix > 0 && !ip.is_unspecified() && !ip.is_multicast() && !ip.is_loopback()
        })
        && key(&p.private_key).is_some()
        && key(&p.peer_public_key).is_some()
        && p.preshared_key
            .as_deref()
            .is_none_or(|value| key(value).is_some())
        && endpoint(&p.endpoint)
        && ipv4_routes(&p.allowed_ips).is_some()
        && p.dns.as_deref().is_none_or(|value| {
            value.len() <= 256
                && value
                    .split(',')
                    .all(|ip| ip.trim().parse::<Ipv4Addr>().is_ok())
        })
        && p.relay.as_ref().is_none_or(relay::Credentials::valid)
        && match p.transport {
            Transport::Direct => p.vk_link.is_none(),
            Transport::Srtp => p.vk_link.as_deref().is_some_and(vk_link),
        }
}

fn decode_link(uri: &str) -> Option<Profile> {
    if uri.len() > 8192 {
        return None;
    }
    let url = url::Url::parse(uri.trim()).ok()?;
    if url.scheme() != "vkturnproxy"
        || !matches!(url.host_str(), None | Some("import"))
        || !matches!(url.path(), "" | "/")
        || url.fragment().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.port().is_some()
    {
        return None;
    }
    // URLComponents, used by upstream, preserves literal '+' in standard
    // base64. Do the same before percent-decoding the query field.
    let raw_query = url.query()?.replace('+', "%2B");
    let mut query = url::form_urlencoded::parse(raw_query.as_bytes());
    let (field, data) = query.next()?;
    if field != "data" || query.next().is_some() {
        return None;
    }
    let bytes = [
        &general_purpose::URL_SAFE_NO_PAD,
        &general_purpose::URL_SAFE,
        &general_purpose::STANDARD_NO_PAD,
        &general_purpose::STANDARD,
    ]
    .iter()
    .find_map(|engine| engine.decode(data.as_bytes()).ok())?;
    let link: Link = serde_json::from_slice(&bytes).ok()?;
    let s = link.settings;
    if link.version != 1
        || link.kind != "connection"
        || s.use_srtp == Some(false)
        || [s.use_wrap, s.use_wrap_a, s.use_wrap_s, s.use_csqtt].contains(&Some(true))
    {
        return None;
    }
    let profile = Profile {
        name: s.server_name.unwrap_or_else(|| "VK TURN".into()),
        address: s.tunnel_address,
        private_key: s.private_key,
        peer_public_key: s.peer_public_key,
        preshared_key: s.preshared_key.filter(|value| !value.is_empty()),
        endpoint: s.peer_address,
        allowed_ips: s.allowed_ips.unwrap_or_else(|| "0.0.0.0/0".into()),
        dns: s.dns_servers.filter(|value| !value.is_empty()),
        transport: Transport::Srtp,
        vk_link: Some(s.vk_link),
        relay: None,
    };
    validate(&profile).then_some(profile)
}

struct Tunnel {
    wg: Tunn,
    routes: Vec<(u32, u32)>,
}

impl Tunnel {
    fn new(p: &Profile) -> Option<Self> {
        if (p.transport == Transport::Srtp && p.relay.is_none()) || !validate(p) {
            return None;
        }
        let private = StaticSecret::from(key(&p.private_key)?);
        let public = PublicKey::from(key(&p.peer_public_key)?);
        if PublicKey::from(&private).as_bytes() == public.as_bytes() {
            return None;
        }
        let psk = p.preshared_key.as_deref().and_then(key);
        Some(Self {
            wg: Tunn::new(private, public, psk, Some(25), 1, None),
            routes: ipv4_routes(&p.allowed_ips)?,
        })
    }

    fn step(&mut self, operation: i32, input: &[u8], output: &mut [u8]) -> (i32, usize) {
        let matches = |ip: Ipv4Addr| {
            let ip = u32::from(ip);
            self.routes
                .iter()
                .any(|&(network, mask)| ip & mask == network)
        };
        let result = match operation {
            0 => self.wg.format_handshake_initiation(output, false),
            1 if matches!(Tunn::dst_address(input), Some(std::net::IpAddr::V4(ip)) if matches(ip)) => {
                self.wg.encapsulate(input, output)
            }
            2 => self.wg.decapsulate(None, input, output),
            3 => self.wg.update_timers(output),
            _ => return (0, 0),
        };
        match result {
            TunnResult::WriteToNetwork(data) => (1, data.len()),
            TunnResult::WriteToTunnelV4(data, source) if matches(source) => (2, data.len()),
            _ => (0, 0),
        }
    }
}

unsafe fn input_text<'a>(value: *const c_char) -> Option<&'a str> {
    if value.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(value) }.to_str().ok()
}

unsafe fn profile(value: *const c_char) -> Option<Profile> {
    serde_json::from_str(unsafe { input_text(value) }?).ok()
}

#[no_mangle]
pub unsafe extern "C" fn vkt_validate(value: *const c_char) -> i32 {
    i32::from(unsafe { profile(value) }.is_some_and(|p| validate(&p)))
}

fn connection_preflight(p: &Profile, now: std::time::SystemTime) -> i32 {
    if !validate(p) {
        return 0;
    }
    if p.transport == Transport::Direct {
        return 1;
    }
    match &p.relay {
        None => -1,
        Some(credentials) if credentials.remaining_at(now).is_none() => -2,
        Some(_) => 1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn vkt_connection_preflight(value: *const c_char) -> i32 {
    unsafe { profile(value) }.map_or(0, |p| {
        connection_preflight(&p, std::time::SystemTime::now())
    })
}

#[no_mangle]
pub unsafe extern "C" fn vkt_import(value: *const c_char) -> *mut c_char {
    unsafe { input_text(value) }
        .and_then(decode_link)
        .and_then(|p| serde_json::to_string(&p).ok())
        .and_then(|json| CString::new(json).ok())
        .map_or(ptr::null_mut(), CString::into_raw)
}

#[no_mangle]
pub unsafe extern "C" fn vkt_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

#[no_mangle]
pub unsafe extern "C" fn vkt_tunnel_new(value: *const c_char) -> *mut std::ffi::c_void {
    unsafe { profile(value) }
        .and_then(|p| Tunnel::new(&p))
        .map_or(ptr::null_mut(), |t| Box::into_raw(Box::new(t)).cast())
}

#[no_mangle]
pub unsafe extern "C" fn vkt_tunnel_free(tunnel: *mut std::ffi::c_void) {
    if !tunnel.is_null() {
        drop(unsafe { Box::from_raw(tunnel.cast::<Tunnel>()) });
    }
}

#[no_mangle]
pub unsafe extern "C" fn vkt_tunnel_ready(tunnel: *mut std::ffi::c_void) -> i32 {
    i32::from(
        unsafe { tunnel.cast::<Tunnel>().as_ref() }
            .is_some_and(|t| t.wg.time_since_last_handshake().is_some()),
    )
}

#[no_mangle]
pub unsafe extern "C" fn vkt_tunnel_step(
    tunnel: *mut std::ffi::c_void,
    operation: i32,
    input: *const u8,
    input_len: usize,
    output: *mut u8,
    output_len: usize,
    written: *mut usize,
) -> i32 {
    let Some(tunnel) = (unsafe { tunnel.cast::<Tunnel>().as_mut() }) else {
        return -1;
    };
    if output.is_null()
        || written.is_null()
        || output_len < 2048
        || input_len > 1536
        || (input_len != 0 && input.is_null())
    {
        return -1;
    }
    let input = if input_len == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(input, input_len) }
    };
    let output = unsafe { std::slice::from_raw_parts_mut(output, 2048) };
    let (event, count) = tunnel.step(operation, input, output);
    unsafe {
        *written = count;
    }
    event
}

#[cfg(test)]
mod tests {
    use super::*;

    fn direct() -> Profile {
        let private = [17; 32];
        let peer = PublicKey::from(&StaticSecret::from([29; 32]));
        Profile {
            name: "Fixture".into(),
            address: "192.0.2.2/32".into(),
            private_key: general_purpose::STANDARD.encode(private),
            peer_public_key: general_purpose::STANDARD.encode(peer.as_bytes()),
            preshared_key: None,
            endpoint: "wg.example:51820".into(),
            allowed_ips: "0.0.0.0/0".into(),
            dns: None,
            transport: Transport::Direct,
            vk_link: None,
            relay: None,
        }
    }

    #[test]
    fn preflight_separates_import_from_connect_and_checks_expiry() {
        use std::time::{Duration, UNIX_EPOCH};

        let now = UNIX_EPOCH + Duration::from_secs(100_000);
        assert_eq!(connection_preflight(&direct(), now), 1);
        let uri = include_str!("../../../tests/fixtures/upstream-ios-import.url").trim();
        let mut imported = decode_link(uri).unwrap();
        assert_eq!(connection_preflight(&imported, now), -1);
        for (expires_at, expected) in [
            (99_999, -2),
            (100_030, -2),
            (100_031, 1),
            (186_400, 1),
            (186_401, -2),
        ] {
            imported.relay = serde_json::from_value(serde_json::json!({
                "address": "turn.example:3478", "username": "synthetic",
                "password": "synthetic", "expiresAt": expires_at.to_string()
            }))
            .unwrap();
            assert_eq!(connection_preflight(&imported, now), expected);
        }
    }

    #[test]
    fn imports_upstream_v1_fixture() {
        let uri = include_str!("../../../tests/fixtures/upstream-ios-import.url").trim();
        let imported = decode_link(uri).unwrap();
        assert!(imported.transport == Transport::Srtp);
        assert_eq!(imported.name, "demo");
        assert_eq!(imported.address, "172.21.7.2/32");
        assert_eq!(imported.endpoint, "srtp.example:56004");
        assert_eq!(imported.allowed_ips, "0.0.0.0/0");
        assert!(imported.relay.is_none());
        assert_eq!(
            imported.vk_link.as_deref(),
            Some("https://vk.ru/call/join/synthetic")
        );
        assert!(Tunnel::new(&imported).is_none());
    }

    #[test]
    fn imports_verified_shape_and_requires_srtp_relay_credentials() {
        let p = direct();
        let fixture = serde_json::json!({"type":"connection","version":1,"settings":{
            "serverName":p.name, "tunnelAddress":p.address, "privateKey":p.private_key,
            "peerPublicKey":p.peer_public_key, "peerAddress":"srtp.example:56004",
            "vkLink":"https://vk.ru/call/join/synthetic","useSrtp":true,"allowedIPs":"198.51.100.0/24"}});
        let payload = general_purpose::URL_SAFE_NO_PAD.encode(fixture.to_string());
        let uri = format!("vkturnproxy://import?data={payload}");
        let imported = decode_link(&uri).unwrap();
        assert!(imported.transport == Transport::Srtp);
        assert_eq!(imported.allowed_ips, "198.51.100.0/24");
        let json = serde_json::to_value(&imported).unwrap();
        assert_eq!(json["allowedIPs"], "198.51.100.0/24");
        assert!(json.get("allowedIps").is_none());
        assert!(Tunnel::new(&imported).is_none());
        assert!(decode_link(&format!("{uri}&data={payload}")).is_none());
        assert!(decode_link(&uri.replace("import", "other")).is_none());
        assert!(decode_link(&format!("vkturnproxy:?data={payload}")).is_some());
        let standard = general_purpose::STANDARD.encode(fixture.to_string());
        assert!(decode_link(&format!("vkturnproxy://import?data={standard}")).is_some());
    }

    #[test]
    fn validates_ipv4_routes_keys_and_endpoints() {
        let mut p = direct();
        assert!(validate(&p));
        p.allowed_ips = "::/0".into();
        assert!(!validate(&p));
        assert!(endpoint("[2001:db8::1]:51820"));
        assert!(!endpoint("wg.example:0"));
        assert!(!endpoint("0.0.0.0:51820"));
        assert!(!endpoint("wg.example:51820\nPrivateKey=x"));
        assert!(key("not-a-key").is_none());
    }

    #[test]
    fn performs_real_wireguard_handshake_and_transports_ipv4() {
        let mut legacy = serde_json::to_value(direct()).unwrap();
        legacy.as_object_mut().unwrap().remove("relay");
        let client: Profile = serde_json::from_value(legacy).unwrap();
        assert!(client.transport == Transport::Direct && client.relay.is_none());
        let mut server = direct();
        server.private_key = general_purpose::STANDARD.encode([29; 32]);
        server.peer_public_key = general_purpose::STANDARD
            .encode(PublicKey::from(&StaticSecret::from([17; 32])).as_bytes());
        let mut a = Tunnel::new(&client).unwrap();
        let mut b = Tunnel::new(&server).unwrap();
        let mut left = [0; 2048];
        let mut right = [0; 2048];
        assert!(a.wg.time_since_last_handshake().is_none());
        let (1, n) = a.step(0, &[], &mut left) else {
            panic!("client initiation");
        };
        let (1, n) = b.step(2, &left[..n], &mut right) else {
            panic!("server response");
        };
        let (1, n) = a.step(2, &right[..n], &mut left) else {
            panic!("client confirmation");
        };
        b.step(2, &left[..n], &mut right);
        assert!(a.wg.time_since_last_handshake().is_some());
        let mut ip = [0; 20];
        ip[0] = 0x45;
        ip[3] = 20;
        ip[12..16].copy_from_slice(&[192, 0, 2, 2]);
        ip[16..20].copy_from_slice(&[192, 0, 2, 1]);
        let (1, n) = a.step(1, &ip, &mut left) else {
            panic!("encrypted data");
        };
        let (2, n) = b.step(2, &left[..n], &mut right) else {
            panic!("decrypted data");
        };
        assert_eq!(&right[..n], &ip);

        ip[12..16].copy_from_slice(&[192, 0, 2, 1]);
        ip[16..20].copy_from_slice(&[192, 0, 2, 2]);
        let (1, n) = b.step(1, &ip, &mut right) else {
            panic!("encrypted reply");
        };
        let (2, n) = a.step(2, &right[..n], &mut left) else {
            panic!("decrypted reply");
        };
        assert_eq!(&left[..n], &ip);
    }
}
