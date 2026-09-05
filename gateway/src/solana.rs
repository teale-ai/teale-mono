//! Solana RPC helpers for verifying deposit-backed USDC funding.

use std::collections::BTreeMap;
use std::time::Duration;

use reqwest::Client;
use serde::Deserialize;
use serde_json::{json, Value};

use crate::config::SolanaConfig;

const MICRO_USDC_PER_CENT: i128 = 10_000;
const USDC_DECIMALS: u8 = 6;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedUsdcDeposit {
    pub tx_signature: String,
    pub source_address: Option<String>,
    pub amount_usdc_cents: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedUsdcWithdrawal {
    pub tx_signature: String,
    pub source_address: String,
    pub destination_address: String,
    pub gross_amount_usdc_cents: i64,
    pub destination_amount_micro_usdc: i64,
    pub treasury_amount_micro_usdc: i64,
}

#[derive(Debug, thiserror::Error)]
pub enum DepositVerificationError {
    #[error("txSignature is required")]
    MissingSignature,
    #[error("deposit txSignature was not found on Solana")]
    TransactionNotFound,
    #[error("deposit txSignature is not {required_status} yet")]
    TransactionNotSettled { required_status: String },
    #[error("deposit transaction failed on-chain")]
    TransactionFailed,
    #[error("deposit transaction did not credit the configured wallet with USDC")]
    NoMatchingDeposit,
    #[error("verified deposit amount {verified_amount_usdc_cents} does not match requested amount {requested_amount_usdc_cents}")]
    AmountMismatch {
        verified_amount_usdc_cents: i64,
        requested_amount_usdc_cents: i64,
    },
    #[error("verified deposit source {verified_source_address} does not match requested sourceAddress {requested_source_address}")]
    SourceMismatch {
        verified_source_address: String,
        requested_source_address: String,
    },
    #[error("deposit amount must be an exact number of USDC cents")]
    FractionalCents,
    #[error("configured USDC mint returned unexpected decimals {decimals}")]
    UnexpectedDecimals { decimals: u8 },
    #[error("solana rpc error: {0}")]
    Rpc(String),
}

#[derive(Debug, thiserror::Error)]
pub enum WithdrawalVerificationError {
    #[error("txSignature is required")]
    MissingSignature,
    #[error("withdrawal txSignature was not found on Solana")]
    TransactionNotFound,
    #[error("withdrawal txSignature is not {required_status} yet")]
    TransactionNotSettled { required_status: String },
    #[error("withdrawal transaction failed on-chain")]
    TransactionFailed,
    #[error("withdrawal transaction did not debit the configured source wallet in USDC")]
    NoMatchingWithdrawal,
    #[error("verified withdrawal source {verified_source_address} does not match the configured account wallet {expected_source_address}")]
    SourceMismatch {
        verified_source_address: String,
        expected_source_address: String,
    },
    #[error("verified withdrawal destination {verified_destination_address} does not match requested destinationAddress {requested_destination_address}")]
    DestinationMismatch {
        verified_destination_address: String,
        requested_destination_address: String,
    },
    #[error("verified withdrawal amount {verified_amount_usdc_cents} does not match requested amount {requested_amount_usdc_cents}")]
    AmountMismatch {
        verified_amount_usdc_cents: i64,
        requested_amount_usdc_cents: i64,
    },
    #[error("verified treasury fee {verified_fee_micro_usdc} micro-USDC does not match expected fee {expected_fee_micro_usdc}")]
    TreasuryFeeMismatch {
        verified_fee_micro_usdc: i64,
        expected_fee_micro_usdc: i64,
    },
    #[error("verified destination amount {verified_destination_micro_usdc} micro-USDC does not match expected net amount {expected_destination_micro_usdc}")]
    DestinationAmountMismatch {
        verified_destination_micro_usdc: i64,
        expected_destination_micro_usdc: i64,
    },
    #[error("configured USDC mint returned unexpected decimals {decimals}")]
    UnexpectedDecimals { decimals: u8 },
    #[error("solana rpc error: {0}")]
    Rpc(String),
}

pub async fn verify_usdc_deposit(
    config: &SolanaConfig,
    destination_owner: &str,
    tx_signature: &str,
    requested_amount_usdc_cents: Option<i64>,
    requested_source_address: Option<&str>,
) -> Result<VerifiedUsdcDeposit, DepositVerificationError> {
    let tx_signature = tx_signature.trim();
    if tx_signature.is_empty() {
        return Err(DepositVerificationError::MissingSignature);
    }

    let client = Client::builder()
        .timeout(Duration::from_secs(config.request_timeout_seconds))
        .build()
        .map_err(|err| DepositVerificationError::Rpc(err.to_string()))?;

    let status = fetch_signature_status(&client, config, tx_signature).await?;
    let Some(status) = status else {
        return Err(DepositVerificationError::TransactionNotFound);
    };
    if status.err.is_some() {
        return Err(DepositVerificationError::TransactionFailed);
    }
    if !commitment_satisfied(&config.commitment, status.confirmation_status.as_deref()) {
        return Err(DepositVerificationError::TransactionNotSettled {
            required_status: config.commitment.clone(),
        });
    }

    let tx = fetch_transaction(&client, config, tx_signature).await?;
    let Some(tx) = tx else {
        return Err(DepositVerificationError::TransactionNotFound);
    };

    let mut verified = extract_verified_deposit(
        &tx,
        destination_owner,
        &config.usdc_mint,
        requested_amount_usdc_cents,
        requested_source_address,
    )?;
    verified.tx_signature = tx_signature.to_string();
    Ok(verified)
}

pub async fn verify_usdc_withdrawal(
    config: &SolanaConfig,
    source_owner: &str,
    destination_owner: &str,
    amount_usdc_cents: i64,
    tx_signature: &str,
) -> Result<VerifiedUsdcWithdrawal, WithdrawalVerificationError> {
    let tx_signature = tx_signature.trim();
    if tx_signature.is_empty() {
        return Err(WithdrawalVerificationError::MissingSignature);
    }
    if amount_usdc_cents <= 0 {
        return Err(WithdrawalVerificationError::AmountMismatch {
            verified_amount_usdc_cents: 0,
            requested_amount_usdc_cents: amount_usdc_cents,
        });
    }

    let client = Client::builder()
        .timeout(Duration::from_secs(config.request_timeout_seconds))
        .build()
        .map_err(|err| WithdrawalVerificationError::Rpc(err.to_string()))?;

    let status = fetch_signature_status(&client, config, tx_signature)
        .await
        .map_err(map_deposit_error_to_withdrawal_error)?;
    let Some(status) = status else {
        return Err(WithdrawalVerificationError::TransactionNotFound);
    };
    if status.err.is_some() {
        return Err(WithdrawalVerificationError::TransactionFailed);
    }
    if !commitment_satisfied(&config.commitment, status.confirmation_status.as_deref()) {
        return Err(WithdrawalVerificationError::TransactionNotSettled {
            required_status: config.commitment.clone(),
        });
    }

    let tx = fetch_transaction(&client, config, tx_signature)
        .await
        .map_err(map_deposit_error_to_withdrawal_error)?;
    let Some(tx) = tx else {
        return Err(WithdrawalVerificationError::TransactionNotFound);
    };

    let mut verified = extract_verified_withdrawal(
        &tx,
        source_owner,
        destination_owner,
        amount_usdc_cents,
        &config.usdc_mint,
        config.treasury_address.as_str(),
        config.withdrawal_fee_bps,
    )?;
    verified.tx_signature = tx_signature.to_string();
    Ok(verified)
}

fn extract_verified_deposit(
    tx: &RpcTransaction,
    destination_owner: &str,
    usdc_mint: &str,
    requested_amount_usdc_cents: Option<i64>,
    requested_source_address: Option<&str>,
) -> Result<VerifiedUsdcDeposit, DepositVerificationError> {
    let meta = tx
        .meta
        .as_ref()
        .ok_or(DepositVerificationError::NoMatchingDeposit)?;
    if meta.err.is_some() {
        return Err(DepositVerificationError::TransactionFailed);
    }

    let deltas = aggregate_owner_deltas(
        meta.pre_token_balances.as_deref().unwrap_or(&[]),
        meta.post_token_balances.as_deref().unwrap_or(&[]),
        usdc_mint,
    )?;

    let credited_micro_usdc = *deltas.get(destination_owner).unwrap_or(&0);
    if credited_micro_usdc <= 0 {
        return Err(DepositVerificationError::NoMatchingDeposit);
    }
    if credited_micro_usdc % MICRO_USDC_PER_CENT != 0 {
        return Err(DepositVerificationError::FractionalCents);
    }

    let amount_usdc_cents: i64 = (credited_micro_usdc / MICRO_USDC_PER_CENT)
        .try_into()
        .map_err(|_| DepositVerificationError::Rpc("verified deposit overflowed i64".into()))?;

    if let Some(requested_amount_usdc_cents) = requested_amount_usdc_cents {
        if requested_amount_usdc_cents != amount_usdc_cents {
            return Err(DepositVerificationError::AmountMismatch {
                verified_amount_usdc_cents: amount_usdc_cents,
                requested_amount_usdc_cents,
            });
        }
    }

    let inferred_source = infer_source_owner(&deltas, destination_owner);
    if let (Some(requested), Some(verified)) = (
        normalize_optional_string(requested_source_address),
        inferred_source.as_deref(),
    ) {
        if requested != verified {
            return Err(DepositVerificationError::SourceMismatch {
                verified_source_address: verified.to_string(),
                requested_source_address: requested,
            });
        }
    }

    Ok(VerifiedUsdcDeposit {
        tx_signature: String::new(),
        source_address: inferred_source,
        amount_usdc_cents,
    })
}

fn extract_verified_withdrawal(
    tx: &RpcTransaction,
    source_owner: &str,
    destination_owner: &str,
    requested_amount_usdc_cents: i64,
    usdc_mint: &str,
    treasury_owner: &str,
    withdrawal_fee_bps: u16,
) -> Result<VerifiedUsdcWithdrawal, WithdrawalVerificationError> {
    let meta = tx
        .meta
        .as_ref()
        .ok_or(WithdrawalVerificationError::NoMatchingWithdrawal)?;
    if meta.err.is_some() {
        return Err(WithdrawalVerificationError::TransactionFailed);
    }

    let deltas = aggregate_owner_deltas(
        meta.pre_token_balances.as_deref().unwrap_or(&[]),
        meta.post_token_balances.as_deref().unwrap_or(&[]),
        usdc_mint,
    )
    .map_err(map_deposit_error_to_withdrawal_error)?;

    let source_delta = *deltas.get(source_owner).unwrap_or(&0);
    if source_delta >= 0 {
        return Err(WithdrawalVerificationError::NoMatchingWithdrawal);
    }

    let verified_source = infer_negative_owner(&deltas, destination_owner, treasury_owner)
        .ok_or(WithdrawalVerificationError::NoMatchingWithdrawal)?;
    if verified_source != source_owner {
        return Err(WithdrawalVerificationError::SourceMismatch {
            verified_source_address: verified_source,
            expected_source_address: source_owner.to_string(),
        });
    }

    let gross_micro_usdc = micro_usdc_from_cents(requested_amount_usdc_cents)
        .map_err(WithdrawalVerificationError::Rpc)?;
    if -source_delta != gross_micro_usdc {
        return Err(WithdrawalVerificationError::AmountMismatch {
            verified_amount_usdc_cents: micro_usdc_to_cents(-source_delta)
                .map_err(WithdrawalVerificationError::Rpc)?,
            requested_amount_usdc_cents,
        });
    }

    let expected_treasury_micro_usdc =
        withdrawal_fee_micro_usdc(gross_micro_usdc, withdrawal_fee_bps);
    let expected_destination_micro_usdc = gross_micro_usdc - expected_treasury_micro_usdc;

    let verified_destination_micro_usdc = *deltas.get(destination_owner).unwrap_or(&0);
    if verified_destination_micro_usdc <= 0 {
        let verified_destination_address =
            infer_positive_owner(&deltas, source_owner, treasury_owner).unwrap_or_default();
        return Err(WithdrawalVerificationError::DestinationMismatch {
            verified_destination_address,
            requested_destination_address: destination_owner.to_string(),
        });
    }
    if verified_destination_micro_usdc != expected_destination_micro_usdc {
        return Err(WithdrawalVerificationError::DestinationAmountMismatch {
            verified_destination_micro_usdc: verified_destination_micro_usdc.try_into().map_err(
                |_| {
                    WithdrawalVerificationError::Rpc(
                        "verified destination amount overflowed i64".into(),
                    )
                },
            )?,
            expected_destination_micro_usdc: expected_destination_micro_usdc.try_into().map_err(
                |_| {
                    WithdrawalVerificationError::Rpc(
                        "expected destination amount overflowed i64".into(),
                    )
                },
            )?,
        });
    }

    let verified_treasury_micro_usdc = *deltas.get(treasury_owner).unwrap_or(&0);
    if verified_treasury_micro_usdc != expected_treasury_micro_usdc {
        return Err(WithdrawalVerificationError::TreasuryFeeMismatch {
            verified_fee_micro_usdc: verified_treasury_micro_usdc.try_into().map_err(|_| {
                WithdrawalVerificationError::Rpc("verified treasury fee overflowed i64".into())
            })?,
            expected_fee_micro_usdc: expected_treasury_micro_usdc.try_into().map_err(|_| {
                WithdrawalVerificationError::Rpc("expected treasury fee overflowed i64".into())
            })?,
        });
    }

    Ok(VerifiedUsdcWithdrawal {
        tx_signature: String::new(),
        source_address: source_owner.to_string(),
        destination_address: destination_owner.to_string(),
        gross_amount_usdc_cents: requested_amount_usdc_cents,
        destination_amount_micro_usdc: verified_destination_micro_usdc.try_into().map_err(
            |_| {
                WithdrawalVerificationError::Rpc(
                    "verified destination amount overflowed i64".into(),
                )
            },
        )?,
        treasury_amount_micro_usdc: verified_treasury_micro_usdc.try_into().map_err(|_| {
            WithdrawalVerificationError::Rpc("verified treasury fee overflowed i64".into())
        })?,
    })
}

fn aggregate_owner_deltas(
    pre_balances: &[RpcTokenBalance],
    post_balances: &[RpcTokenBalance],
    usdc_mint: &str,
) -> Result<BTreeMap<String, i128>, DepositVerificationError> {
    let mut deltas = BTreeMap::<String, i128>::new();

    for balance in pre_balances {
        let Some(owner) = normalize_optional_string(balance.owner.as_deref()) else {
            continue;
        };
        if balance.mint != usdc_mint {
            continue;
        }
        let amount = parse_token_amount(balance)?;
        *deltas.entry(owner).or_default() -= amount;
    }

    for balance in post_balances {
        let Some(owner) = normalize_optional_string(balance.owner.as_deref()) else {
            continue;
        };
        if balance.mint != usdc_mint {
            continue;
        }
        let amount = parse_token_amount(balance)?;
        *deltas.entry(owner).or_default() += amount;
    }

    Ok(deltas)
}

fn parse_token_amount(balance: &RpcTokenBalance) -> Result<i128, DepositVerificationError> {
    if balance.ui_token_amount.decimals != USDC_DECIMALS {
        return Err(DepositVerificationError::UnexpectedDecimals {
            decimals: balance.ui_token_amount.decimals,
        });
    }
    balance
        .ui_token_amount
        .amount
        .parse::<i128>()
        .map_err(|err| DepositVerificationError::Rpc(format!("invalid token amount: {err}")))
}

fn infer_source_owner(deltas: &BTreeMap<String, i128>, destination_owner: &str) -> Option<String> {
    let mut candidates = deltas
        .iter()
        .filter(|(owner, delta)| owner.as_str() != destination_owner && **delta < 0)
        .map(|(owner, _)| owner.clone());
    let first = candidates.next()?;
    if candidates.next().is_some() {
        return None;
    }
    Some(first)
}

fn infer_negative_owner(
    deltas: &BTreeMap<String, i128>,
    destination_owner: &str,
    treasury_owner: &str,
) -> Option<String> {
    let mut candidates = deltas
        .iter()
        .filter(|(owner, delta)| {
            owner.as_str() != destination_owner && owner.as_str() != treasury_owner && **delta < 0
        })
        .map(|(owner, _)| owner.clone());
    let first = candidates.next()?;
    if candidates.next().is_some() {
        return None;
    }
    Some(first)
}

fn infer_positive_owner(
    deltas: &BTreeMap<String, i128>,
    source_owner: &str,
    treasury_owner: &str,
) -> Option<String> {
    let mut candidates = deltas
        .iter()
        .filter(|(owner, delta)| {
            owner.as_str() != source_owner && owner.as_str() != treasury_owner && **delta > 0
        })
        .map(|(owner, _)| owner.clone());
    let first = candidates.next()?;
    if candidates.next().is_some() {
        return None;
    }
    Some(first)
}

fn micro_usdc_from_cents(amount_usdc_cents: i64) -> Result<i128, String> {
    i128::from(amount_usdc_cents)
        .checked_mul(MICRO_USDC_PER_CENT)
        .ok_or_else(|| "usdc cents overflow while converting to micro-USDC".to_string())
}

fn micro_usdc_to_cents(amount_micro_usdc: i128) -> Result<i64, String> {
    if amount_micro_usdc % MICRO_USDC_PER_CENT != 0 {
        return Err("micro-USDC amount was not an exact number of cents".into());
    }
    (amount_micro_usdc / MICRO_USDC_PER_CENT)
        .try_into()
        .map_err(|_| "micro-USDC cents overflowed i64".to_string())
}

fn withdrawal_fee_micro_usdc(gross_micro_usdc: i128, fee_bps: u16) -> i128 {
    gross_micro_usdc * i128::from(fee_bps) / 10_000
}

fn map_deposit_error_to_withdrawal_error(
    err: DepositVerificationError,
) -> WithdrawalVerificationError {
    match err {
        DepositVerificationError::TransactionNotFound => {
            WithdrawalVerificationError::TransactionNotFound
        }
        DepositVerificationError::TransactionNotSettled { required_status } => {
            WithdrawalVerificationError::TransactionNotSettled { required_status }
        }
        DepositVerificationError::TransactionFailed => {
            WithdrawalVerificationError::TransactionFailed
        }
        DepositVerificationError::UnexpectedDecimals { decimals } => {
            WithdrawalVerificationError::UnexpectedDecimals { decimals }
        }
        DepositVerificationError::Rpc(message) => WithdrawalVerificationError::Rpc(message),
        DepositVerificationError::MissingSignature => WithdrawalVerificationError::MissingSignature,
        DepositVerificationError::NoMatchingDeposit => {
            WithdrawalVerificationError::NoMatchingWithdrawal
        }
        DepositVerificationError::AmountMismatch { .. }
        | DepositVerificationError::SourceMismatch { .. }
        | DepositVerificationError::FractionalCents => WithdrawalVerificationError::Rpc(
            "unexpected deposit verification error while verifying withdrawal".into(),
        ),
    }
}

fn normalize_optional_string(value: Option<&str>) -> Option<String> {
    value.and_then(|raw| {
        let trimmed = raw.trim();
        (!trimmed.is_empty()).then_some(trimmed.to_string())
    })
}

fn commitment_satisfied(required: &str, actual: Option<&str>) -> bool {
    match required {
        "processed" => matches!(actual, Some("processed" | "confirmed" | "finalized")),
        "confirmed" => matches!(actual, Some("confirmed" | "finalized")),
        _ => matches!(actual, Some("finalized")),
    }
}

async fn fetch_signature_status(
    client: &Client,
    config: &SolanaConfig,
    tx_signature: &str,
) -> Result<Option<RpcSignatureStatus>, DepositVerificationError> {
    let body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "getSignatureStatuses",
        "params": [
            [tx_signature],
            { "searchTransactionHistory": true }
        ],
    });
    let response: RpcEnvelope<RpcSignatureStatusesResult> =
        send_rpc_request(client, &config.rpc_url, body).await?;
    Ok(response
        .result
        .and_then(|result| result.value.into_iter().next())
        .flatten())
}

