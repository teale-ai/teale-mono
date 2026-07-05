//! Private Inference Networks (PIN) control-plane storage.
//!
//! The gateway is coordination-only for PINs: membership, roles, join codes,
//! netmap generations, and usage COUNTS. PIN code paths must NEVER write to
//! the `ledger` or `balances` tables — PINs have token counting, not credits
//! (see spec §8).

use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::db::{unix_now, DbPool};

/// Unambiguous join-code alphabet: no I, L, O, 0, 1.
const JOIN_CODE_ALPHABET: &[u8] = b"ABCDEFGHJKMNPQRSTVWXYZ23456789";

pub const ROLE_ADMIN: &str = "admin";
pub const ROLE_MODELRATOR: &str = "modelrator";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct PinSettings {
    pub din_contribution_default: bool,
    pub priority_policy: String,
}

impl Default for PinSettings {
    fn default() -> Self {
        Self {
            din_contribution_default: true,
            priority_policy: "pin_first".to_string(),
        }
    }
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Pin {
    pub pin_id: String,
    pub name: String,
    pub join_code: String,
    pub join_code_generation: i64,
    pub owner_account_user_id: String,
    pub netmap_generation: i64,
    pub settings: PinSettings,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PinMember {
    pub pin_id: String,
    pub device_id: String,
    pub node_pubkey: String,
    pub wg_pubkey: String,
    pub display_name: Option<String>,
    pub status: String,
    pub serves_models: bool,
    pub allow_remote_models: bool,
    pub endpoints: String,
    pub loaded_models: String,
    pub requested_at: i64,
    pub approved_by: Option<String>,
    pub joined_at: Option<i64>,
    pub last_seen: Option<i64>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PinSummary {
    pub pin_id: String,
    pub name: String,
    pub role: String,
    pub active_count: i64,
    pub pending_count: i64,
    pub netmap_generation: i64,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PinMembershipSummary {
    pub pin_id: String,
    pub name: String,
    pub status: String,
}

pub fn generate_join_code() -> String {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    let mut pick = |n: usize| -> String {
        (0..n)
            .map(|_| JOIN_CODE_ALPHABET[rng.gen_range(0..JOIN_CODE_ALPHABET.len())] as char)
            .collect()
    };
    format!("{}-{}-{}", pick(4), pick(4), pick(2))
}

/// Uppercase and strip everything outside the code alphabet so lookups
/// tolerate lowercase input and missing/extra dashes.
fn normalize_join_code(code: &str) -> String {
    code.chars()
        .filter_map(|c| {
            let up = c.to_ascii_uppercase();
            JOIN_CODE_ALPHABET.contains(&(up as u8)).then_some(up)
        })
        .collect()
}

fn row_to_pin(row: &rusqlite::Row<'_>) -> rusqlite::Result<Pin> {
    let settings_json: String = row.get("settings")?;
    Ok(Pin {
        pin_id: row.get("pin_id")?,
        name: row.get("name")?,
        join_code: row.get("join_code")?,
        join_code_generation: row.get("join_code_generation")?,
        owner_account_user_id: row.get("owner_account_user_id")?,
        netmap_generation: row.get("netmap_generation")?,
        settings: serde_json::from_str(&settings_json).unwrap_or_default(),
        created_at: row.get("created_at")?,
    })
}

const PIN_COLUMNS: &str = "pin_id, name, join_code, join_code_generation, \
     owner_account_user_id, netmap_generation, settings, created_at";

pub fn create_pin(pool: &DbPool, name: &str, owner_account: &str) -> anyhow::Result<Pin> {
    let name = name.trim();
    anyhow::ensure!(!name.is_empty(), "network name is required");
    let mut conn = pool.lock();
    let tx = conn.transaction()?;
    let now = unix_now();
    let pin_id = uuid::Uuid::new_v4().to_string();
    let join_code = generate_join_code();
    let settings = serde_json::to_string(&PinSettings::default())?;
    tx.execute(
        "INSERT INTO pins (pin_id, name, join_code, owner_account_user_id, settings, created_at)
         VALUES (?, ?, ?, ?, ?, ?)",
        params![pin_id, name, join_code, owner_account, settings, now],
    )?;
    tx.execute(
        "INSERT INTO pin_roles (pin_id, account_user_id, role, granted_by, granted_at)
         VALUES (?, ?, 'admin', ?, ?)",
        params![pin_id, owner_account, owner_account, now],
    )?;
    tx.commit()?;
    drop(conn);
    get_pin(pool, &pin_id)?.ok_or_else(|| anyhow::anyhow!("pin vanished after create"))
}

pub fn get_pin(pool: &DbPool, pin_id: &str) -> anyhow::Result<Option<Pin>> {
    let conn = pool.lock();
    let pin = conn
        .query_row(
            &format!("SELECT {PIN_COLUMNS} FROM pins WHERE pin_id = ? AND deleted_at IS NULL"),
            [pin_id],
            row_to_pin,
        )
        .optional()?;
    Ok(pin)
}

pub fn find_by_join_code(pool: &DbPool, code: &str) -> anyhow::Result<Option<Pin>> {
    let normalized = normalize_join_code(code);
    if normalized.is_empty() {
        return Ok(None);
    }
    let conn = pool.lock();
    // The table is small (one row per network); normalize in Rust rather than
    // depending on SQLite collation tricks.
    let mut stmt = conn.prepare(&format!(
        "SELECT {PIN_COLUMNS} FROM pins WHERE deleted_at IS NULL"
    ))?;
    let pins = stmt
        .query_map([], row_to_pin)?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(pins
        .into_iter()
        .find(|p| normalize_join_code(&p.join_code) == normalized))
}

pub fn submit_join(
    pool: &DbPool,
    pin_id: &str,
    device_id: &str,
    node_pubkey: &str,
    display_name: Option<&str>,
) -> anyhow::Result<()> {
    let conn = pool.lock();
    let now = unix_now();
    let existing: Option<String> = conn
        .query_row(
            "SELECT status FROM pin_members WHERE pin_id = ? AND device_id = ?",
            params![pin_id, device_id],
            |r| r.get(0),
        )
        .optional()?;
    match existing.as_deref() {
        None => {
            conn.execute(
                "INSERT INTO pin_members
                    (pin_id, device_id, node_pubkey, display_name, status, requested_at)
                 VALUES (?, ?, ?, ?, 'pending', ?)",
                params![pin_id, device_id, node_pubkey, display_name, now],
            )?;
        }
        // Re-knock refreshes the pending request; a removed device may
        // rehabilitate itself back into the approval queue.
        Some("pending") | Some("removed") => {
            conn.execute(
                "UPDATE pin_members
                 SET status = 'pending', node_pubkey = ?,
                     display_name = COALESCE(?, display_name),
                     requested_at = ?, approved_by = NULL, joined_at = NULL,
                     removed_at = NULL, removed_by = NULL
                 WHERE pin_id = ? AND device_id = ?",
                params![node_pubkey, display_name, now, pin_id, device_id],
            )?;
        }
        // Already in the network (active or disabled): knocking is a no-op.
        Some(_) => {}
    }
    Ok(())
}

pub fn role_of(pool: &DbPool, pin_id: &str, account: &str) -> anyhow::Result<Option<String>> {
    let conn = pool.lock();
    let owner: Option<String> = conn
        .query_row(
            "SELECT owner_account_user_id FROM pins WHERE pin_id = ? AND deleted_at IS NULL",
            [pin_id],
            |r| r.get(0),
        )
        .optional()?;
    if owner.as_deref() == Some(account) {
        return Ok(Some(ROLE_ADMIN.to_string()));
    }
    let role: Option<String> = conn
        .query_row(
            "SELECT role FROM pin_roles WHERE pin_id = ? AND account_user_id = ?",
            params![pin_id, account],
            |r| r.get(0),
        )
        .optional()?;
    Ok(role)
}

fn require_admin(pool: &DbPool, pin_id: &str, account: &str) -> anyhow::Result<()> {
    match role_of(pool, pin_id, account)?.as_deref() {
        Some(ROLE_ADMIN) => Ok(()),
        _ => anyhow::bail!("account {account} is not an admin of this network"),
    }
}

pub fn approve_member(
    pool: &DbPool,
    pin_id: &str,
    device_id: &str,
    approver_account: &str,
) -> anyhow::Result<()> {
    require_admin(pool, pin_id, approver_account)?;
    let mut conn = pool.lock();
    let tx = conn.transaction()?;
    let now = unix_now();
    let changed = tx.execute(
        "UPDATE pin_members
         SET status = 'active', approved_by = ?, joined_at = ?
         WHERE pin_id = ? AND device_id = ? AND status = 'pending'",
        params![approver_account, now, pin_id, device_id],
    )?;
    anyhow::ensure!(changed == 1, "no pending join request for this device");
    tx.execute(
        "UPDATE pins SET netmap_generation = netmap_generation + 1 WHERE pin_id = ?",
        [pin_id],
    )?;
    tx.commit()?;
    Ok(())
}

pub fn deny_member(pool: &DbPool, pin_id: &str, device_id: &str) -> anyhow::Result<()> {
    let conn = pool.lock();
    let changed = conn.execute(
        "DELETE FROM pin_members WHERE pin_id = ? AND device_id = ? AND status = 'pending'",
        params![pin_id, device_id],
    )?;
    anyhow::ensure!(changed == 1, "no pending join request for this device");
    Ok(())
}

pub fn remove_member(
    pool: &DbPool,
    pin_id: &str,
    device_id: &str,
    remover: &str,
) -> anyhow::Result<()> {
    let mut conn = pool.lock();
    let tx = conn.transaction()?;
    let now = unix_now();
    let changed = tx.execute(
        "UPDATE pin_members
         SET status = 'removed', removed_at = ?, removed_by = ?
         WHERE pin_id = ? AND device_id = ? AND status IN ('active','disabled')",
        params![now, remover, pin_id, device_id],
    )?;
    anyhow::ensure!(changed == 1, "device is not a member of this network");
    tx.execute(
        "UPDATE pins SET netmap_generation = netmap_generation + 1 WHERE pin_id = ?",
        [pin_id],
    )?;
    tx.commit()?;
    Ok(())
}

pub fn set_member_disabled(
    pool: &DbPool,
    pin_id: &str,
    device_id: &str,
    disabled: bool,
) -> anyhow::Result<()> {
    let (from, to) = if disabled {
        ("active", "disabled")
    } else {
        ("disabled", "active")
    };
    let mut conn = pool.lock();
    let tx = conn.transaction()?;
    let changed = tx.execute(
        "UPDATE pin_members SET status = ? WHERE pin_id = ? AND device_id = ? AND status = ?",
        params![to, pin_id, device_id, from],
    )?;
    anyhow::ensure!(changed == 1, "device is not {from} in this network");
    tx.execute(
        "UPDATE pins SET netmap_generation = netmap_generation + 1 WHERE pin_id = ?",
        [pin_id],
    )?;
    tx.commit()?;
    Ok(())
}

pub fn update_member(
    pool: &DbPool,
    pin_id: &str,
    device_id: &str,
    display_name: Option<&str>,
    serves_models: Option<bool>,
) -> anyhow::Result<()> {
    let mut conn = pool.lock();
    let tx = conn.transaction()?;
    let mut bump = false;
    if let Some(name) = display_name {
        let changed = tx.execute(
            "UPDATE pin_members SET display_name = ? WHERE pin_id = ? AND device_id = ?",
            params![name, pin_id, device_id],
        )?;
        anyhow::ensure!(changed == 1, "device is not a member of this network");
    }
    if let Some(serves) = serves_models {
        let changed = tx.execute(
            "UPDATE pin_members SET serves_models = ?
             WHERE pin_id = ? AND device_id = ? AND serves_models != ?",
            params![serves, pin_id, device_id, serves],
        )?;
        bump = changed == 1;
    }
    if bump {
        tx.execute(
            "UPDATE pins SET netmap_generation = netmap_generation + 1 WHERE pin_id = ?",
            [pin_id],
        )?;
    }
    tx.commit()?;
    Ok(())
}

pub fn rotate_join_code(pool: &DbPool, pin_id: &str) -> anyhow::Result<String> {
    let code = generate_join_code();
    let conn = pool.lock();
    let changed = conn.execute(
        "UPDATE pins SET join_code = ?, join_code_generation = join_code_generation + 1
         WHERE pin_id = ? AND deleted_at IS NULL",
        params![code, pin_id],
    )?;
    anyhow::ensure!(changed == 1, "unknown network");
    Ok(code)
}

pub fn grant_role(
    pool: &DbPool,
    pin_id: &str,
    account: &str,
    role: &str,
    granted_by: &str,
) -> anyhow::Result<()> {
    anyhow::ensure!(
        role == ROLE_ADMIN || role == ROLE_MODELRATOR,
        "unknown role {role}"
    );
    let conn = pool.lock();
    let now = unix_now();
    conn.execute(
        "INSERT INTO pin_roles (pin_id, account_user_id, role, granted_by, granted_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(pin_id, account_user_id) DO UPDATE SET
            role = excluded.role, granted_by = excluded.granted_by,
            granted_at = excluded.granted_at",
        params![pin_id, account, role, granted_by, now],
    )?;
    Ok(())
}

pub fn revoke_role(pool: &DbPool, pin_id: &str, account: &str) -> anyhow::Result<()> {
    let conn = pool.lock();
    let owner: Option<String> = conn
        .query_row(
            "SELECT owner_account_user_id FROM pins WHERE pin_id = ?",
            [pin_id],
            |r| r.get(0),
        )
        .optional()?;
    anyhow::ensure!(owner.is_some(), "unknown network");
    anyhow::ensure!(
        owner.as_deref() != Some(account),
        "cannot revoke the owner's role; transfer ownership first"
    );
    let target_role: Option<String> = conn
        .query_row(
            "SELECT role FROM pin_roles WHERE pin_id = ? AND account_user_id = ?",
            params![pin_id, account],
            |r| r.get(0),
        )
        .optional()?;
    if target_role.as_deref() == Some(ROLE_ADMIN) {
        let admins: i64 = conn.query_row(
            "SELECT count(*) FROM pin_roles WHERE pin_id = ? AND role = 'admin'",
            [pin_id],
            |r| r.get(0),
        )?;
        anyhow::ensure!(admins > 1, "cannot remove the last admin");
    }
    conn.execute(
        "DELETE FROM pin_roles WHERE pin_id = ? AND account_user_id = ?",
        params![pin_id, account],
    )?;
    Ok(())
}

pub fn pins_for_account(pool: &DbPool, account: &str) -> anyhow::Result<Vec<PinSummary>> {
    let conn = pool.lock();
    let mut stmt = conn.prepare(
        "SELECT p.pin_id, p.name, r.role, p.netmap_generation, p.created_at,
            (SELECT count(*) FROM pin_members m
              WHERE m.pin_id = p.pin_id AND m.status IN ('active','disabled')) AS active_count,
            (SELECT count(*) FROM pin_members m
              WHERE m.pin_id = p.pin_id AND m.status = 'pending') AS pending_count
         FROM pins p JOIN pin_roles r ON r.pin_id = p.pin_id
         WHERE r.account_user_id = ? AND p.deleted_at IS NULL
         ORDER BY p.created_at",
    )?;
    let rows = stmt
        .query_map([account], |row| {
            Ok(PinSummary {
                pin_id: row.get(0)?,
                name: row.get(1)?,
                role: row.get(2)?,
                netmap_generation: row.get(3)?,
                created_at: row.get(4)?,
                active_count: row.get(5)?,
                pending_count: row.get(6)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

pub fn pins_for_device(
    pool: &DbPool,
    device_id: &str,
) -> anyhow::Result<Vec<PinMembershipSummary>> {
    let conn = pool.lock();
    let mut stmt = conn.prepare(
        "SELECT p.pin_id, p.name, m.status
         FROM pins p JOIN pin_members m ON m.pin_id = p.pin_id
         WHERE m.device_id = ? AND m.status != 'removed' AND p.deleted_at IS NULL
         ORDER BY p.created_at",
    )?;
    let rows = stmt
        .query_map([device_id], |row| {
            Ok(PinMembershipSummary {
                pin_id: row.get(0)?,
                name: row.get(1)?,
                status: row.get(2)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

pub fn members(pool: &DbPool, pin_id: &str) -> anyhow::Result<Vec<PinMember>> {
    let conn = pool.lock();
    let mut stmt = conn.prepare(
        "SELECT pin_id, device_id, node_pubkey, wg_pubkey, display_name, status, serves_models,
                allow_remote_models, endpoints, loaded_models, requested_at, approved_by,
                joined_at, last_seen
         FROM pin_members
         WHERE pin_id = ? AND status != 'removed'
         ORDER BY requested_at",
    )?;
    let rows = stmt
        .query_map([pin_id], |row| {
            Ok(PinMember {
                pin_id: row.get(0)?,
                device_id: row.get(1)?,
                node_pubkey: row.get(2)?,
                wg_pubkey: row.get(3)?,
                display_name: row.get(4)?,
                status: row.get(5)?,
                serves_models: row.get::<_, i64>(6)? != 0,
                allow_remote_models: row.get::<_, i64>(7)? != 0,
                endpoints: row.get(8)?,
                loaded_models: row.get(9)?,
                requested_at: row.get(10)?,
                approved_by: row.get(11)?,
                joined_at: row.get(12)?,
                last_seen: row.get(13)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

pub fn touch_member_last_seen(pool: &DbPool, pin_id: &str, device_id: &str) -> anyhow::Result<()> {
    let conn = pool.lock();
    conn.execute(
        "UPDATE pin_members SET last_seen = ? WHERE pin_id = ? AND device_id = ?",
        params![unix_now(), pin_id, device_id],
    )?;
    Ok(())
}

pub fn update_member_endpoints(
    pool: &DbPool,
    pin_id: &str,
    device_id: &str,
    endpoints_json: &str,
    loaded_models_json: &str,
    wg_pubkey: &str,
) -> anyhow::Result<()> {
    // Validate it's JSON before persisting; these fields are relayed to peers.
    let _: serde_json::Value = serde_json::from_str(endpoints_json)?;
    let _: serde_json::Value = serde_json::from_str(loaded_models_json)?;
    let conn = pool.lock();
    conn.execute(
        "UPDATE pin_members SET endpoints = ?, loaded_models = ?, wg_pubkey = ?, last_seen = ?
         WHERE pin_id = ? AND device_id = ?",
        params![
            endpoints_json,
            loaded_models_json,
            wg_pubkey,
            unix_now(),
            pin_id,
            device_id
        ],
    )?;
    Ok(())
}

pub fn delete_pin(pool: &DbPool, pin_id: &str) -> anyhow::Result<()> {
    let conn = pool.lock();
    let changed = conn.execute(
        "UPDATE pins SET deleted_at = ? WHERE pin_id = ? AND deleted_at IS NULL",
        params![unix_now(), pin_id],
    )?;
    anyhow::ensure!(changed == 1, "unknown network");
    Ok(())
}

/// Live (heartbeat-derived) view of a member device, looked up by node
/// pubkey. `None` means the device is not currently connected.
pub struct LiveMemberInfo {
    pub loaded_models: Vec<String>,
}

/// Assemble the current netmap for a network. `live` resolves a member's
/// node pubkey to registry state when the device is online; offline members
/// appear with their persisted endpoints and no loaded models.
pub fn build_netmap(
    pool: &DbPool,
    pin_id: &str,
    live: impl Fn(&str) -> Option<LiveMemberInfo>,
) -> anyhow::Result<teale_protocol::PinNetmap> {
    let pin = get_pin(pool, pin_id)?.ok_or_else(|| anyhow::anyhow!("unknown network"))?;
    let members = members(pool, pin_id)?
        .into_iter()
        .filter(|m| m.status == "active" || m.status == "disabled")
        .map(|m| {
            let disabled = m.status == "disabled";
            let live_info = live(&m.node_pubkey);
            teale_protocol::PinNetmapMember {
                device_id: m.device_id,
                node_pubkey: m.node_pubkey,
                wg_pubkey: m.wg_pubkey,
                display_name: m.display_name,
                serves_models: m.serves_models,
                disabled,
                // Disabled devices stay listed (peers must recognize and
                // reject them) but their endpoints are withheld.
                endpoints: if disabled {
                    Vec::new()
                } else {
                    serde_json::from_str(&m.endpoints).unwrap_or_default()
                },
                loaded_models: live_info
                    .map(|i| i.loaded_models)
                    .unwrap_or_else(|| serde_json::from_str(&m.loaded_models).unwrap_or_default()),
                last_seen: m.last_seen,
            }
        })
        .collect();
    Ok(teale_protocol::PinNetmap {
        pin_id: pin.pin_id,
        name: pin.name,
        generation: pin.netmap_generation,
        issued_at: unix_now(),
        members,
    })
}

pub fn sign_netmap(
    netmap: teale_protocol::PinNetmap,
    identity: &crate::identity::GatewayIdentity,
) -> anyhow::Result<teale_protocol::SignedPinNetmap> {
    let message = teale_protocol::canonical_json(&netmap)?;
    Ok(teale_protocol::SignedPinNetmap {
        gateway_pubkey: identity.public_key_hex(),
        signature: identity.sign_hex(&message),
        netmap,
    })
}

pub fn set_settings(pool: &DbPool, pin_id: &str, settings: &PinSettings) -> anyhow::Result<()> {
    let json = serde_json::to_string(settings)?;
    let conn = pool.lock();
    let changed = conn.execute(
        "UPDATE pins SET settings = ? WHERE pin_id = ? AND deleted_at IS NULL",
        params![json, pin_id],
    )?;
    anyhow::ensure!(changed == 1, "unknown network");
    Ok(())
}

pub fn member_status(
    pool: &DbPool,
    pin_id: &str,
    device_id: &str,
) -> anyhow::Result<Option<String>> {
    let conn = pool.lock();
    Ok(conn
        .query_row(
            "SELECT status FROM pin_members WHERE pin_id = ? AND device_id = ?",
            params![pin_id, device_id],
            |r| r.get(0),
        )
        .optional()?)
}

pub fn set_allow_remote_models(
    pool: &DbPool,
    pin_id: &str,
    device_id: &str,
    allow: bool,
) -> anyhow::Result<()> {
    let conn = pool.lock();
    conn.execute(
        "UPDATE pin_members SET allow_remote_models = ? WHERE pin_id = ? AND device_id = ?",
        params![allow, pin_id, device_id],
    )?;
    Ok(())
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ModelPolicyEntry {
    pub device_id: String,
    pub model_id: String,
    pub desired_state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub applied_state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    pub set_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub applied_at: Option<i64>,
}

/// Full-replace the desired loadout for one device. `models` is
/// (model_id, desired_state) with state in {loaded, downloaded, none}.
pub fn set_model_policy(
    pool: &DbPool,
    pin_id: &str,
    device_id: &str,
    models: &[(String, String)],
    set_by: &str,
) -> anyhow::Result<()> {
    for (_, state) in models {
        anyhow::ensure!(
            matches!(state.as_str(), "loaded" | "downloaded" | "none"),
            "invalid desired state {state}"
        );
    }
    let mut conn = pool.lock();
    let tx = conn.transaction()?;
    let now = unix_now();
    tx.execute(
        "DELETE FROM pin_model_policy WHERE pin_id = ? AND device_id = ?",
        params![pin_id, device_id],
    )?;
    for (model_id, state) in models {
        tx.execute(
            "INSERT INTO pin_model_policy
                (pin_id, device_id, model_id, desired_state, set_by, set_at)
             VALUES (?, ?, ?, ?, ?, ?)",
            params![pin_id, device_id, model_id, state, set_by, now],
        )?;
    }
    tx.commit()?;
    Ok(())
}

pub fn model_policy(
    pool: &DbPool,
    pin_id: &str,
    device_id: Option<&str>,
) -> anyhow::Result<Vec<ModelPolicyEntry>> {
    let conn = pool.lock();
    let sql =
        "SELECT device_id, model_id, desired_state, applied_state, last_error, set_at, applied_at
         FROM pin_model_policy WHERE pin_id = ?";
    let map_row = |row: &rusqlite::Row<'_>| -> rusqlite::Result<ModelPolicyEntry> {
        Ok(ModelPolicyEntry {
            device_id: row.get(0)?,
            model_id: row.get(1)?,
            desired_state: row.get(2)?,
            applied_state: row.get(3)?,
            last_error: row.get(4)?,
            set_at: row.get(5)?,
            applied_at: row.get(6)?,
        })
    };
    let rows = match device_id {
        Some(dev) => {
            let mut stmt = conn.prepare(&format!("{sql} AND device_id = ? ORDER BY model_id"))?;
            let rows = stmt.query_map(params![pin_id, dev], map_row)?;
            rows.collect::<Result<Vec<_>, _>>()?
        }
        None => {
            let mut stmt = conn.prepare(&format!("{sql} ORDER BY device_id, model_id"))?;
            let rows = stmt.query_map(params![pin_id], map_row)?;
            rows.collect::<Result<Vec<_>, _>>()?
        }
    };
    Ok(rows)
}

/// Device-reported reconciliation status: (model_id, applied_state, error).
pub fn report_model_policy_status(
    pool: &DbPool,
    pin_id: &str,
    device_id: &str,
    statuses: &[(String, String, Option<String>)],
) -> anyhow::Result<()> {
    let mut conn = pool.lock();
    let tx = conn.transaction()?;
    let now = unix_now();
    for (model_id, applied, error) in statuses {
        tx.execute(
            "UPDATE pin_model_policy
             SET applied_state = ?, applied_at = ?, last_error = ?
             WHERE pin_id = ? AND device_id = ? AND model_id = ?",
            params![applied, now, error.as_deref(), pin_id, device_id, model_id],
        )?;
    }
    tx.commit()?;
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageEntry {
    /// YYYY-MM-DD (UTC).
    pub day: String,
    pub consumer_device_id: String,
    pub model_id: String,
    pub requests: i64,
    pub tokens_in: i64,
    pub tokens_out: i64,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageRow {
    pub day: String,
    pub provider_device_id: String,
    pub consumer_device_id: String,
    pub model_id: String,
    pub requests: i64,
    pub tokens_in: i64,
    pub tokens_out: i64,
}

/// Additive upsert of a provider's usage batch. Returns false when the batch
/// id was already applied (idempotent replay from a device whose ack was
/// lost). NEVER touches ledger/balances.
pub fn record_usage_batch(
    pool: &DbPool,
    pin_id: &str,
    provider_device_id: &str,
    batch_id: &str,
    entries: &[UsageEntry],
) -> anyhow::Result<bool> {
    let mut conn = pool.lock();
    let tx = conn.transaction()?;
    let inserted = tx.execute(
        "INSERT OR IGNORE INTO pin_usage_batches
            (pin_id, provider_device_id, batch_id, received_at)
         VALUES (?, ?, ?, ?)",
        params![pin_id, provider_device_id, batch_id, unix_now()],
    )?;
    if inserted == 0 {
        return Ok(false); // duplicate batch — drop without applying
    }
    for e in entries {
        anyhow::ensure!(
            e.requests >= 0 && e.tokens_in >= 0 && e.tokens_out >= 0,
            "usage counts must be non-negative"
        );
        tx.execute(
            "INSERT INTO pin_usage
                (pin_id, day, provider_device_id, consumer_device_id, model_id,
                 requests, tokens_in, tokens_out)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(pin_id, day, provider_device_id, consumer_device_id, model_id)
             DO UPDATE SET
                requests = requests + excluded.requests,
                tokens_in = tokens_in + excluded.tokens_in,
                tokens_out = tokens_out + excluded.tokens_out",
            params![
                pin_id,
                e.day,
                provider_device_id,
                e.consumer_device_id,
                e.model_id,
                e.requests,
                e.tokens_in,
                e.tokens_out,
            ],
        )?;
    }
    tx.commit()?;
    Ok(true)
}

/// Raw usage rows, optionally bounded to [from, to] days (inclusive) and
/// filtered to a single consumer (member self-scope).
pub fn usage_rows(
    pool: &DbPool,
    pin_id: &str,
    from: Option<&str>,
    to: Option<&str>,
    consumer_filter: Option<&str>,
) -> anyhow::Result<Vec<UsageRow>> {
    let conn = pool.lock();
    let mut sql = String::from(
        "SELECT day, provider_device_id, consumer_device_id, model_id,
                requests, tokens_in, tokens_out
         FROM pin_usage WHERE pin_id = ?",
    );
    let mut args: Vec<Box<dyn rusqlite::types::ToSql>> = vec![Box::new(pin_id.to_string())];
    if let Some(from) = from {
        sql.push_str(" AND day >= ?");
        args.push(Box::new(from.to_string()));
    }
    if let Some(to) = to {
        sql.push_str(" AND day <= ?");
        args.push(Box::new(to.to_string()));
    }
    if let Some(consumer) = consumer_filter {
        sql.push_str(" AND consumer_device_id = ?");
        args.push(Box::new(consumer.to_string()));
    }
    sql.push_str(" ORDER BY day, provider_device_id, consumer_device_id, model_id");
    let mut stmt = conn.prepare(&sql)?;
    let rows = stmt
        .query_map(
            rusqlite::params_from_iter(args.iter().map(|a| a.as_ref())),
            |row| {
                Ok(UsageRow {
                    day: row.get(0)?,
                    provider_device_id: row.get(1)?,
                    consumer_device_id: row.get(2)?,
                    model_id: row.get(3)?,
                    requests: row.get(4)?,
                    tokens_in: row.get(5)?,
                    tokens_out: row.get(6)?,
                })
            },
        )?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(rows)
}

pub fn bump_netmap_generation(pool: &DbPool, pin_id: &str) -> anyhow::Result<i64> {
    let conn = pool.lock();
    conn.execute(
        "UPDATE pins SET netmap_generation = netmap_generation + 1 WHERE pin_id = ?",
        [pin_id],
    )?;
    let gen: i64 = conn.query_row(
        "SELECT netmap_generation FROM pins WHERE pin_id = ?",
        [pin_id],
        |r| r.get(0),
    )?;
    Ok(gen)
}

pub fn netmap_generation(pool: &DbPool, pin_id: &str) -> anyhow::Result<i64> {
    let conn = pool.lock();
    Ok(conn.query_row(
        "SELECT netmap_generation FROM pins WHERE pin_id = ?",
        [pin_id],
        |r| r.get(0),
    )?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::open_in_memory;

    fn make_account(pool: &DbPool, account: &str) {
        let conn = pool.lock();
        let now = unix_now();
        conn.execute(
            "INSERT INTO account_wallets
                (account_user_id, balance_credits, usdc_cents, created_at, updated_at)
             VALUES (?, 0, 0, ?, ?)",
            params![account, now, now],
        )
        .unwrap();
    }

    fn setup() -> (DbPool, Pin) {
        let pool = open_in_memory().unwrap();
        make_account(&pool, "owner-acct");
        let pin = create_pin(&pool, "teale-hq", "owner-acct").unwrap();
        (pool, pin)
    }

    #[test]
    fn migration_013_creates_pin_tables() {
        let pool = open_in_memory().unwrap();
        let conn = pool.lock();
        for table in [
            "pins",
            "pin_roles",
            "pin_members",
            "pin_usage",
            "pin_model_policy",
        ] {
            let found: Option<String> = conn
                .query_row(
                    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
                    [table],
                    |r| r.get(0),
                )
                .ok();
            assert_eq!(found.as_deref(), Some(table), "missing table {table}");
        }
    }

    #[test]
    fn join_lifecycle_reaches_active() {
        let (pool, pin) = setup();
        submit_join(
            &pool,
            &pin.pin_id,
            "dev-1",
            "aa".repeat(32).as_str(),
            Some("Alice's PC"),
        )
        .unwrap();
        let m = &members(&pool, &pin.pin_id).unwrap()[0];
        assert_eq!(m.status, "pending");
        assert!(m.joined_at.is_none());

        approve_member(&pool, &pin.pin_id, "dev-1", "owner-acct").unwrap();
        let m = &members(&pool, &pin.pin_id).unwrap()[0];
        assert_eq!(m.status, "active");
        assert!(m.joined_at.is_some());
        assert_eq!(m.approved_by.as_deref(), Some("owner-acct"));
    }

    #[test]
    fn deny_deletes_pending_and_rejects_active() {
        let (pool, pin) = setup();
        submit_join(&pool, &pin.pin_id, "dev-1", "ab", None).unwrap();
        deny_member(&pool, &pin.pin_id, "dev-1").unwrap();
        assert!(members(&pool, &pin.pin_id).unwrap().is_empty());

        submit_join(&pool, &pin.pin_id, "dev-1", "ab", None).unwrap();
        approve_member(&pool, &pin.pin_id, "dev-1", "owner-acct").unwrap();
        assert!(deny_member(&pool, &pin.pin_id, "dev-1").is_err());
    }

    #[test]
    fn approve_requires_admin_role() {
        let (pool, pin) = setup();
        make_account(&pool, "mod-acct");
        make_account(&pool, "random-acct");
        grant_role(
            &pool,
            &pin.pin_id,
            "mod-acct",
            ROLE_MODELRATOR,
            "owner-acct",
        )
        .unwrap();
        submit_join(&pool, &pin.pin_id, "dev-1", "ab", None).unwrap();

        assert!(approve_member(&pool, &pin.pin_id, "dev-1", "mod-acct").is_err());
        assert!(approve_member(&pool, &pin.pin_id, "dev-1", "random-acct").is_err());
        approve_member(&pool, &pin.pin_id, "dev-1", "owner-acct").unwrap();
    }

    #[test]
    fn rotate_join_code_invalidates_old() {
        let (pool, pin) = setup();
        let new_code = rotate_join_code(&pool, &pin.pin_id).unwrap();
        assert_ne!(new_code, pin.join_code);
        assert!(find_by_join_code(&pool, &pin.join_code).unwrap().is_none());
        let found = find_by_join_code(&pool, &new_code).unwrap().unwrap();
        assert_eq!(found.pin_id, pin.pin_id);
        assert_eq!(found.join_code_generation, 2);
    }

    #[test]
    fn revoke_role_protects_owner_and_last_admin() {
        let (pool, pin) = setup();
        // Owner is protected even though they hold an explicit admin row.
        assert!(revoke_role(&pool, &pin.pin_id, "owner-acct").is_err());

        make_account(&pool, "second-admin");
        grant_role(&pool, &pin.pin_id, "second-admin", ROLE_ADMIN, "owner-acct").unwrap();
        revoke_role(&pool, &pin.pin_id, "second-admin").unwrap();
        assert_eq!(role_of(&pool, &pin.pin_id, "second-admin").unwrap(), None);
    }

    #[test]
    fn join_code_format_and_forgiving_lookup() {
        let (pool, pin) = setup();
        for _ in 0..50 {
            let code = generate_join_code();
            assert_eq!(code.len(), 12);
            let groups: Vec<&str> = code.split('-').collect();
            assert_eq!(groups.len(), 3);
            assert_eq!(
                (groups[0].len(), groups[1].len(), groups[2].len()),
                (4, 4, 2)
            );
            for c in code.chars().filter(|c| *c != '-') {
                assert!(
                    JOIN_CODE_ALPHABET.contains(&(c as u8)),
                    "bad char {c} in {code}"
                );
                assert!(!"ILO01".contains(c), "ambiguous char {c} in {code}");
            }
        }
        let sloppy = pin.join_code.replace('-', "").to_lowercase();
        assert_eq!(
            find_by_join_code(&pool, &sloppy).unwrap().unwrap().pin_id,
            pin.pin_id
        );
    }

    #[test]
    fn netmap_generation_bumps_on_membership_changes_only() {
        let (pool, pin) = setup();
        assert_eq!(netmap_generation(&pool, &pin.pin_id).unwrap(), 1);

        submit_join(&pool, &pin.pin_id, "dev-1", "ab", None).unwrap();
        assert_eq!(netmap_generation(&pool, &pin.pin_id).unwrap(), 1); // knock: no bump

        approve_member(&pool, &pin.pin_id, "dev-1", "owner-acct").unwrap();
        assert_eq!(netmap_generation(&pool, &pin.pin_id).unwrap(), 2);

        update_member(&pool, &pin.pin_id, "dev-1", Some("renamed"), None).unwrap();
        assert_eq!(netmap_generation(&pool, &pin.pin_id).unwrap(), 2); // rename: no bump

        update_member(&pool, &pin.pin_id, "dev-1", None, Some(false)).unwrap();
        assert_eq!(netmap_generation(&pool, &pin.pin_id).unwrap(), 3);
        update_member(&pool, &pin.pin_id, "dev-1", None, Some(false)).unwrap();
        assert_eq!(netmap_generation(&pool, &pin.pin_id).unwrap(), 3); // no-op change: no bump

        set_member_disabled(&pool, &pin.pin_id, "dev-1", true).unwrap();
        assert_eq!(netmap_generation(&pool, &pin.pin_id).unwrap(), 4);

        remove_member(&pool, &pin.pin_id, "dev-1", "owner-acct").unwrap();
        assert_eq!(netmap_generation(&pool, &pin.pin_id).unwrap(), 5);
    }

    #[test]
    fn removed_device_can_reknock_to_pending() {
        let (pool, pin) = setup();
        submit_join(&pool, &pin.pin_id, "dev-1", "ab", None).unwrap();
        approve_member(&pool, &pin.pin_id, "dev-1", "owner-acct").unwrap();
        remove_member(&pool, &pin.pin_id, "dev-1", "owner-acct").unwrap();
        assert!(members(&pool, &pin.pin_id).unwrap().is_empty()); // removed hidden

        submit_join(&pool, &pin.pin_id, "dev-1", "ab", None).unwrap();
        let m = &members(&pool, &pin.pin_id).unwrap()[0];
        assert_eq!(m.status, "pending");
        assert!(m.joined_at.is_none());
    }

    #[test]
    fn active_member_knock_is_noop() {
        let (pool, pin) = setup();
        submit_join(&pool, &pin.pin_id, "dev-1", "ab", None).unwrap();
        approve_member(&pool, &pin.pin_id, "dev-1", "owner-acct").unwrap();
        submit_join(&pool, &pin.pin_id, "dev-1", "ab", None).unwrap();
        assert_eq!(members(&pool, &pin.pin_id).unwrap()[0].status, "active");
    }

    #[test]
    fn delete_pin_hides_network() {
        let (pool, pin) = setup();
        delete_pin(&pool, &pin.pin_id).unwrap();
        assert!(find_by_join_code(&pool, &pin.join_code).unwrap().is_none());
        assert!(get_pin(&pool, &pin.pin_id).unwrap().is_none());
        assert!(pins_for_account(&pool, "owner-acct").unwrap().is_empty());
    }

    #[test]
    fn pins_for_account_reports_counts_and_role() {
        let (pool, pin) = setup();
        submit_join(&pool, &pin.pin_id, "dev-1", "ab", None).unwrap();
        submit_join(&pool, &pin.pin_id, "dev-2", "cd", None).unwrap();
        approve_member(&pool, &pin.pin_id, "dev-1", "owner-acct").unwrap();

        let summaries = pins_for_account(&pool, "owner-acct").unwrap();
        assert_eq!(summaries.len(), 1);
        let s = &summaries[0];
        assert_eq!(s.role, "admin");
        assert_eq!(s.active_count, 1);
        assert_eq!(s.pending_count, 1);

        let mine = pins_for_device(&pool, "dev-2").unwrap();
        assert_eq!(mine.len(), 1);
        assert_eq!(mine[0].status, "pending");
    }

    #[test]
    fn netmap_includes_active_and_disabled_only_and_signs() {
        let (pool, pin) = setup();
        for (dev, key) in [("dev-a", "aa"), ("dev-b", "bb"), ("dev-c", "cc")] {
            submit_join(&pool, &pin.pin_id, dev, key.repeat(32).as_str(), None).unwrap();
        }
        approve_member(&pool, &pin.pin_id, "dev-a", "owner-acct").unwrap();
        approve_member(&pool, &pin.pin_id, "dev-b", "owner-acct").unwrap();
        set_member_disabled(&pool, &pin.pin_id, "dev-b", true).unwrap();
        // dev-c stays pending and must not appear.
        update_member_endpoints(
            &pool,
            &pin.pin_id,
            "dev-a",
            r#"[{"kind":"lan","addr":"10.0.0.5:41641"}]"#,
            r#"["offline-model"]"#,
            "ee".repeat(32).as_str(),
        )
        .unwrap();
        update_member_endpoints(
            &pool,
            &pin.pin_id,
            "dev-b",
            r#"[{"kind":"lan","addr":"10.0.0.6:41641"}]"#,
            "[]",
            "ff".repeat(32).as_str(),
        )
        .unwrap();

        let live = |pubkey: &str| {
            (pubkey == "aa".repeat(32)).then(|| LiveMemberInfo {
                loaded_models: vec!["qwen3-4b".to_string()],
            })
        };
        let netmap = build_netmap(&pool, &pin.pin_id, live).unwrap();
        assert_eq!(
            netmap.generation,
            netmap_generation(&pool, &pin.pin_id).unwrap()
        );
        assert_eq!(netmap.members.len(), 2);

        let a = netmap
            .members
            .iter()
            .find(|m| m.device_id == "dev-a")
            .unwrap();
        assert!(!a.disabled);
        assert_eq!(a.endpoints.len(), 1);
        assert_eq!(a.loaded_models, vec!["qwen3-4b".to_string()]);

        let b = netmap
            .members
            .iter()
            .find(|m| m.device_id == "dev-b")
            .unwrap();
        assert!(b.disabled);
        assert!(b.endpoints.is_empty(), "disabled endpoints withheld");
        assert!(b.loaded_models.is_empty());

        // Sign and verify with the pinned gateway key.
        let dir = std::env::temp_dir().join(format!("pin-test-{}", uuid::Uuid::new_v4()));
        let identity =
            crate::identity::GatewayIdentity::load_or_create(dir.join("id.key").to_str().unwrap())
                .unwrap();
        let signed = sign_netmap(netmap, &identity).unwrap();
        assert!(signed.verify(&identity.public_key_hex()));
        let mut tampered = signed.clone();
        tampered.netmap.members[0].disabled = !tampered.netmap.members[0].disabled;
        assert!(!tampered.verify(&identity.public_key_hex()));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn settings_default_roundtrip() {
        let (_pool, pin) = setup();
        assert!(pin.settings.din_contribution_default);
        assert_eq!(pin.settings.priority_policy, "pin_first");
    }
}
