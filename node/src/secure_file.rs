//! Owner-only files for node secrets (Ed25519 identity key, gateway account
//! session token).
//!
//! Unix: created with mode 0600.
//!
//! Windows: the inherited ACL is replaced with an explicit, non-inherited one
//! granting full control to SYSTEM, the local Administrators group and the
//! account the node runs as (LocalSystem for the NSSM service, the developer's
//! own account for a hand-started node). Standard users lose read access, so
//! they can no longer copy the node key or the account session. `icacls` ships
//! with every supported Windows version, which keeps this free of unsafe Win32
//! security-descriptor code.

use std::io::Write;
use std::path::Path;

/// Well-known SID for `NT AUTHORITY\SYSTEM`.
#[cfg_attr(not(windows), allow(dead_code))]
const SYSTEM_SID: &str = "S-1-5-18";
/// Well-known SID for `BUILTIN\Administrators`.
#[cfg_attr(not(windows), allow(dead_code))]
const ADMINISTRATORS_SID: &str = "S-1-5-32-544";

/// Write `bytes` to `path` (creating parent directories) and restrict the file
/// to its owner. Existing files are overwritten.
pub fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(path)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }

    #[cfg(not(unix))]
    {
        let mut file = std::fs::File::create(path)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }

    restrict_to_owner(path)
}

/// Tighten the permissions of an existing file (also repairs files written by
/// older node versions that only set 0600 on Unix).
pub fn restrict_to_owner(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
    }

    #[cfg(windows)]
    {
        windows_restrict(path)
    }

    #[cfg(not(any(unix, windows)))]
    {
        let _ = path;
        Ok(())
    }
}

#[cfg(windows)]
fn windows_restrict(path: &Path) -> std::io::Result<()> {
    use std::os::windows::process::CommandExt;
    use std::process::Command;

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;

    let current_sid = Command::new("whoami")
        .args(["/user", "/fo", "csv", "/nh"])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| parse_whoami_sid(&String::from_utf8_lossy(&output.stdout)));

    let args = icacls_args(path, current_sid.as_deref());
    let output = Command::new("icacls")
        .args(&args)
        .creation_flags(CREATE_NO_WINDOW)
        .output()?;
    if output.status.success() {
        Ok(())
    } else {
        Err(std::io::Error::other(format!(
            "icacls exited with {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        )))
    }
}

/// Arguments for `icacls`: drop inherited ACEs and grant full control to
/// SYSTEM, Administrators and (when it is neither) the current account.
#[cfg_attr(not(windows), allow(dead_code))]
fn icacls_args(path: &Path, current_sid: Option<&str>) -> Vec<String> {
    let mut args = vec![
        path.to_string_lossy().to_string(),
        "/inheritance:r".to_string(),
        "/grant:r".to_string(),
        format!("*{SYSTEM_SID}:F"),
        format!("*{ADMINISTRATORS_SID}:F"),
    ];
    let extra = current_sid.filter(|sid| ![SYSTEM_SID, ADMINISTRATORS_SID].contains(sid));
    if let Some(sid) = extra {
        args.push(format!("*{sid}:F"));
    }
    args
}

/// Parse the SID out of `whoami /user /fo csv /nh`, whose output is a single
/// CSV row like `"nt authority\system","S-1-5-18"`.
#[cfg_attr(not(windows), allow(dead_code))]
fn parse_whoami_sid(output: &str) -> Option<String> {
    let line = output.lines().find(|line| !line.trim().is_empty())?;
    let sid = line.rsplit(',').next()?.trim().trim_matches('"').trim();
    (sid.starts_with("S-1-") && sid.len() > 4).then(|| sid.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_whoami_csv_output() {
        assert_eq!(
            parse_whoami_sid("\"nt authority\\system\",\"S-1-5-18\"\r\n").as_deref(),
            Some("S-1-5-18")
        );
        assert_eq!(
            parse_whoami_sid("\"host\\alice\",\"S-1-5-21-1-2-3-1001\"").as_deref(),
            Some("S-1-5-21-1-2-3-1001")
        );
        assert_eq!(parse_whoami_sid(""), None);
        assert_eq!(parse_whoami_sid("garbage"), None);
    }

    #[test]
    fn icacls_args_grant_system_admins_and_current_user() {
        let args = icacls_args(Path::new("key"), Some("S-1-5-21-1-2-3-1001"));
        assert_eq!(
            args,
            vec![
                "key",
                "/inheritance:r",
                "/grant:r",
                "*S-1-5-18:F",
                "*S-1-5-32-544:F",
                "*S-1-5-21-1-2-3-1001:F",
            ]
        );
        // Running as LocalSystem: no duplicate grant.
        assert_eq!(icacls_args(Path::new("key"), Some("S-1-5-18")).len(), 5);
        assert_eq!(icacls_args(Path::new("key"), None).len(), 5);
    }

    #[cfg(unix)]
    #[test]
    fn write_private_sets_owner_only_mode() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("teale-secure-{}", uuid::Uuid::new_v4()));
        let path = dir.join("nested").join("secret");
        write_private(&path, b"abc").expect("write private");
        assert_eq!(std::fs::read(&path).expect("read back"), b"abc");
        let mode = std::fs::metadata(&path).expect("meta").permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