async fn fetch_transaction(
    client: &Client,
    config: &SolanaConfig,
    tx_signature: &str,
) -> Result<Option<RpcTransaction>, DepositVerificationError> {
    let body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "getTransaction",
        "params": [
            tx_signature,
            {
                "commitment": config.commitment,
                "maxSupportedTransactionVersion": config.max_supported_transaction_version,
                "encoding": "jsonParsed"
            }
        ],
    });
    let response: RpcEnvelope<RpcTransaction> =
        send_rpc_request(client, &config.rpc_url, body).await?;
    Ok(response.result)
}

async fn send_rpc_request<T>(
    client: &Client,
    rpc_url: &str,
    body: Value,
) -> Result<RpcEnvelope<T>, DepositVerificationError>
where
    T: for<'de> Deserialize<'de>,
{
    let response = client
        .post(rpc_url)
        .json(&body)
        .send()
        .await
        .map_err(|err| DepositVerificationError::Rpc(err.to_string()))?;
    let status = response.status();
    let payload = response
        .text()
        .await
        .map_err(|err| DepositVerificationError::Rpc(err.to_string()))?;
    if !status.is_success() {
        return Err(DepositVerificationError::Rpc(format!(
            "http {} from solana rpc: {}",
            status, payload
        )));
    }

    let envelope: RpcEnvelope<T> = serde_json::from_str(&payload)
        .map_err(|err| DepositVerificationError::Rpc(format!("invalid rpc response: {err}")))?;
    if let Some(error) = envelope.error.as_ref() {
        return Err(DepositVerificationError::Rpc(
            error
                .message
                .clone()
                .unwrap_or_else(|| "unknown rpc error".into()),
        ));
    }
    Ok(envelope)
}

