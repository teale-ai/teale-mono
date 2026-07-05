//! PIN UDP transport — Noise-encrypted ClusterMessage exchange, wire-
//! compatible with WANKit's `WireGuardTransport.swift`.
//!
//! Outer framing (first byte = packet type):
//!   0x01 handshake msg1        0x02 handshake msg2
//!   0x03 keepalive (empty)     0x04 transport data
//!   0x05 transport fragment
//!
//! 0x04 plaintext: `[4B BE length][JSON ClusterMessage]`.
//! 0x05 plaintext: `[4B BE fragmentID][2B BE index][2B BE total][chunk]`,
//! chunks ≤1100 bytes of the length-prefixed JSON. See
//! docs/pin-noise-protocol.md.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use parking_lot::Mutex;
use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use x25519_dalek::{PublicKey, StaticSecret};

use super::noise::{
    initiator_begin, initiator_finish, responder_complete, timestamp_payload, NoiseSession,
};
use teale_protocol::ClusterMessage;

const TYPE_HANDSHAKE_INIT: u8 = 0x01;
const TYPE_HANDSHAKE_RESP: u8 = 0x02;
const TYPE_KEEPALIVE: u8 = 0x03;
const TYPE_DATA: u8 = 0x04;
const TYPE_FRAGMENT: u8 = 0x05;

/// Max plaintext chunk per datagram, matching WANKit's `maxPayload`.
const MAX_PAYLOAD: usize = 1100;
const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(20);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// Drop partial fragment buffers not completed within this window.
const FRAGMENT_TTL: Duration = Duration::from_secs(10);

/// Decides whether a peer's authenticated Noise static key is allowed —
/// backed by the current netmap (active, not disabled).
pub type PeerAuthorizer = Arc<dyn Fn(&PublicKey) -> bool + Send + Sync>;

struct FragmentBuffer {
    total: usize,
    chunks: HashMap<usize, Vec<u8>>,
    created: std::time::Instant,
}

impl FragmentBuffer {
    fn new(total: usize) -> Self {
        Self {
            total,
            chunks: HashMap::new(),
            created: std::time::Instant::now(),
        }
    }
    fn insert(&mut self, index: usize, data: Vec<u8>) {
        self.chunks.insert(index, data);
    }
    fn is_complete(&self) -> bool {
        self.chunks.len() == self.total
    }
    fn reassemble(mut self) -> Vec<u8> {
        let mut out = Vec::new();
        for i in 0..self.total {
            if let Some(chunk) = self.chunks.remove(&i) {
                out.extend_from_slice(&chunk);
            }
        }
        out
    }
}

fn frame_message(message: &ClusterMessage) -> Result<Vec<u8>> {
    let json = serde_json::to_vec(&message.to_value())?;
    let mut framed = (json.len() as u32).to_be_bytes().to_vec();
    framed.extend_from_slice(&json);
    Ok(framed)
}

fn deframe_message(framed: &[u8]) -> Result<ClusterMessage> {
    if framed.len() < 4 {
        bail!("framed message too short");
    }
    let length = u32::from_be_bytes(framed[..4].try_into().expect("checked")) as usize;
    if framed.len() < 4 + length {
        bail!("framed message truncated");
    }
    ClusterMessage::parse(&framed[4..4 + length])
        .ok_or_else(|| anyhow!("unrecognized cluster message"))
}

/// One encrypted peer connection (either dialed or accepted).
pub struct PeerConnection {
    socket: Arc<UdpSocket>,
    remote_addr: SocketAddr,
    session: Arc<Mutex<NoiseSession>>,
    /// Peer's authenticated Noise static key.
    pub remote_static: PublicKey,
    incoming: tokio::sync::Mutex<mpsc::Receiver<ClusterMessage>>,
    last_send: Arc<Mutex<std::time::Instant>>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

impl PeerConnection {
    pub async fn send(&self, message: &ClusterMessage) -> Result<()> {
        let framed = frame_message(message)?;
        if framed.len() <= MAX_PAYLOAD {
            let encrypted = self.session.lock().encrypt(&framed);
            let mut packet = vec![TYPE_DATA];
            packet.extend_from_slice(&encrypted);
            self.socket.send_to(&packet, self.remote_addr).await?;
        } else {
            let fragment_id: u32 = rand::random();
            let chunks: Vec<&[u8]> = framed.chunks(MAX_PAYLOAD).collect();
            let total = chunks.len() as u16;
            for (index, chunk) in chunks.iter().enumerate() {
                let mut plaintext = fragment_id.to_be_bytes().to_vec();
                plaintext.extend_from_slice(&(index as u16).to_be_bytes());
                plaintext.extend_from_slice(&total.to_be_bytes());
                plaintext.extend_from_slice(chunk);
                let encrypted = self.session.lock().encrypt(&plaintext);
                let mut packet = vec![TYPE_FRAGMENT];
                packet.extend_from_slice(&encrypted);
                self.socket.send_to(&packet, self.remote_addr).await?;
            }
        }
        *self.last_send.lock() = std::time::Instant::now();
        Ok(())
    }

