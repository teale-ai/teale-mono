use anyhow::{bail, Context, Result};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

#[derive(Clone, Serialize, Deserialize)]
pub struct Change {
    pub path: PathBuf,
    pub before: Option<String>,
    pub after: Option<String>,
}

/// Advisory OS lock released on process death; never steal a timed-out holder.
pub fn lock(root: &Path) -> Result<File> {
    safe_parents(root)?;
    fs::create_dir_all(root)?;
    private_dir(root)?;
    let path = root.join("lock");
    no_symlink(&path)?;
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)?;
    private_file(&file)?;
    let started = Instant::now();
    loop {
        match file.try_lock_exclusive() {
            Ok(()) => return Ok(file),
            Err(e)
                if e.kind() == std::io::ErrorKind::WouldBlock
                    && started.elapsed() < Duration::from_secs(5) =>
            {
                std::thread::sleep(Duration::from_millis(50))
            }
            Err(e) => return Err(e).context("connector lock unavailable; no files changed"),
        }
    }
}
fn no_symlink(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => bail!("symlink refused: {}", path.display()),
        Ok(_) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e.into()),
    }
}
fn safe_parents(path: &Path) -> Result<()> {
    for parent in path.ancestors() {
        no_symlink(parent)?;
    }
    Ok(())
}
pub fn read(path: &Path) -> Result<Option<String>> {
    safe_parents(path)?;
    match fs::read_to_string(path) {
        Ok(value) => Ok(Some(value)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e).with_context(|| format!("cannot read {}", path.display())),
    }
}
fn private_file(file: &File) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    Ok(())
}
fn private_dir(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}
fn write_atomic(path: &Path, value: &Option<String>) -> Result<()> {
    safe_parents(path)?;
    match value {
        Some(value) => {
            let parent = path.parent().context("file has no parent")?;
            fs::create_dir_all(parent)?;
            let mut temp = tempfile::NamedTempFile::new_in(parent)?;
            private_file(temp.as_file())?;
            temp.write_all(value.as_bytes())?;
            temp.as_file().sync_all()?;
            temp.persist(path).map_err(|e| e.error)?;
            #[cfg(unix)]
            File::open(parent)?.sync_all()?;
        }
        None => match fs::remove_file(path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        },
    }
    Ok(())
}
pub fn require_clean(root: &Path) -> Result<()> {
    if root.join("journal.json").exists() {
        bail!("interrupted transaction; run connections recover first");
    }
    Ok(())
}
/// Persist inverse evidence before any write, including receipt creation/deletion.
pub fn apply(root: &Path, changes: Vec<Change>) -> Result<()> {
    require_clean(root)?;
    for change in &changes {
        if read(&change.path)? != change.before {
            bail!("configuration changed; preserved {}", change.path.display());
        }
    }
    let journal = root.join("journal.json");
    write_atomic(&journal, &Some(serde_json::to_string(&changes)?))?;
    for change in &changes {
        let outcome = (|| {
            if read(&change.path)? != change.before {
                bail!(
                    "concurrent configuration edit; preserved {}",
                    change.path.display()
                );
            }
            write_atomic(&change.path, &change.after)
        })();
        if let Err(error) = outcome {
            return match recover(root) {
                Ok(()) => Err(error),
                Err(recovery) => Err(error).context(format!("rollback pending: {recovery}")),
            };
        }
    }
    write_atomic(&journal, &None)?;
    Ok(())
}
pub fn recover(root: &Path) -> Result<()> {
    let journal = root.join("journal.json");
    let Some(source) = read(&journal)? else {
        return Ok(());
    };
    let changes: Vec<Change> = serde_json::from_str(&source).context("invalid recovery journal")?;
    // Validate every file before changing any. Never replace edits from another process.
    for change in &changes {
        let current = read(&change.path)?;
        if current != change.before && current != change.after {
            bail!("recovery conflict; preserved {}", change.path.display());
        }
    }
    for change in changes.iter().rev() {
        let current = read(&change.path)?;
        if current == change.before {
            continue;
        }
        if current != change.after {
            bail!(
                "concurrent recovery edit; preserved {}",
                change.path.display()
            );
        }
        write_atomic(&change.path, &change.before)?;
    }
    write_atomic(&journal, &None)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn apply_and_restore_exact_bytes() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("state");
        let _guard = lock(&root).unwrap();
        let path = dir.path().join("config");
        fs::write(&path, "original # comment\n").unwrap();
        let change = Change {
            path: path.clone(),
            before: read(&path).unwrap(),
            after: Some("new\n".into()),
        };
        apply(&root, vec![change.clone()]).unwrap();
        apply(
            &root,
            vec![Change {
                path: path.clone(),
                before: change.after,
                after: change.before,
            }],
        )
        .unwrap();
        assert_eq!(read(&path).unwrap().unwrap(), "original # comment\n");
    }
    #[test]
    fn interrupted_write_recovery_and_conflict() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("state");
        let _g = lock(&root).unwrap();
        let path = dir.path().join("config");
        let c = Change {
            path: path.clone(),
            before: Some("old".into()),
            after: Some("new".into()),
        };
        write_atomic(
            &root.join("journal.json"),
            &Some(serde_json::to_string(&vec![c]).unwrap()),
        )
        .unwrap();
        fs::write(&path, "user edit").unwrap();
        assert!(recover(&root).is_err());
        assert_eq!(read(&path).unwrap().unwrap(), "user edit");
        assert!(require_clean(&root).is_err());
        fs::write(&path, "new").unwrap();
        recover(&root).unwrap();
        assert_eq!(read(&path).unwrap().unwrap(), "old");
    }
    #[test]
    fn remove_preserves_user_edits() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("state");
        let _g = lock(&root).unwrap();
        let path = dir.path().join("config");
        fs::write(&path, "user changed credential").unwrap();
        assert!(apply(
            &root,
            vec![Change {
                path: path.clone(),
                before: Some("owned".into()),
                after: None
            }]
        )
        .is_err());
        assert_eq!(read(&path).unwrap().unwrap(), "user changed credential");
    }
    #[test]
    fn lock_excludes_second_writer() {
        let dir = tempfile::tempdir().unwrap();
        let _g = lock(dir.path()).unwrap();
        let second = OpenOptions::new()
            .read(true)
            .write(true)
            .open(dir.path().join("lock"))
            .unwrap();
        assert!(second.try_lock_exclusive().is_err());
    }
    #[cfg(unix)]
    #[test]
    fn symlinks_refused_and_secrets_private() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config");
        write_atomic(&path, &Some("secret".into())).unwrap();
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        symlink(&path, dir.path().join("link")).unwrap();
        assert!(read(&dir.path().join("link")).is_err());
    }
}

#[cfg(test)]
mod crash_tests {
    use super::*;
    #[test]
    fn partial_multifile_transaction_rolls_back_and_recovery_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("state");
        let _g = lock(&root).unwrap();
        let first = dir.path().join("config");
        let receipt = root.join("receipt.json");
        let changes = vec![
            Change {
                path: first.clone(),
                before: None,
                after: Some("provider with fake key".into()),
            },
            Change {
                path: receipt.clone(),
                before: None,
                after: Some("fake receipt".into()),
            },
        ];
        write_atomic(
            &root.join("journal.json"),
            &Some(serde_json::to_string(&changes).unwrap()),
        )
        .unwrap();
        write_atomic(&first, &changes[0].after).unwrap();
        // Simulates a killed process after configuration write, before receipt commit.
        recover(&root).unwrap();
        assert_eq!(read(&first).unwrap(), None);
        assert_eq!(read(&receipt).unwrap(), None);
        recover(&root).unwrap();
    }
}
