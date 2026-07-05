//! Private Inference Networks (PIN) control-plane storage.
//!
//! The gateway is coordination-only for PINs: membership, roles, join codes,
//! netmap generations, and usage COUNTS. PIN code paths must NEVER write to
//! the `ledger` or `balances` tables — PINs have token counting, not credits
//! (see spec §8).

#[cfg(test)]
mod tests {
    use crate::db::open_in_memory;

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
}
