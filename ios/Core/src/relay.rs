//! RFC 5766 TURN, RFC 5764 DTLS-SRTP and the upstream RTP type-100 envelope.
//! WireGuard authentication stays in the caller; relay readiness is not VPN readiness.
use super::{endpoint, profile, validate, Transport};
use async_trait::async_trait;
use dtls::{
    config::{Config, ExtendedMasterSecretType},
    conn::DTLSConn,
    crypto::Certificate,
    extension::extension_use_srtp::SrtpProtectionProfile,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use srtp::{
    config::Config as SrtpConfig, context::Context, option::srtp_replay_protection,
    protection_profile::ProtectionProfile,
};
use std::{
    ffi::{c_char, c_void},
    io,
    net::SocketAddr,
    ptr,
    sync::{
        atomic::{AtomicI32, Ordering},
        Arc,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    net::{lookup_host, UdpSocket},
    sync::{mpsc, oneshot, Mutex},
    time::timeout,
};
use turn::client::{Client, ClientConfig};
use util::Conn;
#[path = "relay_tcp.rs"]
mod tcp;

const LIMIT: usize = 1400;
const QUEUE: usize = 64;
const PROFILE: SrtpProtectionProfile = SrtpProtectionProfile::Srtp_Aes128_Cm_Hmac_Sha1_80;
const INITIALIZING: i32 = 0;
const READY: i32 = 1;
const NEED_CREDENTIALS: i32 = -2;
const TURN_FAILED: i32 = -3;
const DTLS_FAILED: i32 = -4;
const RELAY_LOST: i32 = -5;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Credentials {
    address: String,
    username: String,
    password: String,
    expires_at: String,
    certificate_sha256: Option<String>,
    use_tcp: Option<bool>,
}

impl Credentials {
    pub(super) fn valid(&self) -> bool {
        endpoint(&self.address)
            && !self.username.is_empty()
            && self.username.len() <= 512
            && !self.password.is_empty()
            && self.password.len() <= 512
            && !self
                .username
                .chars()
                .chain(self.password.chars())
                .any(char::is_control)
            && self.expires_at.parse::<u64>().is_ok()
            && self
                .certificate_sha256
                .as_ref()
                .is_none_or(|pin| pin.len() == 64 && pin.bytes().all(|b| b.is_ascii_hexdigit()))
    }

    fn expiry(&self) -> Option<Duration> {
        let expiry = Duration::from_secs(self.expires_at.parse().ok()?);
        expiry.checked_sub(SystemTime::now().duration_since(UNIX_EPOCH).ok()?)
    }
}

fn connection_error(message: &'static str) -> util::Error {
    io::Error::new(io::ErrorKind::ConnectionAborted, message).into()
}

struct DtlsLane {
    socket: Arc<dyn Conn + Send + Sync>,
    peer: SocketAddr,
    incoming: Mutex<mpsc::Receiver<Vec<u8>>>,
}

#[async_trait]
impl Conn for DtlsLane {
    fn as_any(&self) -> &(dyn std::any::Any + Send + Sync) {
        self
    }
    async fn connect(&self, _: SocketAddr) -> util::Result<()> {
        Ok(())
    }
    async fn recv(&self, buf: &mut [u8]) -> util::Result<usize> {
        let data = self
            .incoming
            .lock()
            .await
            .recv()
            .await
            .ok_or_else(|| connection_error("DTLS lane closed"))?;
        if data.len() > buf.len() {
            return Err(connection_error("DTLS datagram too large"));
        }
        buf[..data.len()].copy_from_slice(&data);
        Ok(data.len())
    }
    async fn recv_from(&self, buf: &mut [u8]) -> util::Result<(usize, SocketAddr)> {
        Ok((self.recv(buf).await?, self.peer))
    }
    async fn send(&self, buf: &[u8]) -> util::Result<usize> {
        self.socket.send_to(buf, self.peer).await
    }
    async fn send_to(&self, buf: &[u8], peer: SocketAddr) -> util::Result<usize> {
        if peer != self.peer {
            return Err(connection_error("Wrong DTLS peer"));
        }
        self.send(buf).await
    }
    fn local_addr(&self) -> util::Result<SocketAddr> {
        self.socket.local_addr()
    }
    fn remote_addr(&self) -> Option<SocketAddr> {
        Some(self.peer)
    }
    async fn close(&self) -> util::Result<()> {
        Ok(())
    }
}

async fn address(endpoint: &str) -> Option<SocketAddr> {
    lookup_host(endpoint).await.ok()?.find(SocketAddr::is_ipv4)
}

async fn exchange(
    relay: Arc<dyn Conn + Send + Sync>,
    peer: SocketAddr,
    credentials: &Credentials,
    outgoing: &mut mpsc::Receiver<Vec<u8>>,
    incoming: &mpsc::Sender<Vec<u8>>,
    status: &AtomicI32,
) -> Result<(), i32> {
    let (dtls_tx, dtls_rx) = mpsc::channel(QUEUE);
    let (srtp_tx, mut srtp_rx) = mpsc::channel(QUEUE);
    let socket = relay.clone();
    let reader = tokio::spawn(async move {
        let mut buffer = [0; 2048];
        while let Ok((n, sender)) = socket.recv_from(&mut buffer).await {
            if sender != peer || n == 0 {
                continue;
            }
            let packet = &buffer[..n];
            // RFC 7983 multiplexing range and upstream version-2 RTP.
            let lane = match packet[0] {
                20..=63 => &dtls_tx,
                128..=191 => &srtp_tx,
                _ => continue,
            };
            let _ = lane.try_send(packet.to_vec());
        }
    });
    let result = async {
        let lane = Arc::new(DtlsLane {
            socket: relay.clone(),
            peer,
            incoming: Mutex::new(dtls_rx),
        });
        let cert =
            Certificate::generate_self_signed(vec!["localhost".into()]).map_err(|_| DTLS_FAILED)?;
        let mut config = Config {
            certificates: vec![cert],
            extended_master_secret: ExtendedMasterSecretType::Require,
            srtp_protection_profiles: vec![PROFILE],
            // build478 generates its own ephemeral certificate. The optional
            // configured pin replaces CA verification; otherwise only WG
            // authenticates the peer end to end.
            insecure_skip_verify: true,
            ..Default::default()
        };
        if let Some(pin) = &credentials.certificate_sha256 {
            let expected = hex::decode(pin).map_err(|_| DTLS_FAILED)?;
            config.verify_peer_certificate = Some(Arc::new(move |chain, _| {
                if chain
                    .first()
                    .is_some_and(|der| Sha256::digest(der).as_slice() == expected)
                {
                    Ok(())
                } else {
                    Err(dtls::Error::ErrVerifyDataMismatch)
                }
            }));
        }
        let dtls = timeout(
            Duration::from_secs(12),
            DTLSConn::new(lane, config, true, None),
        )
        .await
        .map_err(|_| DTLS_FAILED)?
        .map_err(|_| DTLS_FAILED)?;
        if dtls.selected_srtpprotection_profile() != PROFILE {
            return Err(DTLS_FAILED);
        }
        let profile = ProtectionProfile::Aes128CmHmacSha1_80;
        let mut keys = SrtpConfig {
            profile,
            ..Default::default()
        };
        keys.extract_session_keys_from_dtls(dtls.connection_state().await, true)
            .await
            .map_err(|_| DTLS_FAILED)?;
        let mut send = Context::new(
            &keys.keys.local_master_key,
            &keys.keys.local_master_salt,
            profile,
            None,
            None,
        )
        .map_err(|_| DTLS_FAILED)?;
        let mut receive = Context::new(
            &keys.keys.remote_master_key,
            &keys.keys.remote_master_salt,
            profile,
            Some(srtp_replay_protection(64)),
            None,
        )
        .map_err(|_| DTLS_FAILED)?;
        let mut ssrc = [0; 4];
        getrandom::getrandom(&mut ssrc).map_err(|_| DTLS_FAILED)?;
        let mut seq = 0u16;
        let mut stamp = 0u32;
        let probe_period = Duration::from_secs(10);
        let mut probe = tokio::time::interval_at(tokio::time::Instant::now() + probe_period, probe_period);
        probe.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut latest_probe = 0u64;
        let mut latest_ack = 0u64;
        let mut last_echo = tokio::time::Instant::now();
        status.store(READY, Ordering::Release);
        loop {
            tokio::select! {
                packet = async {
                    tokio::select! {
                        packet = outgoing.recv() => Ok(packet),
                        _ = probe.tick() => {
                            if last_echo.elapsed() >= Duration::from_secs(35) { return Err(RELAY_LOST); }
                            latest_probe += 1;
                            let mut ping = vec![0xff, b'P', b'N', b'G'];
                            ping.extend(latest_probe.to_be_bytes());
                            Ok(Some(ping))
                        }
                    }
                } => {
                    let Some(packet) = packet? else { return Ok(()); };
                    let mut rtp = Vec::with_capacity(12 + packet.len());
                    rtp.extend([0x80, 100]);
                    rtp.extend(seq.to_be_bytes());
                    rtp.extend(stamp.to_be_bytes());
                    rtp.extend(ssrc);
                    rtp.extend(&packet);
                    seq = seq.wrapping_add(1);
                    stamp = stamp.wrapping_add(packet.len() as u32);
                    let encoded = send.encrypt_rtp(&rtp).map_err(|_| RELAY_LOST)?;
                    timeout(Duration::from_secs(5), relay.send_to(&encoded, peer))
                        .await.map_err(|_| RELAY_LOST)?.map_err(|_| RELAY_LOST)?;
                }
                packet = srtp_rx.recv() => {
                    let Some(packet) = packet else { return Err(RELAY_LOST); };
                    let Ok(plain) = receive.decrypt_rtp(&packet) else { continue; };
                    // Upstream uses basic RTP without CSRC, extension or padding.
                    if plain.len() > 12 && plain.len() <= LIMIT + 12
                        && plain[0] == 0x80 && plain[1] & 0x7f == 100 {
                        let payload = &plain[12..];
                        if payload.len() == 12 && payload.starts_with(&[0xff, b'P', b'N', b'G']) {
                            let id = u64::from_be_bytes(payload[4..].try_into().unwrap());
                            if id > latest_ack && id <= latest_probe {
                                latest_ack = id;
                                last_echo = tokio::time::Instant::now();
                            }
                        } else {
                            let _ = incoming.try_send(payload.to_vec());
                        }
                    }
                }
            }
        }
    }
    .await;
    reader.abort();
    result
}

async fn run(
    endpoint: String,
    credentials: Credentials,
    mut outgoing: mpsc::Receiver<Vec<u8>>,
    incoming: mpsc::Sender<Vec<u8>>,
    mut stopped: oneshot::Receiver<()>,
    status: Arc<AtomicI32>,
) {
    let result = async {
        let expires = credentials.expiry().filter(|duration| *duration > Duration::from_secs(30) && *duration <= Duration::from_secs(86400)).ok_or(NEED_CREDENTIALS)?;
        let deadline = tokio::time::Instant::now() + expires;
        let relay_addr = timeout(Duration::from_secs(5), address(&credentials.address))
            .await.ok().flatten().ok_or(TURN_FAILED)?;
        let peer = timeout(Duration::from_secs(5), address(&endpoint))
            .await.ok().flatten().ok_or(TURN_FAILED)?;
        let transport: Arc<dyn Conn + Send + Sync> = if credentials.use_tcp.unwrap_or(true) {
            Arc::new(timeout(Duration::from_secs(5), tcp::TurnTcp::connect(relay_addr))
                .await.map_err(|_| TURN_FAILED)?.map_err(|_| TURN_FAILED)?)
        } else {
            Arc::new(UdpSocket::bind("0.0.0.0:0").await.map_err(|_| TURN_FAILED)?)
        };
        let client = Client::new(ClientConfig {
            stun_serv_addr: String::new(), turn_serv_addr: relay_addr.to_string(),
            username: credentials.username.clone(), password: credentials.password.clone(),
            realm: String::new(), software: String::new(), rto_in_ms: 250,
            conn: transport, vnet: None,
        }).await.map_err(|_| TURN_FAILED)?;
        client.listen().await.map_err(|_| TURN_FAILED)?;
        let acquired = tokio::select! {
            result = timeout(Duration::from_secs(8), client.allocate()) => result,
            _ = &mut stopped => {
                let _ = timeout(Duration::from_secs(1), client.close()).await;
                return Ok(());
            }
        };
        let result = match acquired {
            Ok(Ok(socket)) => {
                let socket = Arc::new(socket);
                let result = tokio::select! {
                    outcome = exchange(socket.clone(), peer, &credentials, &mut outgoing, &incoming, &status) => outcome,
                    _ = tokio::time::sleep_until(deadline) => Err(NEED_CREDENTIALS),
                    _ = stopped => Ok(()),
                };
                let _ = timeout(Duration::from_secs(1), socket.close()).await;
                result
            }
            _ => Err(TURN_FAILED),
        };
        let _ = timeout(Duration::from_secs(1), client.close()).await;
        result
    }.await;
    status.store(result.err().unwrap_or(RELAY_LOST), Ordering::Release);
}

struct Handle {
    status: Arc<AtomicI32>,
    outgoing: mpsc::Sender<Vec<u8>>,
    incoming: mpsc::Receiver<Vec<u8>>,
    _stop: oneshot::Sender<()>,
}

fn start(endpoint: String, credentials: Credentials) -> Option<Box<Handle>> {
    let (outgoing, from_app) = mpsc::channel(QUEUE);
    let (to_app, incoming) = mpsc::channel(QUEUE);
    let (stop, stopped) = oneshot::channel();
    let status = Arc::new(AtomicI32::new(INITIALIZING));
    let worker = status.clone();
    std::thread::Builder::new()
        .name("vk-srtp".into())
        .spawn(move || {
            match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime.block_on(run(
                    endpoint,
                    credentials,
                    from_app,
                    to_app,
                    stopped,
                    worker,
                )),
                Err(_) => worker.store(TURN_FAILED, Ordering::Release),
            }
        })
        .ok()?;
    Some(Box::new(Handle {
        status,
        outgoing,
        incoming,
        _stop: stop,
    }))
}

#[no_mangle]
pub unsafe extern "C" fn vkt_relay_new(value: *const c_char) -> *mut c_void {
    let Some(p) = (unsafe { profile(value) }) else {
        return ptr::null_mut();
    };
    if p.transport != Transport::Srtp || !validate(&p) {
        return ptr::null_mut();
    }
    p.relay
        .and_then(|credentials| start(p.endpoint, credentials))
        .map_or(ptr::null_mut(), |handle| Box::into_raw(handle).cast())
}

#[no_mangle]
pub unsafe extern "C" fn vkt_relay_status(value: *mut c_void) -> i32 {
    unsafe { value.cast::<Handle>().as_ref() }
        .map_or(RELAY_LOST, |h| h.status.load(Ordering::Acquire))
}

#[no_mangle]
pub unsafe extern "C" fn vkt_relay_send(value: *mut c_void, data: *const u8, len: usize) -> i32 {
    if data.is_null() || len == 0 || len > LIMIT {
        return -1;
    }
    let Some(h) = (unsafe { value.cast::<Handle>().as_ref() }) else {
        return -1;
    };
    let bytes = unsafe { std::slice::from_raw_parts(data, len) };
    i32::from(h.outgoing.try_send(bytes.to_vec()).is_ok())
}

#[no_mangle]
pub unsafe extern "C" fn vkt_relay_receive(
    value: *mut c_void,
    output: *mut u8,
    capacity: usize,
) -> usize {
    if output.is_null() || capacity < LIMIT {
        return 0;
    }
    let Some(h) = (unsafe { value.cast::<Handle>().as_mut() }) else {
        return 0;
    };
    let Ok(packet) = h.incoming.try_recv() else {
        return 0;
    };
    unsafe { ptr::copy_nonoverlapping(packet.as_ptr(), output, packet.len()) };
    packet.len()
}

#[no_mangle]
pub unsafe extern "C" fn vkt_relay_free(value: *mut c_void) {
    if !value.is_null() {
        drop(unsafe { Box::from_raw(value.cast::<Handle>()) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Tunnel;
    use boringtun::noise::{Tunn, TunnResult};
    use boringtun::x25519::{PublicKey, StaticSecret};
    use std::{
        net::IpAddr,
        process::{Child, Command, Stdio},
    };
    use tokio::net::TcpListener;
    use turn::{
        auth::{generate_auth_key, AuthHandler},
        relay::relay_static::RelayAddressGeneratorStatic,
        server::{
            config::{ConnConfig, ServerConfig},
            Server,
        },
    };
    use util::vnet::net::Net;

    const REALM: &str = "fixture.invalid";
    struct Auth;
    impl AuthHandler for Auth {
        fn auth_handle(
            &self,
            user: &str,
            realm: &str,
            _: SocketAddr,
        ) -> Result<Vec<u8>, turn::Error> {
            if user != "synthetic" || realm != REALM {
                return Err(turn::Error::ErrFakeErr);
            }
            Ok(generate_auth_key(user, realm, "synthetic-password"))
        }
    }

    struct ChildGuard(Child);
    impl Drop for ChildGuard {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    fn credentials(addr: SocketAddr) -> Credentials {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        Credentials {
            address: addr.to_string(),
            username: "synthetic".into(),
            password: "synthetic-password".into(),
            expires_at: (now + 120).to_string(),
            certificate_sha256: None,
            use_tcp: Some(false),
        }
    }

    #[test]
    fn rejects_expiry_or_invalid_pin() {
        let mut value = credentials("127.0.0.1:3478".parse().unwrap());
        assert!(value.valid());
        value.expires_at = "0".into();
        assert!(value.expiry().is_none());
        value.certificate_sha256 = Some("bad pin".into());
        assert!(!value.valid());
    }

    // The local TURN server exposes UDP. Bridge a TCP control connection
    // into its UDP control socket to exercise stream framing end to end.
    async fn tcp_fixture(target: SocketAddr) -> (SocketAddr, tokio::task::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let task = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let tcp = tcp::TurnTcp::from_stream(tcp).unwrap();
            let udp = UdpSocket::bind("127.0.0.1:0").await.unwrap();
            udp.connect(target).await.unwrap();
            let upstream = async {
                let mut packet = [0; 4096];
                while let Ok(n) = tcp.recv(&mut packet).await {
                    if udp.send(&packet[..n]).await.is_err() {
                        break;
                    }
                }
            };
            let downstream = async {
                let mut packet = [0; 4096];
                while let Ok(n) = udp.recv(&mut packet).await {
                    if tcp.send(&packet[..n]).await.is_err() {
                        break;
                    }
                }
            };
            tokio::select! { _ = upstream => {}, _ = downstream => {} }
        });
        (address, task)
    }

    #[tokio::test]
    #[ignore = "requires the SHA-256-verified upstream srtp-build478 executable"]
    async fn wireguard_through_turn_and_build478_udp() {
        compatible_path(false).await;
    }

    #[tokio::test]
    #[ignore = "requires the SHA-256-verified upstream srtp-build478 executable"]
    async fn wireguard_through_turn_and_build478_tcp() {
        compatible_path(true).await;
    }

    async fn compatible_path(use_tcp: bool) {
        let executable = std::env::var_os("VK_SRTP_SERVER").expect("set VK_SRTP_SERVER");
        let listener = Arc::new(UdpSocket::bind("127.0.0.1:0").await.unwrap());
        let turn_endpoint = listener.local_addr().unwrap();
        let turn = Server::new(ServerConfig {
            conn_configs: vec![ConnConfig {
                conn: listener,
                relay_addr_generator: Box::new(RelayAddressGeneratorStatic {
                    relay_address: IpAddr::from([127, 0, 0, 1]),
                    address: "127.0.0.1".into(),
                    net: Arc::new(Net::new(None)),
                }),
            }],
            realm: REALM.into(),
            auth_handler: Arc::new(Auth),
            channel_bind_timeout: Duration::ZERO,
            alloc_close_notify: None,
        })
        .await
        .unwrap();
        let backend = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let backend_addr = backend.local_addr().unwrap();
        let free = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let srtp_endpoint = free.local_addr().unwrap();
        drop(free);
        let mut _server = ChildGuard(
            Command::new(executable)
                .args([
                    "-srtp",
                    "-listen",
                    &srtp_endpoint.to_string(),
                    "-connect",
                    &backend_addr.to_string(),
                ])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        );
        tokio::time::sleep(Duration::from_millis(250)).await;
        assert!(_server.0.try_wait().unwrap().is_none());
        let server_private = StaticSecret::from([29; 32]);
        let client_private = StaticSecret::from([17; 32]);
        let server_public = PublicKey::from(&server_private);
        let client_public = PublicKey::from(&client_private);
        let echo = tokio::spawn(async move {
            let mut wireguard = Tunn::new(server_private, client_public, None, None, 2, None);
            let mut recv = [0; 2048];
            let mut output = [0; 2048];
            let mut encoded = [0; 2048];
            loop {
                let (length, addr) = backend.recv_from(&mut recv).await.unwrap();
                match wireguard.decapsulate(None, &recv[..length], &mut output) {
                    TunnResult::WriteToNetwork(reply) => {
                        backend.send_to(reply, addr).await.unwrap();
                    }
                    TunnResult::WriteToTunnelV4(packet, _) => {
                        let source: [u8; 4] = packet[12..16].try_into().unwrap();
                        let destination: [u8; 4] = packet[16..20].try_into().unwrap();
                        packet[12..16].copy_from_slice(&destination);
                        packet[16..20].copy_from_slice(&source);
                        if let TunnResult::WriteToNetwork(reply) =
                            wireguard.encapsulate(packet, &mut encoded)
                        {
                            backend.send_to(reply, addr).await.unwrap();
                        }
                    }
                    _ => {}
                }
            }
        });

        let tcp = if use_tcp {
            Some(tcp_fixture(turn_endpoint).await)
        } else {
            None
        };
        let mut credentials =
            credentials(tcp.as_ref().map_or(turn_endpoint, |(address, _)| *address));
        credentials.use_tcp = Some(use_tcp);
        let mut handle = start(srtp_endpoint.to_string(), credentials).unwrap();
        timeout(Duration::from_secs(15), async {
            loop {
                match handle.status.load(Ordering::Acquire) {
                    READY => break,
                    INITIALIZING => tokio::time::sleep(Duration::from_millis(20)).await,
                    code => panic!("relay failed with stage code {code}"),
                }
            }
        })
        .await
        .expect("relay ready");
        let mut client = Tunnel {
            wg: Tunn::new(client_private, server_public, None, None, 1, None),
            routes: vec![(0, 0)],
        };
        let mut buffer = [0; 2048];
        assert!(client.wg.time_since_last_handshake().is_none());
        let (1, n) = client.step(0, &[], &mut buffer) else {
            panic!("missing initiation");
        };
        handle.outgoing.send(buffer[..n].to_vec()).await.unwrap();
        let packet = timeout(Duration::from_secs(6), handle.incoming.recv())
            .await
            .unwrap()
            .unwrap();
        let (1, n) = client.step(2, &packet, &mut buffer) else {
            panic!("missing WG confirmation");
        };
        assert!(client.wg.time_since_last_handshake().is_some());
        handle.outgoing.send(buffer[..n].to_vec()).await.unwrap();
        let mut ip = [0; 20];
        ip[0] = 0x45;
        ip[3] = 20;
        ip[12..20].copy_from_slice(&[192, 0, 2, 2, 192, 0, 2, 1]);
        let (1, n) = client.step(1, &ip, &mut buffer) else {
            panic!("missing encrypted IPv4");
        };
        handle.outgoing.send(buffer[..n].to_vec()).await.unwrap();
        let packet = timeout(Duration::from_secs(6), handle.incoming.recv())
            .await
            .unwrap()
            .unwrap();
        let (2, n) = client.step(2, &packet, &mut buffer) else {
            panic!("missing decrypted IPv4");
        };
        assert_eq!(n, 20);
        assert_eq!(&buffer[12..20], &[192, 0, 2, 1, 192, 0, 2, 2]);
        drop(handle);
        echo.abort();
        if let Some((_, task)) = tcp {
            task.abort();
        }
        turn.close().await.unwrap();
    }
}
