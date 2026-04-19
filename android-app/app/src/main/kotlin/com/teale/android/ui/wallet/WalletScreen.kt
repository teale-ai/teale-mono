package com.teale.android.ui.wallet

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.teale.android.R
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.teale.android.TealeApplication
import com.teale.android.data.wallet.BalanceSnapshot
import com.teale.android.data.wallet.LedgerEntry
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class WalletViewModel : ViewModel() {
    private val repo = TealeApplication.instance.container.walletRepository

    private val _balance = MutableStateFlow<BalanceSnapshot?>(null)
    val balance: StateFlow<BalanceSnapshot?> = _balance.asStateFlow()

    private val _transactions = MutableStateFlow<List<LedgerEntry>>(emptyList())
    val transactions: StateFlow<List<LedgerEntry>> = _transactions.asStateFlow()

    init {
        viewModelScope.launch {
            repo.balance.collect { _balance.value = it }
        }
        viewModelScope.launch {
            repo.transactions.collect { _transactions.value = it }
        }
        viewModelScope.launch {
            while (true) {
                repo.refresh()
                delay(5_000)
            }
        }
    }

    fun refresh() {
        viewModelScope.launch { repo.refresh() }
    }
}

@Composable
fun WalletScreen(viewModel: WalletViewModel = viewModel()) {
    val balance by viewModel.balance.collectAsState()
    val transactions by viewModel.transactions.collectAsState()

    Column(Modifier.fillMaxSize()) {
        BalanceCard(balance)
        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(R.string.wallet_transactions),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
        if (transactions.isEmpty()) {
            Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                Text(stringResource(R.string.wallet_empty), color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        } else {
            LazyColumn(
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                items(transactions, key = { it.id }) { TransactionRow(it) }
            }
        }
    }
}

@Composable
private fun BalanceCard(balance: BalanceSnapshot?) {
    Column(
        modifier = Modifier
            .padding(16.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.primaryContainer)
            .padding(20.dp)
    ) {
        Text(
            stringResource(R.string.wallet_credits),
            color = MaterialTheme.colorScheme.onPrimaryContainer,
            style = MaterialTheme.typography.labelMedium,
        )
        Text(
            balance?.balance_credits?.let { "${"%,d".format(it)}" } ?: "—",
            color = MaterialTheme.colorScheme.onPrimaryContainer,
            style = MaterialTheme.typography.displaySmall,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
            Column {
                Text(stringResource(R.string.wallet_earned), color = MaterialTheme.colorScheme.onPrimaryContainer, style = MaterialTheme.typography.labelSmall)
                Text(balance?.total_earned_credits?.let { "%,d".format(it) } ?: "—", color = MaterialTheme.colorScheme.onPrimaryContainer)
            }
            Column {
                Text(stringResource(R.string.wallet_spent), color = MaterialTheme.colorScheme.onPrimaryContainer, style = MaterialTheme.typography.labelSmall)
                Text(balance?.total_spent_credits?.let { "%,d".format(it) } ?: "—", color = MaterialTheme.colorScheme.onPrimaryContainer)
            }
            Column {
                Text(stringResource(R.string.wallet_usdc), color = MaterialTheme.colorScheme.onPrimaryContainer, style = MaterialTheme.typography.labelSmall)
                Text(
                    balance?.usdc_cents?.let { "$%.2f".format(it / 100.0) } ?: "$0.00",
                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                )
            }
        }
    }
}

@Composable
private fun TransactionRow(entry: LedgerEntry) {
    val (badgeColor, badgeTextColor) = when (entry.type) {
        "BONUS" -> Color(0xFF0D9488) to Color.White
        "DIRECT_EARN" -> Color(0xFF059669) to Color.White
        "AVAILABILITY_EARN" -> Color(0xFF65A30D) to Color.White
        "AVAILABILITY_DRIP" -> Color(0xFF84CC16) to Color.White
        "SPENT" -> Color(0xFFDC2626) to Color.White
        else -> MaterialTheme.colorScheme.surfaceVariant to MaterialTheme.colorScheme.onSurfaceVariant
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surface)
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(8.dp))
                .background(badgeColor)
                .padding(horizontal = 8.dp, vertical = 4.dp),
        ) {
            Text(entry.type, color = badgeTextColor, style = MaterialTheme.typography.labelSmall)
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                entry.note ?: "—",
                maxLines = 1,
                style = MaterialTheme.typography.bodySmall,
            )
            Text(
                SimpleDateFormat("MMM d · HH:mm", Locale.getDefault())
                    .format(Date(entry.timestamp * 1000)),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Text(
            if (entry.amount >= 0) "+${"%,d".format(entry.amount)}" else "${"%,d".format(entry.amount)}",
            fontWeight = FontWeight.SemiBold,
            color = if (entry.amount >= 0) Color(0xFF059669) else Color(0xFFDC2626),
        )
    }
}
