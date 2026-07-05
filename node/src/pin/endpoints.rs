//! Endpoint advertisement for the PIN data plane: which addresses peers can
//! dial us on. LAN addresses come from the primary local interface; the
//! reflexive (public) address from a STUN binding request. Both are
//! advertised via `/v1/pins/:id/sync` and distributed in netmaps — cached
//! netmaps therefore keep LAN dialing working even when the gateway is
//! unreachable (offline-LAN mode).

use std::net::{Ipv4Addr, SocketAddr};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use teale_protocol::PinEndpoint;
use tokio::net::UdpSocket;

const STUN_SERVERS: &[&str] = &["stun.l.google.com:19302", "stun1.l.google.com:19302"];
const STUN_MAGIC_COOKIE: u32 = 0x2112_A442;
const STUN_TIMEOUT: Duration = Duration::from_secs(3);

/// Primary LAN IPv4 without sending traffic: route-table lookup via a
/// connected UDP socket.
pub async fn primary_lan_ip() -> Option<Ipv4Addr> {
    let socket = UdpSocket::bind(("0.0.0.0", 0)).await.ok()?;
    socket.connect(("8.8.8.8", 80)).await.ok()?;
    match socket.local_addr().ok()? {
        SocketAddr::V4(v4) if !v4.ip().is_loopback() => Some(*v4.ip()),
        _ => None,
    }
}

/// RFC 5389 binding request → XOR-MAPPED-ADDRESS. `local_port` is the PIN
/// transport port whose mapping we want, so the request is sent from a
/// socket bound to it — NAT mappings are per source port.
pub async fn stun_reflexive(local_port: u16) -> Result<SocketAddr> {
    let socket = UdpSocket::bind(("0.0.0.0", local_port))
        .await
        .or(UdpSocket::bind(("0.0.0.0", 0)).await)
        .context("bind stun socket")?;

    let mut request = Vec::with_capacity(20);
    request.extend_from_slice(&0x0001u16.to_be_bytes()); // binding request
    request.extend_from_slice(&0u16.to_be_bytes()); // length
    request.extend_from_slice(&STUN_MAGIC_COOKIE.to_be_bytes());
    let transaction_id: [u8; 12] = rand::random();
    request.extend_from_slice(&transaction_id);

    for server in STUN_SERVERS {
        if socket.send_to(&request, server).await.is_err() {
            continue;
        }
        let mut buf = [0u8; 512];
        let Ok(Ok((len, _))) = tokio::time::timeout(STUN_TIMEOUT, socket.recv_from(&mut buf)).await
        else {
            continue;
        };
        if let Some(addr) = parse_stun_response(&buf[..len], &transaction_id) {
            return Ok(addr);
        }
    }
    bail!("no STUN server answered")
}

fn parse_stun_response(packet: &[u8], transaction_id: &[u8; 12]) -> Option<SocketAddr> {
    if packet.len() < 20 || packet[0..2] != [0x01, 0x01] {
        return None; // not a binding success response
    }
    if &packet[8..20] != transaction_id {
        return None;
    }
    let mut cursor = 20;
    while cursor + 4 <= packet.len() {
        let attr_type = u16::from_be_bytes([packet[cursor], packet[cursor + 1]]);
        let attr_len = u16::from_be_bytes([packet[cursor + 2], packet[cursor + 3]]) as usize;
        let value = packet.get(cursor + 4..cursor + 4 + attr_len)?;
        // XOR-MAPPED-ADDRESS (0x0020), IPv4 family (0x01).
        if attr_type == 0x0020 && value.len() >= 8 && value[1] == 0x01 {
            let port = u16::from_be_bytes([value[2], value[3]]) ^ (STUN_MAGIC_COOKIE >> 16) as u16;
            let cookie = STUN_MAGIC_COOKIE.to_be_bytes();
            let ip = Ipv4Addr::new(
                value[4] ^ cookie[0],
                value[5] ^ cookie[1],
                value[6] ^ cookie[2],
                value[7] ^ cookie[3],
            );
            return Some(SocketAddr::from((ip, port)));
        }
        cursor += 4 + attr_len.div_ceil(4) * 4; // attributes are 32-bit aligned
    }
    None
}

/// Gather everything we can advertise for the given transport port.
/// STUN failures degrade gracefully to LAN-only.
pub async fn gather(transport_port: u16) -> Vec<PinEndpoint> {
    let mut endpoints = Vec::new();
    if let Some(ip) = primary_lan_ip().await {
        endpoints.push(PinEndpoint {
            kind: "lan".into(),
            addr: format!("{ip}:{transport_port}"),
        });
    }
    if let Ok(reflexive) = stun_reflexive(transport_port).await {
        endpoints.push(PinEndpoint {
            kind: "reflexive".into(),
            addr: reflexive.to_string(),
        });
    }
    endpoints
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_canned_xor_mapped_address() {
        // Binding success, one XOR-MAPPED-ADDRESS attribute for
        // 203.0.113.7:41641 (values XORed with the magic cookie).
        let transaction_id = [7u8; 12];
        let cookie = STUN_MAGIC_COOKIE.to_be_bytes();
        let ip = [203u8, 0, 113, 7];
        let port: u16 = 41641;
        let xport = port ^ (STUN_MAGIC_COOKIE >> 16) as u16;
        let mut packet = Vec::new();
        packet.extend_from_slice(&[0x01, 0x01]); // success
        packet.extend_from_slice(&12u16.to_be_bytes()); // msg length
        packet.extend_from_slice(&cookie);
        packet.extend_from_slice(&transaction_id);
        packet.extend_from_slice(&0x0020u16.to_be_bytes());
        packet.extend_from_slice(&8u16.to_be_bytes());
        packet.push(0);
        packet.push(0x01);
        packet.extend_from_slice(&xport.to_be_bytes());
        for (i, byte) in ip.iter().enumerate() {
            packet.push(byte ^ cookie[i]);
        }

        let parsed = parse_stun_response(&packet, &transaction_id).unwrap();
        assert_eq!(parsed, "203.0.113.7:41641".parse().unwrap());
    }

    #[test]
    fn rejects_wrong_transaction_id() {
        let packet = {
            let mut p = vec![0x01, 0x01, 0, 0];
            p.extend_from_slice(&STUN_MAGIC_COOKIE.to_be_bytes());
            p.extend_from_slice(&[9u8; 12]);
            p
        };
        assert!(parse_stun_response(&packet, &[7u8; 12]).is_none());
    }
}
