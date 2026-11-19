//! Gateway account session (`tsess_…`) held by the node on behalf of the
//! desktop companion UI.
//!
//! The companion signs in with the gateway's passwordless email code
//! (`/v1/auth/email/request` + `/v1/auth/email/verify`). The verify response
//! carries a session token; the node persists it next to its identity key
//! (owner-only permissions, see `secure_file`) and presents it as
//! `X-Teale-Account-Session` when linking this device to the account, which is
//! the gateway's proof that the caller owns the account.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub const ACCOUNT_SESSION_HEADER: &str = "X-Teale-Account-Session";
const SESSION_FILE_NAME: &str = "account-session.json";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountSession {
    #[serde(rename = "sessionToken")]
    pub session_token: String,
    #[serde(rename = "accountUserID")]
    pub account_user_id: String,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(rename = "expiresAt", default)]
    pub expires_at: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct AccountSessionStore {
    path: PathBuf,
}

impl AccountSessionStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    /// Store under the node data directory (next to `wan-identity.key`).
    pub fn in_data_dir(data_dir: &Path) -> Self {
        Self::new(data_dir.join(SESSION_FILE_NAME))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The persisted session, if any. A corrupt or empty file reads as "no
    /// session" so the user can simply sign in again.
    pub fn load(&self) -> Option<AccountSession> {
        let raw = std::fs::read(&self.path).ok()?;
        let session: AccountSession = serde_json::from_slice(&raw).ok()?;
        if session.session_token.trim().is_empty() || session.account_user_id.trim().is_empty() {
            return None;
        }
        Some(session)
    }

    pub fn save(&self, session: &AccountSession) -> anyhow::Result<()> {
        let bytes = serde_json::to_vec(session)?;
        crate::secure_file::write_private(&self.path, &bytes)?;
        Ok(())
    }

    pub fn clear(&self) -> anyhow::Result<()> {
        match std::fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(err) => Err(err.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_store() -> (PathBuf, AccountSessionStore) {
        let dir = std::env::temp_dir().join(format!("teale-session-{}", uuid::Uuid::new_v4()));
        let store = AccountSessionStore::in_data_dir(&dir);
        (dir, store)
    }

    #[test]
    fn save_load_clear_roundtrip() {
        let (dir, store) = temp_store();
        assert!(store.load().is_none());

        let session = AccountSession {
            session_token: "tsess_abc".to_string(),
            account_user_id: "acct-1".to_string(),
            email: Some("a@example.com".to_string()),
            expires_at: Some(123),
        };
        store.save(&session).expect("save session");
        assert_eq!(store.load(), Some(session));

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::metadata(store.path()).expect("meta").permissions();
            assert_eq!(perms.mode() & 0o777, 0o600);
        }

        store.clear().expect("clear session");
        assert!(store.load().is_none());
        store.clear().expect("clearing twice is fine");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_or_blank_file_reads_as_signed_out() {
        let (dir, store) = temp_store();
        std::fs::create_dir_all(&dir).expect("dir");
        std::fs::write(store.path(), b"not json").expect("write");
        assert!(store.load().is_none());
        let blank = br#"{"sessionToken":" ","accountUserID":"acct"}"#;
        std::fs::write(store.path(), blank).expect("write");
        assert!(store.load().is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