#[derive(Debug, Deserialize)]
struct RpcEnvelope<T> {
    result: Option<T>,
    error: Option<RpcError>,
}

#[derive(Debug, Deserialize)]
struct RpcError {
    message: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RpcSignatureStatusesResult {
    value: Vec<Option<RpcSignatureStatus>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RpcSignatureStatus {
    err: Option<Value>,
    confirmation_status: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RpcTransaction {
    meta: Option<RpcTransactionMeta>,
    transaction: Option<RpcTransactionData>,
}

#[derive(Debug, Deserialize)]
struct RpcTransactionData {
    message: Option<RpcMessage>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RpcMessage {
    account_keys: Option<Vec<Value>>,
    instructions: Option<Vec<RpcInstruction>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RpcInstruction {
    program_id: Option<String>,
    /// Base58-encoded instruction data (jsonParsed encoding, non-parsed program).
    data: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RpcTransactionMeta {
    err: Option<Value>,
    pre_token_balances: Option<Vec<RpcTokenBalance>>,
    post_token_balances: Option<Vec<RpcTokenBalance>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RpcTokenBalance {
    mint: String,
    owner: Option<String>,
    ui_token_amount: RpcUiTokenAmount,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RpcUiTokenAmount {
    amount: String,
    decimals: u8,
}

// ---------------------------------------------------------------------------
// Ledger-anchor memo verification
//
// Anchoring is operator-signed: the gateway emits the exact memo string, the
// operator publishes it from the configured anchor authority wallet, and this
// function verifies the published transaction byte-for-byte. Same posture as
// USDC deposits — the gateway verifies, it never holds a key.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedTreasuryPayout {
    pub tx_signature: String,
    pub destination_address: String,
    pub gross_amount_usdc_cents: i64,
    pub destination_amount_micro_usdc: i64,
    pub treasury_retained_micro_usdc: i64,
}

#[derive(Debug, thiserror::Error)]
pub enum TreasuryPayoutError {
    #[error("txSignature is required")]
    MissingSignature,
    #[error("payout transaction was not found on Solana")]
    TransactionNotFound,
    #[error("payout transaction is not {required_status} yet")]
    TransactionNotSettled { required_status: String },
    #[error("payout transaction failed on-chain")]
    TransactionFailed,
    #[error("payout did not debit the treasury exactly the expected net amount")]
    TreasuryDebitMismatch,
    #[error("payout did not credit the requested destination exactly the expected net amount")]
    DestinationMismatch,
    #[error("payout credited unexpected additional USDC owners")]
    UnexpectedRecipients,
    #[error(transparent)]
    Deposit(#[from] DepositVerificationError),
    #[error("solana rpc error: {0}")]
    Rpc(String),
}

/// Verify a treasury-paid withdrawal: a settled, successful transaction that
/// moves exactly `gross - fee` USDC from the treasury to the destination.
/// The 1.8% fee is retained by simply never leaving the treasury.
pub async fn verify_treasury_payout(
    config: &SolanaConfig,
    tx_signature: &str,
    expected_destination: &str,
    gross_amount_usdc_cents: i64,
) -> Result<VerifiedTreasuryPayout, TreasuryPayoutError> {
    let tx_signature = tx_signature.trim();
    if tx_signature.is_empty() {
        return Err(TreasuryPayoutError::MissingSignature);
    }

    let client = Client::builder()
        .timeout(Duration::from_secs(config.request_timeout_seconds))
        .build()
        .map_err(|err| TreasuryPayoutError::Rpc(err.to_string()))?;

    let status = fetch_signature_status(&client, config, tx_signature).await?;
    let Some(status) = status else {
        return Err(TreasuryPayoutError::TransactionNotFound);
    };
    if status.err.is_some() {
        return Err(TreasuryPayoutError::TransactionFailed);
    }
    if !commitment_satisfied(&config.commitment, status.confirmation_status.as_deref()) {
        return Err(TreasuryPayoutError::TransactionNotSettled {
            required_status: config.commitment.clone(),
        });
    }

    let tx = fetch_transaction(&client, config, tx_signature).await?;
    let Some(tx) = tx else {
        return Err(TreasuryPayoutError::TransactionNotFound);
    };
    let meta = tx
        .meta
        .as_ref()
        .ok_or(TreasuryPayoutError::DestinationMismatch)?;
    if meta.err.is_some() {
        return Err(TreasuryPayoutError::TransactionFailed);
    }

    let deltas = aggregate_owner_deltas(
        meta.pre_token_balances.as_deref().unwrap_or(&[]),
        meta.post_token_balances.as_deref().unwrap_or(&[]),
        &config.usdc_mint,
    )?;

    let gross_micro_usdc = i128::from(gross_amount_usdc_cents) * MICRO_USDC_PER_CENT;
    let fee_micro_usdc = withdrawal_fee_micro_usdc(gross_micro_usdc, config.withdrawal_fee_bps);
    let net_micro_usdc = gross_micro_usdc - fee_micro_usdc;

    let treasury_delta = *deltas.get(config.treasury_address.as_str()).unwrap_or(&0);
    if treasury_delta != -net_micro_usdc {
        return Err(TreasuryPayoutError::TreasuryDebitMismatch);
    }
    let destination_delta = *deltas.get(expected_destination).unwrap_or(&0);
    if destination_delta != net_micro_usdc {
        return Err(TreasuryPayoutError::DestinationMismatch);
    }
    if deltas
        .iter()
        .any(|(owner, delta)| *delta > 0 && owner != expected_destination)
    {
        return Err(TreasuryPayoutError::UnexpectedRecipients);
    }

    Ok(VerifiedTreasuryPayout {
        tx_signature: tx_signature.to_string(),
        destination_address: expected_destination.to_string(),
        gross_amount_usdc_cents,
        destination_amount_micro_usdc: net_micro_usdc
            .try_into()
            .map_err(|_| TreasuryPayoutError::Rpc("verified payout overflowed i64".into()))?,
        treasury_retained_micro_usdc: fee_micro_usdc
            .try_into()
            .map_err(|_| TreasuryPayoutError::Rpc("verified fee overflowed i64".into()))?,
    })
}

pub struct VerifiedTreasuryDeposit {
    pub tx_signature: String,
    pub amount_usdc_cents: i64,
    pub source_address: Option<String>,
    pub memo: String,
    pub fee_payer: String,
}

#[derive(Debug, thiserror::Error)]
pub enum TreasuryDepositError {
    #[error("txSignature is required")]
    MissingSignature,
    #[error("deposit transaction was not found on Solana")]
    TransactionNotFound,
    #[error("deposit transaction is not {required_status} yet")]
    TransactionNotSettled { required_status: String },
    #[error("deposit transaction failed on-chain")]
    TransactionFailed,
    #[error("deposit transaction carries no memo instruction - include the deposit memo shown in the app")]
    NoMemoInstruction,
    #[error("on-chain memo does not match this account's deposit memo")]
    MemoMismatch,
    #[error(transparent)]
    Deposit(#[from] DepositVerificationError),
    #[error("solana rpc error: {0}")]
    Rpc(String),
}

/// Verify a custodial deposit: a settled, successful transaction that (a)
/// credits the configured TREASURY with a whole-cent USDC amount and (b)
/// carries a Memo-program instruction exactly equal to `expected_memo`
/// (`teale:deposit:<account_user_id>`). Unlike `verify_memo_anchor` the fee
/// payer is arbitrary - anyone may fund an account, the memo binds it.
pub async fn verify_treasury_deposit(
    config: &SolanaConfig,
    tx_signature: &str,
    expected_memo: &str,
) -> Result<VerifiedTreasuryDeposit, TreasuryDepositError> {
    let tx_signature = tx_signature.trim();
    if tx_signature.is_empty() {
        return Err(TreasuryDepositError::MissingSignature);
    }

    let client = Client::builder()
        .timeout(Duration::from_secs(config.request_timeout_seconds))
        .build()
        .map_err(|err| TreasuryDepositError::Rpc(err.to_string()))?;

    let status = fetch_signature_status(&client, config, tx_signature).await?;
    let Some(status) = status else {
        return Err(TreasuryDepositError::TransactionNotFound);
    };
    if status.err.is_some() {
        return Err(TreasuryDepositError::TransactionFailed);
    }
    if !commitment_satisfied(&config.commitment, status.confirmation_status.as_deref()) {
        return Err(TreasuryDepositError::TransactionNotSettled {
            required_status: config.commitment.clone(),
        });
    }

    let tx = fetch_transaction(&client, config, tx_signature).await?;
    let Some(tx) = tx else {
        return Err(TreasuryDepositError::TransactionNotFound);
    };

    let message = tx
        .transaction
        .as_ref()
        .and_then(|t| t.message.as_ref())
        .ok_or(TreasuryDepositError::Rpc(
            "transaction payload missing message".into(),
        ))?;
    let fee_payer = message
        .account_keys
        .as_ref()
        .and_then(|keys| keys.first())
        .and_then(|k| {
            k.as_str()
                .map(|s| s.to_string())
                .or_else(|| k.get("pubkey")?.as_str().map(|s| s.to_string()))
        })
        .ok_or(TreasuryDepositError::Rpc(
            "transaction message has no account keys".into(),
        ))?;

    let memos: Vec<String> = message
        .instructions
        .as_deref()
        .unwrap_or(&[])
        .iter()
        .filter(|ix| ix.program_id.as_deref() == Some(crate::anchoring::MEMO_PROGRAM_ID))
        .filter_map(|ix| ix.data.as_ref())
        .filter_map(|data| base58_decode(data).ok())
        .filter_map(|bytes| String::from_utf8(bytes).ok())
        .collect();
    if memos.is_empty() {
        return Err(TreasuryDepositError::NoMemoInstruction);
    }
    if !memos.iter().any(|m| m == expected_memo) {
        return Err(TreasuryDepositError::MemoMismatch);
    }

    let verified = extract_verified_deposit(
        &tx,
        config.treasury_address.as_str(),
        &config.usdc_mint,
        None,
        None,
    )?;

    Ok(VerifiedTreasuryDeposit {
        tx_signature: tx_signature.to_string(),
        amount_usdc_cents: verified.amount_usdc_cents,
        source_address: verified.source_address,
        memo: expected_memo.to_string(),
        fee_payer,
    })
}

pub struct VerifiedMemoAnchor {
    pub tx_signature: String,
    pub memo: String,
    pub fee_payer: String,
}

#[derive(Debug, thiserror::Error)]
pub enum MemoAnchorError {
    #[error("txSignature is required")]
    MissingSignature,
    #[error("anchor transaction was not found on Solana")]
    TransactionNotFound,
    #[error("anchor transaction is not {required_status} yet")]
    TransactionNotSettled { required_status: String },
    #[error("anchor transaction failed on-chain")]
    TransactionFailed,
    #[error("anchor transaction carries no memo instruction")]
    NoMemoInstruction,
    #[error("on-chain memo does not match the pending anchor memo")]
    MemoMismatch,
    #[error(
        "anchor transaction fee payer {actual} is not the configured anchor authority {expected}"
    )]
    WrongAuthority { actual: String, expected: String },
    #[error("solana rpc error: {0}")]
    Rpc(String),
}

/// Verify that `tx_signature` is a settled, successful transaction whose fee
/// payer is `authority_address` and whose Memo-program instruction data is
/// exactly `expected_memo` (UTF-8). Any deviation — wrong wallet, wrong memo,
/// extra whitespace — rejects the anchor.
pub async fn verify_memo_anchor(
    config: &SolanaConfig,
    tx_signature: &str,
    expected_memo: &str,
    authority_address: &str,
) -> Result<VerifiedMemoAnchor, MemoAnchorError> {
    let tx_signature = tx_signature.trim();
    if tx_signature.is_empty() {
        return Err(MemoAnchorError::MissingSignature);
    }

    let client = Client::builder()
        .timeout(Duration::from_secs(config.request_timeout_seconds))
        .build()
        .map_err(|err| MemoAnchorError::Rpc(err.to_string()))?;

    let status = fetch_signature_status(&client, config, tx_signature)
        .await
        .map_err(|err| MemoAnchorError::Rpc(err.to_string()))?;
    let Some(status) = status else {
        return Err(MemoAnchorError::TransactionNotFound);
    };
    if status.err.is_some() {
        return Err(MemoAnchorError::TransactionFailed);
    }
    if !commitment_satisfied(&config.commitment, status.confirmation_status.as_deref()) {
        return Err(MemoAnchorError::TransactionNotSettled {
            required_status: config.commitment.clone(),
        });
    }

    let tx = fetch_transaction(&client, config, tx_signature)
        .await
        .map_err(|err| MemoAnchorError::Rpc(err.to_string()))?;
    let Some(tx) = tx else {
        return Err(MemoAnchorError::TransactionNotFound);
    };
    let message = tx
        .transaction
        .and_then(|t| t.message)
        .ok_or(MemoAnchorError::Rpc(
            "transaction payload missing message".into(),
        ))?;

    // Fee payer is always accountKeys[0]; jsonParsed encodes keys either as
    // plain address strings or { pubkey, signer, ... } objects.
    let fee_payer = message
        .account_keys
        .as_ref()
        .and_then(|keys| keys.first())
        .and_then(|k| {
            k.as_str()
                .map(|s| s.to_string())
                .or_else(|| k.get("pubkey")?.as_str().map(|s| s.to_string()))
        })
        .ok_or(MemoAnchorError::Rpc(
            "transaction message has no account keys".into(),
        ))?;
    if fee_payer != authority_address {
        return Err(MemoAnchorError::WrongAuthority {
            actual: fee_payer,
            expected: authority_address.to_string(),
        });
    }

    let memos: Vec<String> = message
        .instructions
        .unwrap_or_default()
        .iter()
        .filter(|ix| ix.program_id.as_deref() == Some(crate::anchoring::MEMO_PROGRAM_ID))
        .filter_map(|ix| ix.data.as_ref())
        .filter_map(|data| base58_decode(data).ok())
        .filter_map(|bytes| String::from_utf8(bytes).ok())
        .collect();
    if memos.is_empty() {
        return Err(MemoAnchorError::NoMemoInstruction);
    }
    if !memos.iter().any(|m| m == expected_memo) {
        return Err(MemoAnchorError::MemoMismatch);
    }

    Ok(VerifiedMemoAnchor {
        tx_signature: tx_signature.to_string(),
        memo: expected_memo.to_string(),
        fee_payer,
    })
}

/// Minimal base58 (Bitcoin alphabet) decoder for Solana instruction data.
/// Solana's jsonParsed encoding carries non-parsed instruction data as
/// base58 strings; there is no bs58 crate in the dependency tree today, and
/// memo payloads are ~150 bytes, so a small exact implementation beats a new
/// dependency.
pub fn base58_decode(s: &str) -> Result<Vec<u8>, MemoAnchorError> {
    const ALPHABET: &[u8; 58] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    let mut bytes: Vec<u8> = Vec::with_capacity(s.len());
    for ch in s.bytes() {
        let digit = match ALPHABET.iter().position(|&c| c == ch) {
            Some(pos) => pos as u32,
            None => {
                return Err(MemoAnchorError::Rpc(format!(
                    "invalid base58 character: {}",
                    ch as char
                )))
            }
        };
        let mut carry = digit;
        for byte in bytes.iter_mut().rev() {
            carry += (*byte as u32) * 58;
            *byte = (carry & 0xff) as u8;
            carry >>= 8;
        }
        while carry > 0 {
            bytes.insert(0, (carry & 0xff) as u8);
            carry >>= 8;
        }
    }
    // Leading '1's encode leading zero bytes.
    let leading_zeros = s.bytes().take_while(|&b| b == b'1').count();
    let mut out = vec![0u8; leading_zeros];
    out.extend_from_slice(&bytes);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_tx(json: &str) -> RpcTransaction {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn extracts_verified_deposit_from_new_associated_token_account() {
        let tx = sample_tx(
            r#"{
                "meta": {
                    "err": null,
                    "preTokenBalances": [
                        {
                            "mint": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
                            "owner": "source-wallet",
                            "uiTokenAmount": { "amount": "10000000", "decimals": 6 }
                        }
                    ],
                    "postTokenBalances": [
                        {
                            "mint": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
                            "owner": "dest-wallet",
                            "uiTokenAmount": { "amount": "1250000", "decimals": 6 }
                        },
                        {
                            "mint": "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
                            "owner": "source-wallet",
                            "uiTokenAmount": { "amount": "8750000", "decimals": 6 }
                        }
                    ]
                }
            }"#,
        );

        let verified = extract_verified_deposit(
            &tx,
            "dest-wallet",
            "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
            Some(125),
            Some("source-wallet"),
        )
        .unwrap();

        assert_eq!(verified.amount_usdc_cents, 125);
        assert_eq!(verified.source_address.as_deref(), Some("source-wallet"));
    }

    #[test]
    fn rejects_amount_mismatch() {
        let tx = sample_tx(
            r#"{
                "meta": {
                    "err": null,
                    "preTokenBalances": [
                        {
                            "mint": "mint",
                            "owner": "dest-wallet",
                            "uiTokenAmount": { "amount": "10000", "decimals": 6 }
                        }
                    ],
                    "postTokenBalances": [
                        {
                            "mint": "mint",
                            "owner": "dest-wallet",
                            "uiTokenAmount": { "amount": "30000", "decimals": 6 }
                        }
                    ]
                }
            }"#,
        );

        let err = extract_verified_deposit(&tx, "dest-wallet", "mint", Some(3), None).unwrap_err();
        assert!(matches!(
            err,
            DepositVerificationError::AmountMismatch {
                verified_amount_usdc_cents: 2,
                requested_amount_usdc_cents: 3,
            }
        ));
    }

    #[test]
    fn rejects_fractional_cent_deposits() {
        let tx = sample_tx(
            r#"{
                "meta": {
                    "err": null,
                    "preTokenBalances": [],
                    "postTokenBalances": [
                        {
                            "mint": "mint",
                            "owner": "dest-wallet",
                            "uiTokenAmount": { "amount": "15001", "decimals": 6 }
                        }
                    ]
                }
            }"#,
        );

        let err = extract_verified_deposit(&tx, "dest-wallet", "mint", None, None).unwrap_err();
        assert!(matches!(err, DepositVerificationError::FractionalCents));
    }

    #[test]
    fn source_is_only_accepted_when_it_matches_unique_negative_owner() {
        let tx = sample_tx(
            r#"{
                "meta": {
                    "err": null,
                    "preTokenBalances": [
                        {
                            "mint": "mint",
                            "owner": "source-wallet",
                            "uiTokenAmount": { "amount": "250000", "decimals": 6 }
                        },
                        {
                            "mint": "mint",
                            "owner": "dest-wallet",
                            "uiTokenAmount": { "amount": "0", "decimals": 6 }
                        }
                    ],
                    "postTokenBalances": [
                        {
                            "mint": "mint",
                            "owner": "source-wallet",
                            "uiTokenAmount": { "amount": "50000", "decimals": 6 }
                        },
                        {
                            "mint": "mint",
                            "owner": "dest-wallet",
                            "uiTokenAmount": { "amount": "200000", "decimals": 6 }
                        }
                    ]
                }
            }"#,
        );

        let err = extract_verified_deposit(
            &tx,
            "dest-wallet",
            "mint",
            Some(20),
            Some("different-source"),
        )
        .unwrap_err();
        assert!(matches!(
            err,
            DepositVerificationError::SourceMismatch { .. }
        ));
    }

    #[test]
    fn extracts_verified_withdrawal_with_destination_and_treasury_split() {
        let tx = sample_tx(
            r#"{
                "meta": {
                    "err": null,
                    "preTokenBalances": [
                        {
                            "mint": "mint",
                            "owner": "source-wallet",
                            "uiTokenAmount": { "amount": "1000000", "decimals": 6 }
                        }
                    ],
                    "postTokenBalances": [
                        {
                            "mint": "mint",
                            "owner": "source-wallet",
                            "uiTokenAmount": { "amount": "0", "decimals": 6 }
                        },
                        {
                            "mint": "mint",
                            "owner": "dest-wallet",
                            "uiTokenAmount": { "amount": "982000", "decimals": 6 }
                        },
                        {
                            "mint": "mint",
                            "owner": "treasury-wallet",
                            "uiTokenAmount": { "amount": "18000", "decimals": 6 }
                        }
                    ]
                }
            }"#,
        );

        let verified = extract_verified_withdrawal(
            &tx,
            "source-wallet",
            "dest-wallet",
            100,
            "mint",
            "treasury-wallet",
            180,
        )
        .unwrap();

        assert_eq!(verified.gross_amount_usdc_cents, 100);
        assert_eq!(verified.destination_amount_micro_usdc, 982_000);
        assert_eq!(verified.treasury_amount_micro_usdc, 18_000);
    }

    #[test]
    fn rejects_withdrawal_when_treasury_fee_does_not_match_policy() {
        let tx = sample_tx(
            r#"{
                "meta": {
                    "err": null,
                    "preTokenBalances": [
                        {
                            "mint": "mint",
                            "owner": "source-wallet",
                            "uiTokenAmount": { "amount": "1000000", "decimals": 6 }
                        }
                    ],
                    "postTokenBalances": [
                        {
                            "mint": "mint",
                            "owner": "source-wallet",
                            "uiTokenAmount": { "amount": "0", "decimals": 6 }
                        },
                        {
                            "mint": "mint",
                            "owner": "dest-wallet",
                            "uiTokenAmount": { "amount": "990000", "decimals": 6 }
                        },
                        {
                            "mint": "mint",
                            "owner": "treasury-wallet",
                            "uiTokenAmount": { "amount": "10000", "decimals": 6 }
                        }
                    ]
                }
            }"#,
        );

        let err = extract_verified_withdrawal(
            &tx,
            "source-wallet",
            "dest-wallet",
            100,
            "mint",
            "treasury-wallet",
            180,
        )
        .unwrap_err();

        assert!(matches!(
            err,
            WithdrawalVerificationError::DestinationAmountMismatch { .. }
                | WithdrawalVerificationError::TreasuryFeeMismatch { .. }
        ));
    }

    #[test]
    fn rejects_withdrawal_when_destination_is_not_requested_wallet() {
        let tx = sample_tx(
            r#"{
                "meta": {
                    "err": null,
                    "preTokenBalances": [
                        {
                            "mint": "mint",
                            "owner": "source-wallet",
                            "uiTokenAmount": { "amount": "500000", "decimals": 6 }
                        }
                    ],
                    "postTokenBalances": [
                        {
                            "mint": "mint",
                            "owner": "source-wallet",
                            "uiTokenAmount": { "amount": "0", "decimals": 6 }
                        },
                        {
                            "mint": "mint",
                            "owner": "wrong-dest-wallet",
                            "uiTokenAmount": { "amount": "491000", "decimals": 6 }
                        },
                        {
                            "mint": "mint",
                            "owner": "treasury-wallet",
                            "uiTokenAmount": { "amount": "9000", "decimals": 6 }
                        }
                    ]
                }
            }"#,
        );

        let err = extract_verified_withdrawal(
            &tx,
            "source-wallet",
            "dest-wallet",
            50,
            "mint",
            "treasury-wallet",
            180,
        )
        .unwrap_err();

        assert!(matches!(
            err,
            WithdrawalVerificationError::DestinationMismatch {
                verified_destination_address,
                requested_destination_address
            } if verified_destination_address == "wrong-dest-wallet"
                && requested_destination_address == "dest-wallet"
        ));
    }
}

#[cfg(test)]
mod anchor_tests {
    use super::*;

