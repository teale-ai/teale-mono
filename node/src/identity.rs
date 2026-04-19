use ed25519_dalek::{Signer, SigningKey};
use rand::rngs::OsRng;
use std::path::PathBuf;
use tracing::info;

/// Ed25519 identity matching Swift's WANNodeIdentity.
/// nodeID = hex-encoded 32-byte public key (64 hex chars).
pub struct NodeIdentity {
    signing_key: SigningKey,
}

impl NodeIdentity {
    pub fn node_id(&self) -> String {
        hex::encode(self.signing_key.verifying_key().as_bytes())
    }

    pub fn public_key_hex(&self) -> String {
        self.node_id() // nodeID == publicKey in the protocol
    }

    /// Sign data and return hex-encoded signature.
    pub fn sign_hex(&self, data: &[u8]) -> String {
        let signature = self.signing_key.sign(data);
        hex::encode(signature.to_bytes())
    }

    /// Sign the nodeID string (UTF-8 bytes) — used for relay registration.
    pub fn sign_node_id(&self) -> String {
        self.sign_hex(self.node_id().as_bytes())
    }

    /// Sign "{from}:{to}:{session}" for offer/answer signatures.
    pub fn sign_session(&self, from: &str, to: &str, session: &str) -> String {
        let data = format!("{}:{}:{}", from, to, session);
        self.sign_hex(data.as_bytes())
    }

    /// Load from file or generate new identity.
    pub fn load_or_create() -> anyhow::Result<Self> {
        let path = identity_file_path();
        if path.exists() {
            let data = std::fs::read(&path)?;
            if data.len() != 32 {
                anyhow::bail!(
                    "Identity file has wrong size (expected 32 bytes, got {})",
                    data.len()
                );
            }
            let bytes: [u8; 32] = data.try_into().unwrap();
            let signing_key = SigningKey::from_bytes(&bytes);
            info!(
                "Loaded identity from {:?}, nodeID={}",
                path,
                hex::encode(signing_key.verifying_key().as_bytes())
            );
            Ok(Self { signing_key })
        } else {
            let signing_key = SigningKey::generate(&mut OsRng);
            // Create parent directories
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::write(&path, signing_key.to_bytes())?;
            // Set file permissions to 0600 on Unix
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
            }
            info!(
                "Generated new identity at {:?}, nodeID={}",
                path,
                hex::encode(signing_key.verifying_key().as_bytes())
            );
            Ok(Self { signing_key })
        }
    }
}

fn identity_file_path() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        let home = dirs_path("HOME");
        home.join("Library/Application Support/Teale/wan-identity.key")
    }
    #[cfg(target_os = "linux")]
    {
        let home = dirs_path("HOME");
        home.join(".local/share/teale/wan-identity.key")
    }
    #[cfg(target_os = "windows")]
    {
        let appdata = std::env::var("APPDATA").unwrap_or_else(|_| ".".to_string());
        PathBuf::from(appdata)
            .join("Teale")
            .join("wan-identity.key")
    }
    #[cfg(target_os = "android")]
    {
        // Android: use current directory as fallback
        PathBuf::from(".teale/wan-identity.key")
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn dirs_path(var: &str) -> PathBuf {
    PathBuf::from(std::env::var(var).unwrap_or_else(|_| "/tmp".to_string()))
}
