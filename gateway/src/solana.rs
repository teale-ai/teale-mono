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