    #[test]
    fn base58_decodes_known_vectors() {
        assert_eq!(base58_decode("").unwrap(), Vec::<u8>::new());
        assert_eq!(base58_decode("1").unwrap(), vec![0u8]);
        assert_eq!(base58_decode("11").unwrap(), vec![0u8, 0u8]);
        assert_eq!(base58_decode("2").unwrap(), vec![1u8]);
        assert_eq!(base58_decode("2g").unwrap(), vec![97u8]);
        // The memo program id is a real 32-byte program address.
        assert_eq!(
            base58_decode(crate::anchoring::MEMO_PROGRAM_ID)
                .unwrap()
                .len(),
            32
        );
    }

    #[test]
    fn memo_instruction_extracted_from_jsonparsed_tx() {
        let memo = "TEALE:ANCHOR:V1:1:2:2:aaaa:bbbb";
        // base58 of the memo bytes, computed by hand for the test:
        // we trust round-trip here (encode is trivial), the point is the
        // jsonParsed walking logic.
        let data = base58_encode_for_test(memo.as_bytes());
        let tx = sample_anchor_tx(&data);
        let message = tx.transaction.unwrap().message.unwrap();
        let memos: Vec<String> = message
            .instructions
            .unwrap()
            .iter()
            .filter(|ix| ix.program_id.as_deref() == Some(crate::anchoring::MEMO_PROGRAM_ID))
            .filter_map(|ix| ix.data.as_ref())
            .filter_map(|d| base58_decode(d).ok())
            .filter_map(|b| String::from_utf8(b).ok())
            .collect();
        assert_eq!(memos, vec![memo.to_string()]);
    }

