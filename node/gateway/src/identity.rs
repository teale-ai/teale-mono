//! Ed25519 identity for the gateway (registers on the relay as a node).

use ed25519_dalek::{Signer, SigningKey};
use rand::rngs::OsRng;
use std::path::PathBuf;
use tracing::info;

pub struct GatewayIdentity {
    signing_key: SigningKey,
}

impl GatewayIdentity {
    pub fn node_id(&self) -> String {
        hex::encode(self.signing_key.verifying_key().as_bytes())
    }

    pub fn public_key_hex(&self) -> String {
        self.node_id()
    }

    pub fn sign_hex(&self, data: &[u8]) -> String {
        hex::encode(self.signing_key.sign(data).to_bytes())
    }

    pub fn sign_node_id(&self) -> String {
        self.sign_hex(self.node_id().as_bytes())
    }

    pub fn load_or_create(path: &str) -> anyhow::Result<Self> {
        let path = PathBuf::from(path);
        if path.exists() {
            let data = std::fs::read(&path)?;
            if data.len() != 32 {
                anyhow::bail!(
                    "identity file has wrong size (expected 32 bytes, got {})",
                    data.len()
                );
            }
            let bytes: [u8; 32] = data.try_into().unwrap();
            let signing_key = SigningKey::from_bytes(&bytes);
            info!(
                "Loaded gateway identity from {:?}, nodeID={}",
                path,
                hex::encode(signing_key.verifying_key().as_bytes())
            );
            Ok(Self { signing_key })
        } else {
            let signing_key = SigningKey::generate(&mut OsRng);
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&path, signing_key.to_bytes())?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
            }
            info!(
                "Generated new gateway identity at {:?}, nodeID={}",
                path,
                hex::encode(signing_key.verifying_key().as_bytes())
            );
            Ok(Self { signing_key })
        }
    }
}
