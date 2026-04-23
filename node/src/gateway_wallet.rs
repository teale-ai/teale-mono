use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use base64::Engine;
use reqwest::Url;
use serde::Deserialize;
use tokio::sync::Mutex;
use tracing::{debug, warn};

use crate::identity::NodeIdentity;
use crate::status_server::{GatewayWalletState, StatusState, WalletTransactionSnapshot};

const WALLET_SYNC_INTERVAL: Duration = Duration::from_secs(10);

#[derive(Debug, Clone)]
struct DeviceToken {
    value: String,
    expires_at: i64,
}

#[derive(Debug, Deserialize)]
struct ChallengeResponse {
    nonce: String,
    #[serde(rename = "expiresAt")]
    expires_at: i64,
}

#[derive(Debug, Deserialize)]
struct ExchangeResponse {
    token: String,
    #[serde(rename = "expiresAt")]
    expires_at: i64,
}

#[derive(Debug, Deserialize)]
struct BalanceResponse {
    balance_credits: i64,
    total_earned_credits: i64,
    total_spent_credits: i64,
    usdc_cents: i64,
}

#[derive(Debug, Deserialize)]
struct TransactionsResponse {
    transactions: Vec<WalletTransactionSnapshot>,
}

pub fn spawn(
    status: Arc<StatusState>,
    identity: Arc<NodeIdentity>,
    relay_url: String,
) -> anyhow::Result<()> {
    let gateway_url = derive_gateway_url(&relay_url)?;
    let token = Arc::new(Mutex::new(None::<DeviceToken>));

    tokio::spawn(async move {
        let client = match wallet_client() {
            Ok(client) => client,
            Err(err) => {
                warn!("gateway wallet client init failed: {err:#}");
                status
                    .set_gateway_wallet_error(format!("wallet client init failed: {err:#}"))
                    .await;
                return;
            }
        };

        loop {
            if let Err(err) =
                sync_wallet_once(&client, &gateway_url, &identity, &status, &token).await
            {
                warn!("gateway wallet sync failed: {err:#}");
                status
                    .set_gateway_wallet_error(format!("wallet sync failed: {err:#}"))
                    .await;
            }
            tokio::time::sleep(WALLET_SYNC_INTERVAL).await;
        }
    });

    Ok(())
}

fn wallet_client() -> anyhow::Result<reqwest::Client> {
    let builder = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(20))
        .user_agent(format!("teale-node/{}", env!("CARGO_PKG_VERSION")));
    #[cfg(windows)]
    let builder = builder.use_native_tls();
    #[cfg(not(windows))]
    let builder = builder.use_rustls_tls();
    Ok(builder.build()?)
}

async fn sync_wallet_once(
    client: &reqwest::Client,
    gateway_url: &str,
    identity: &NodeIdentity,
    status: &StatusState,
    token_state: &Mutex<Option<DeviceToken>>,
) -> anyhow::Result<()> {
    let token = ensure_device_token(client, gateway_url, identity, token_state).await?;
    let balance = match fetch_balance(client, gateway_url, &token.value).await {
        Ok(balance) => balance,
        Err(err) if err.to_string().contains("device token rejected") => {
            *token_state.lock().await = None;
            let token = ensure_device_token(client, gateway_url, identity, token_state).await?;
            fetch_balance(client, gateway_url, &token.value).await?
        }
        Err(err) => return Err(err),
    };
    let transactions = fetch_transactions(client, gateway_url, &token.value)
        .await
        .unwrap_or_default();

    status
        .set_gateway_wallet(
            GatewayWalletState {
                device_id: identity.node_id(),
                balance_credits: balance.balance_credits,
                total_earned_credits: balance.total_earned_credits,
                total_spent_credits: balance.total_spent_credits,
                usdc_cents: balance.usdc_cents,
                synced_at: now_unix_secs(),
            },
            Some(token.value.clone()),
            transactions,
        )
        .await;
    debug!(
        balance = balance.balance_credits,
        earned = balance.total_earned_credits,
        "gateway wallet synced"
    );
    Ok(())
}