    fn base58_encode_for_test(bytes: &[u8]) -> String {
        const ALPHABET: &[u8; 58] = b"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        let mut digits: Vec<u8> = vec![0];
        for &byte in bytes {
            let mut carry = byte as u32;
            for d in digits.iter_mut().rev() {
                carry += (*d as u32) * 256;
                *d = (carry % 58) as u8;
                carry /= 58;
            }
            while carry > 0 {
                digits.insert(0, (carry % 58) as u8);
                carry /= 58;
            }
        }
        let zeros = bytes.iter().take_while(|&&b| b == 0).count();
        let mut out: String = "1".repeat(zeros);
        let start = digits.iter().position(|&d| d != 0).unwrap_or(digits.len());
        for &d in &digits[start..] {
            out.push(ALPHABET[d as usize] as char);
        }
        out
    }

    fn sample_anchor_tx(data: &str) -> RpcTransaction {
        serde_json::from_str(&format!(
            r#"{{"transaction": {{"message": {{
                "accountKeys": [{{"pubkey": "anchor-authority", "signer": true}}],
                "instructions": [
                    {{"programId": "11111111111111111111111111111111", "data": "3yZe7d"}},
                    {{"programId": "{memo_prog}", "data": "{data}"}}
                ]
            }} }}, "meta": {{"err": null}} }}"#,
            memo_prog = crate::anchoring::MEMO_PROGRAM_ID,
            data = data,
        ))
        .unwrap()
    }
}
