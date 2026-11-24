use super::{Peer, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde_json::json;

// ConnectionLink and ConnectionSettings from anton48/vk-turn-proxy-ios,
// commit 0fddeef5b70044a0cf9bcd9fe093edfc4956d8c6.
pub(super) fn link(
    peer: &Peer,
    private: &str,
    public: &str,
    endpoint: &str,
    vk_link: &str,
) -> Result<String> {
    let token = ["https://vk.ru/call/join/", "https://vk.com/call/join/"]
        .iter()
        .find_map(|prefix| vk_link.strip_prefix(prefix))
        .ok_or("Expected a VK call join URL")?;
    if token.is_empty()
        || token.len() > 512
        || !token
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_-".contains(&c))
    {
        return Err("Invalid VK call join URL".into());
    }
    let payload = json!({
        "version": 1, "type": "connection",
        "settings": {
            "serverName": peer.name, "privateKey": private, "peerPublicKey": public,
            "tunnelAddress": format!("{}/32", peer.ip), "allowedIPs": "0.0.0.0/0",
            "peerAddress": endpoint, "vkLink": vk_link, "useSrtp": true
        }
    });
    Ok(format!(
        "vkturnproxy://import?data={}\n",
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload)?)
    ))
}