async fn ensure_device_token(
    client: &reqwest::Client,
    gateway_url: &str,
    identity: &NodeIdentity,
    token_state: &Mutex<Option<DeviceToken>>,
) -> anyhow::Result<DeviceToken> {
    {
        let guard = token_state.lock().await;
        if let Some(token) = guard.as_ref() {
            if token.expires_at > now_unix_secs_i64() + 300 {
                return Ok(token.clone());
            }
        }
    }

    let challenge_url = format!("{gateway_url}/v1/auth/device/challenge");
    let challenge = client
        .post(&challenge_url)
        .json(&serde_json::json!({ "deviceID": identity.node_id() }))
        .send()
        .await
        .with_context(|| format!("POST {challenge_url}"))?
        .error_for_status()
        .with_context(|| format!("device challenge failed at {challenge_url}"))?
        .json::<ChallengeResponse>()
        .await
        .context("decode device challenge response")?;

    if challenge.expires_at <= now_unix_secs_i64() {
        anyhow::bail!("device challenge expired immediately");
    }

    let nonce_bytes = base64::engine::general_purpose::STANDARD
        .decode(&challenge.nonce)
        .context("decode challenge nonce")?;
    let signature = identity.sign_hex(&nonce_bytes);

    let exchange_url = format!("{gateway_url}/v1/auth/device/exchange");
    let exchange = client
        .post(&exchange_url)
        .json(&serde_json::json!({
            "deviceID": identity.node_id(),
            "nonce": challenge.nonce,
            "signature": signature,
        }))
        .send()
        .await
        .with_context(|| format!("POST {exchange_url}"))?
        .error_for_status()
        .with_context(|| format!("device exchange failed at {exchange_url}"))?
        .json::<ExchangeResponse>()
        .await
        .context("decode device exchange response")?;

    let token = DeviceToken {
        value: exchange.token,
        expires_at: exchange.expires_at,
    };
    *token_state.lock().await = Some(token.clone());
    Ok(token)
}

async fn fetch_balance(
    client: &reqwest::Client,
    gateway_url: &str,
    token: &str,
) -> anyhow::Result<BalanceResponse> {
    let balance_url = format!("{gateway_url}/v1/wallet/balance");
    let response = client
        .get(&balance_url)
        .bearer_auth(token)
        .send()
        .await
        .with_context(|| format!("GET {balance_url}"))?;

    if response.status() == reqwest::StatusCode::UNAUTHORIZED {
        anyhow::bail!("device token rejected by gateway wallet");
    }

    response
        .error_for_status()
        .with_context(|| format!("wallet balance request failed at {balance_url}"))?
        .json::<BalanceResponse>()
        .await
        .context("decode wallet balance response")
}

async fn fetch_transactions(
    client: &reqwest::Client,
    gateway_url: &str,
    token: &str,
) -> anyhow::Result<Vec<WalletTransactionSnapshot>> {
    let tx_url = format!("{gateway_url}/v1/wallet/transactions?limit=25");
    let response = client
        .get(&tx_url)
        .bearer_auth(token)
        .send()
        .await
        .with_context(|| format!("GET {tx_url}"))?;

    if response.status() == reqwest::StatusCode::UNAUTHORIZED {
        anyhow::bail!("device token rejected by gateway wallet transactions");
    }

    let payload = response
        .error_for_status()
        .with_context(|| format!("wallet transactions request failed at {tx_url}"))?
        .json::<TransactionsResponse>()
        .await
        .context("decode wallet transactions response")?;
    Ok(payload.transactions)
}

fn now_unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn now_unix_secs_i64() -> i64 {
    now_unix_secs().try_into().unwrap_or(i64::MAX)
}

fn derive_gateway_url(relay_url: &str) -> anyhow::Result<String> {
    let relay = Url::parse(relay_url).with_context(|| format!("invalid relay url: {relay_url}"))?;
    let scheme = match relay.scheme() {
        "ws" => "http",
        "wss" => "https",
        "http" => "http",
        "https" => "https",
        other => anyhow::bail!("unsupported relay scheme: {other}"),
    };

    let host = relay
        .host_str()
        .ok_or_else(|| anyhow::anyhow!("relay url missing host"))?;
    let gateway_host = host.replacen("relay.", "gateway.", 1);

    let mut gateway = relay;
    gateway
        .set_scheme(scheme)
        .map_err(|_| anyhow::anyhow!("failed to rewrite relay scheme"))?;
    gateway.set_host(Some(&gateway_host))?;
    gateway.set_path("");
    gateway.set_query(None);
    gateway.set_fragment(None);
    Ok(gateway.to_string().trim_end_matches('/').to_string())
}

#[cfg(test)]
mod tests {
    use super::derive_gateway_url;

    #[test]
    fn derive_gateway_https_from_relay_wss() {
        let gateway = derive_gateway_url("wss://relay.teale.com/ws").unwrap();
        assert_eq!(gateway, "https://gateway.teale.com");
    }

    #[test]
    fn derive_gateway_preserves_host_when_not_relay_subdomain() {
        let gateway = derive_gateway_url("https://example.com/ws").unwrap();
        assert_eq!(gateway, "https://example.com");
    }
}
