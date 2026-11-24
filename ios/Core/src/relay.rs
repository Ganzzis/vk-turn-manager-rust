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
        status.store(READY, Ordering::Release);
        loop {
            tokio::select! {
                packet = outgoing.recv() => {
                    let Some(packet) = packet else { return Ok(()); };
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
                        let _ = incoming.try_send(plain[12..].to_vec());
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
    stopped: oneshot::Receiver<()>,
    status: Arc<AtomicI32>,
) {
    let result = async {
        let expires = credentials.expiry().filter(|duration| *duration > Duration::from_secs(30)).ok_or(NEED_CREDENTIALS)?;
        let relay_addr = timeout(Duration::from_secs(5), address(&credentials.address))
            .await.ok().flatten().ok_or(TURN_FAILED)?;
        let peer = timeout(Duration::from_secs(5), address(&endpoint))
            .await.ok().flatten().ok_or(TURN_FAILED)?;
        let udp = UdpSocket::bind("0.0.0.0:0").await.map_err(|_| TURN_FAILED)?;
        let client = Client::new(ClientConfig {
            stun_serv_addr: String::new(), turn_serv_addr: relay_addr.to_string(),
            username: credentials.username.clone(), password: credentials.password.clone(),
            realm: String::new(), software: String::new(), rto_in_ms: 250,
            conn: Arc::new(udp), vnet: None,
        }).await.map_err(|_| TURN_FAILED)?;
        client.listen().await.map_err(|_| TURN_FAILED)?;
        let acquired = timeout(Duration::from_secs(8), client.allocate()).await;
        let result = match acquired {
            Ok(Ok(socket)) => {
                let socket = Arc::new(socket);
                let result = tokio::select! {
                    outcome = exchange(socket.clone(), peer, &credentials, &mut outgoing, &incoming, &status) => outcome,
                    _ = tokio::time::sleep(expires) => Err(NEED_CREDENTIALS),
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
