package com.teale.android.data.wallet

import com.teale.android.data.auth.TokenExchangeClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

@Serializable
data class BalanceSnapshot(
    val deviceID: String,
    val balance_credits: Long,
    val total_earned_credits: Long,
    val total_spent_credits: Long,
    val usdc_cents: Long,
)

@Serializable
data class LedgerEntry(
    val id: Long,
    val device_id: String,
    val type: String,
    val amount: Long,
    val timestamp: Long,
    val refRequestID: String? = null,
    val note: String? = null,
)

@Serializable
data class TransactionsRes(val transactions: List<LedgerEntry>)

class WalletRepository(
    private val baseUrl: String,
    private val tokenClient: TokenExchangeClient,
) {
    private val http = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()
    private val json = Json { ignoreUnknownKeys = true }

    private val _balance = MutableStateFlow<BalanceSnapshot?>(null)
    val balance: Flow<BalanceSnapshot?> = _balance.asStateFlow()

    private val _transactions = MutableStateFlow<List<LedgerEntry>>(emptyList())
    val transactions: Flow<List<LedgerEntry>> = _transactions.asStateFlow()

    suspend fun refresh() = withContext(Dispatchers.IO) {
        runCatching {
            val token = tokenClient.bearer()
            val balReq = Request.Builder()
                .url("$baseUrl/v1/wallet/balance")
                .addHeader("Authorization", "Bearer $token")
                .build()
            http.newCall(balReq).execute().use { r ->
                if (r.isSuccessful) {
                    val body = r.body?.string().orEmpty()
                    _balance.value = json.decodeFromString(BalanceSnapshot.serializer(), body)
                } else if (r.code == 401) {
                    tokenClient.invalidate()
                }
            }
            val txReq = Request.Builder()
                .url("$baseUrl/v1/wallet/transactions?limit=100")
                .addHeader("Authorization", "Bearer $token")
                .build()
            http.newCall(txReq).execute().use { r ->
                if (r.isSuccessful) {
                    val body = r.body?.string().orEmpty()
                    val list = json.decodeFromString(TransactionsRes.serializer(), body)
                    _transactions.value = list.transactions
                }
            }
        }
    }

    fun currentBalance(): BalanceSnapshot? = _balance.value
}