    /// Next decrypted message; None when the connection is closed.
    pub async fn recv(&self) -> Option<ClusterMessage> {
        self.incoming.lock().await.recv().await
    }

    pub fn close(&self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

impl Drop for PeerConnection {
    fn drop(&mut self) {
        self.close();
    }
}

/// Shared receive-side machinery: decrypt a datagram and deliver completed
/// messages. Returns without delivering on any malformed/undecryptable input
/// (UDP: drop, never fail the connection).
fn handle_datagram(
    packet: &[u8],
    session: &Mutex<NoiseSession>,
    fragments: &Mutex<HashMap<u32, FragmentBuffer>>,
    deliver: &mpsc::Sender<ClusterMessage>,
) {
    let Some((&packet_type, body)) = packet.split_first() else {
        return;
    };
    match packet_type {
        TYPE_DATA => {
            let Ok(plaintext) = session.lock().decrypt(body) else {
                return;
            };
            if let Ok(message) = deframe_message(&plaintext) {
                let _ = deliver.try_send(message);
            }
        }
        TYPE_FRAGMENT => {
            let Ok(plaintext) = session.lock().decrypt(body) else {
                return;
            };
            if plaintext.len() < 8 {
                return;
            }
            let fragment_id = u32::from_be_bytes(plaintext[..4].try_into().expect("len checked"));
            let index =
                u16::from_be_bytes(plaintext[4..6].try_into().expect("len checked")) as usize;
            let total =
                u16::from_be_bytes(plaintext[6..8].try_into().expect("len checked")) as usize;
            if total == 0 || index >= total {
                return;
            }
            let mut fragments = fragments.lock();
            fragments.retain(|_, buf| buf.created.elapsed() < FRAGMENT_TTL);
            let buffer = fragments
                .entry(fragment_id)
                .or_insert_with(|| FragmentBuffer::new(total));
            buffer.insert(index, plaintext[8..].to_vec());
            if buffer.is_complete() {
                let buffer = fragments.remove(&fragment_id).expect("present");
                if let Ok(message) = deframe_message(&buffer.reassemble()) {
                    let _ = deliver.try_send(message);
                }
            }
        }
        TYPE_KEEPALIVE => {}
        _ => {}
    }
}

fn spawn_connection(
    socket: Arc<UdpSocket>,
    remote_addr: SocketAddr,
    session: NoiseSession,
    remote_static: PublicKey,
    // For dialed connections the socket is exclusive: spawn our own read
    // loop. Accepted connections receive datagrams via the listener's
    // dispatch loop instead (reader = None).
    reader: Option<()>,
) -> (Arc<PeerConnection>, mpsc::Sender<ClusterMessage>) {
    let (tx, rx) = mpsc::channel(256);
    let session = Arc::new(Mutex::new(session));
    let last_send = Arc::new(Mutex::new(std::time::Instant::now()));
    let fragments = Arc::new(Mutex::new(HashMap::new()));
    let mut tasks = Vec::new();

    if reader.is_some() {
        let socket_r = socket.clone();
        let session_r = session.clone();
        let tx_r = tx.clone();
        let fragments_r = fragments.clone();
        tasks.push(tokio::spawn(async move {
            let mut buf = vec![0u8; 65536];
            loop {
                let Ok((len, from)) = socket_r.recv_from(&mut buf).await else {
                    break;
                };
                if from != remote_addr {
                    continue;
                }
                handle_datagram(&buf[..len], &session_r, &fragments_r, &tx_r);
            }
        }));
    }

    // Keepalive loop (both roles).
    let socket_k = socket.clone();
    let last_send_k = last_send.clone();
    tasks.push(tokio::spawn(async move {
        loop {
            tokio::time::sleep(KEEPALIVE_INTERVAL).await;
            if last_send_k.lock().elapsed() >= KEEPALIVE_INTERVAL {
                let _ = socket_k.send_to(&[TYPE_KEEPALIVE], remote_addr).await;
                *last_send_k.lock() = std::time::Instant::now();
            }
        }
    }));

    let connection = Arc::new(PeerConnection {
        socket,
        remote_addr,
        session,
        remote_static,
        incoming: tokio::sync::Mutex::new(rx),
        last_send,
        tasks,
    });
    (connection, tx)
}

/// Dial a peer: exclusive socket, initiator handshake, receive loop.
pub async fn dial(
    remote_addr: SocketAddr,
    remote_wg_pubkey: &PublicKey,
    local_static: &StaticSecret,
) -> Result<Arc<PeerConnection>> {
    let socket = Arc::new(
        UdpSocket::bind(("0.0.0.0", 0))
            .await
            .context("bind dial socket")?,
    );
    let ephemeral = StaticSecret::random_from_rng(rand::rngs::OsRng);
    let (msg1, state) = initiator_begin(
        local_static,
        remote_wg_pubkey,
        ephemeral,
        &timestamp_payload(),
    );
    let mut packet = vec![TYPE_HANDSHAKE_INIT];
    packet.extend_from_slice(&msg1);
    socket.send_to(&packet, remote_addr).await?;

    // Await 0x02 from the peer.
    let mut buf = vec![0u8; 4096];
    let keys = tokio::time::timeout(HANDSHAKE_TIMEOUT, async {
        loop {
            let (len, from) = socket.recv_from(&mut buf).await?;
            if from != remote_addr || len < 1 || buf[0] != TYPE_HANDSHAKE_RESP {
                continue;
            }
            return anyhow::Ok(buf[1..len].to_vec());
        }
    })
    .await
    .map_err(|_| anyhow!("handshake timed out"))??;
    let keys = initiator_finish(state, &keys)?;

    let (connection, _tx) = spawn_connection(
        socket,
        remote_addr,
        NoiseSession::new(keys),
        *remote_wg_pubkey,
        Some(()),
    );
    Ok(connection)
}

/// Listener: accepts inbound handshakes on one socket and dispatches
/// datagrams to accepted connections by source address.
pub struct PinListener {
    socket: Arc<UdpSocket>,
    accepted: mpsc::Receiver<Arc<PeerConnection>>,
    dispatch_task: tokio::task::JoinHandle<()>,
}

impl PinListener {
    pub async fn bind(
        bind_addr: &str,
        local_static: StaticSecret,
        authorizer: PeerAuthorizer,
    ) -> Result<Self> {
        let socket = Arc::new(UdpSocket::bind(bind_addr).await.context("bind listener")?);
        let (accept_tx, accepted) = mpsc::channel(16);

        let socket_l = socket.clone();
        let dispatch_task = tokio::spawn(async move {
            // Per-peer delivery channels + fragment buffers, keyed by addr.
            struct AcceptedPeer {
                session: Arc<Mutex<NoiseSession>>,
                fragments: Arc<Mutex<HashMap<u32, FragmentBuffer>>>,
                deliver: mpsc::Sender<ClusterMessage>,
            }
            let mut peers: HashMap<SocketAddr, AcceptedPeer> = HashMap::new();
            let mut buf = vec![0u8; 65536];
            loop {
                let Ok((len, from)) = socket_l.recv_from(&mut buf).await else {
                    break;
                };
                if len == 0 {
                    continue;
                }
                let packet = &buf[..len];
                if packet[0] == TYPE_HANDSHAKE_INIT {
                    let ephemeral = StaticSecret::random_from_rng(rand::rngs::OsRng);
                    let Ok((msg2, keys, remote_static)) = responder_complete(
                        &local_static,
                        &packet[1..],
                        ephemeral,
                        &timestamp_payload(),
                    ) else {
                        continue; // garbage or wrong static key — drop silently
                    };
                    if !authorizer(&remote_static) {
                        // Unknown/disabled device: no response at all.
                        continue;
                    }
                    let mut reply = vec![TYPE_HANDSHAKE_RESP];
                    reply.extend_from_slice(&msg2);
                    if socket_l.send_to(&reply, from).await.is_err() {
                        continue;
                    }
                    let (connection, deliver) = spawn_connection(
                        socket_l.clone(),
                        from,
                        NoiseSession::new(keys),
                        remote_static,
                        None,
                    );
                    peers.insert(
                        from,
                        AcceptedPeer {
                            session: connection.session.clone(),
                            fragments: Arc::new(Mutex::new(HashMap::new())),
                            deliver,
                        },
                    );
                    let _ = accept_tx.try_send(connection);
                } else if let Some(peer) = peers.get(&from) {
                    handle_datagram(packet, &peer.session, &peer.fragments, &peer.deliver);
                }
            }
        });

        Ok(Self {
            socket,
            accepted,
            dispatch_task,
        })
    }

    pub fn local_addr(&self) -> Result<SocketAddr> {
        Ok(self.socket.local_addr()?)
    }

    /// Next authenticated inbound connection.
    pub async fn accept(&mut self) -> Option<Arc<PeerConnection>> {
        self.accepted.recv().await
    }
}

impl Drop for PinListener {
    fn drop(&mut self) {
        self.dispatch_task.abort();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use teale_protocol::cluster::InferenceChunkPayload;

    fn test_message(payload_size: usize) -> ClusterMessage {
        ClusterMessage::InferenceChunk(InferenceChunkPayload {
            request_id: "req-1".into(),
            chunk: serde_json::Value::String("x".repeat(payload_size)),
        })
    }

    fn as_json(message: &ClusterMessage) -> serde_json::Value {
        message.to_value()
    }

    fn authorize_all() -> PeerAuthorizer {
        Arc::new(|_| true)
    }

    async fn pair(
        authorizer: PeerAuthorizer,
    ) -> (Arc<PeerConnection>, Arc<PeerConnection>, PinListener) {
        let server_static = StaticSecret::from([21u8; 32]);
        let server_public = PublicKey::from(&server_static);
        let mut listener = PinListener::bind("127.0.0.1:0", server_static, authorizer)
            .await
            .unwrap();
        let addr = listener.local_addr().unwrap();
        let client_static = StaticSecret::from([22u8; 32]);
        let client = dial(addr, &server_public, &client_static).await.unwrap();
        let server_side = listener.accept().await.unwrap();
        (client, server_side, listener)
    }

    #[tokio::test]
    async fn round_trip_small_message() {
        let (client, server, _listener) = pair(authorize_all()).await;
        client.send(&test_message(100)).await.unwrap();
        let got = server.recv().await.unwrap();
        assert_eq!(as_json(&got), as_json(&test_message(100)));

        // Reply direction (accepted side sends over shared socket).
        server.send(&test_message(50)).await.unwrap();
        assert_eq!(
            as_json(&client.recv().await.unwrap()),
            as_json(&test_message(50))
        );
    }

    #[tokio::test]
    async fn round_trip_fragmented_message() {
        let (client, server, _listener) = pair(authorize_all()).await;
        // >64 KiB forces dozens of fragments.
        let big = test_message(70_000);
        client.send(&big).await.unwrap();
        let got = tokio::time::timeout(Duration::from_secs(5), server.recv())
            .await
            .expect("reassembly must complete")
            .unwrap();
        assert_eq!(as_json(&got), as_json(&big));
    }

    #[tokio::test]
    async fn authenticated_static_key_is_exposed() {
        let (client, server, _listener) = pair(authorize_all()).await;
        assert_eq!(
            server.remote_static.as_bytes(),
            PublicKey::from(&StaticSecret::from([22u8; 32])).as_bytes()
        );
        assert_eq!(
            client.remote_static.as_bytes(),
            PublicKey::from(&StaticSecret::from([21u8; 32])).as_bytes()
        );
    }

    #[tokio::test]
    async fn unauthorized_peer_gets_no_response() {
        let server_static = StaticSecret::from([31u8; 32]);
        let server_public = PublicKey::from(&server_static);
        let denied = PublicKey::from(&StaticSecret::from([32u8; 32]));
        let authorizer: PeerAuthorizer =
            Arc::new(move |peer: &PublicKey| peer.as_bytes() != denied.as_bytes());
        let listener = PinListener::bind("127.0.0.1:0", server_static, authorizer)
            .await
            .unwrap();
        let addr = listener.local_addr().unwrap();

        let result = dial(addr, &server_public, &StaticSecret::from([32u8; 32])).await;
        assert!(result.is_err(), "denied peer must time out");
    }
}
