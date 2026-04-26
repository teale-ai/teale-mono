package com.teale.android.ui.wallet

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.teale.android.R
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
    private val identity = TealeApplication.instance.container.identity

    private val _balance = MutableStateFlow<BalanceSnapshot?>(null)
    val balance: StateFlow<BalanceSnapshot?> = _balance.asStateFlow()

    private val _transactions = MutableStateFlow<List<LedgerEntry>>(emptyList())
    val transactions: StateFlow<List<LedgerEntry>> = _transactions.asStateFlow()

    private val _sendStatus = MutableStateFlow<String?>(null)
    val sendStatus: StateFlow<String?> = _sendStatus.asStateFlow()

    private val _sendStatusIsError = MutableStateFlow(false)
    val sendStatusIsError: StateFlow<Boolean> = _sendStatusIsError.asStateFlow()

    private val _isSending = MutableStateFlow(false)
    val isSending: StateFlow<Boolean> = _isSending.asStateFlow()

    val deviceId: String
        get() = _balance.value?.deviceID ?: repo.currentDeviceID() ?: identity.deviceId()

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

    fun clearSendStatus() {
        _sendStatus.value = null
        _sendStatusIsError.value = false
    }

    fun sendCredits(
        recipient: String,
        amountText: String,
        memo: String,
        onSuccess: () -> Unit,
    ) {
        val trimmedRecipient = recipient.trim()
        val parsedAmount = amountText.replace(",", "").trim().toLongOrNull()
        val balanceCredits = _balance.value?.balance_credits ?: 0L

        if (trimmedRecipient.isEmpty()) {
            _sendStatus.value = "Enter a recipient first."
            _sendStatusIsError.value = true
            return
        }
        if (parsedAmount == null || parsedAmount <= 0L) {
            _sendStatus.value = "Enter a whole-number credit amount."
            _sendStatusIsError.value = true
            return
        }
        if (parsedAmount > balanceCredits) {
            _sendStatus.value = "That exceeds this device wallet balance."
            _sendStatusIsError.value = true
            return
        }

        viewModelScope.launch {
            _isSending.value = true
            _sendStatus.value = null
            _sendStatusIsError.value = false
            runCatching {
                repo.sendCredits(
                    recipient = trimmedRecipient,
                    amount = parsedAmount,
                    memo = memo.trim(),
                )
            }.onSuccess {
                _sendStatus.value = "Sent ${String.format("%,d", parsedAmount)} credits."
                onSuccess()
            }.onFailure { error ->
                _sendStatus.value = error.message ?: "Could not send credits."
                _sendStatusIsError.value = true
            }
            _isSending.value = false
        }
    }
}

@Composable
fun WalletScreen(viewModel: WalletViewModel = viewModel()) {
    val balance by viewModel.balance.collectAsState()
    val transactions by viewModel.transactions.collectAsState()
    val sendStatus by viewModel.sendStatus.collectAsState()
    val sendStatusIsError by viewModel.sendStatusIsError.collectAsState()
    val isSending by viewModel.isSending.collectAsState()
    val clipboard = LocalClipboardManager.current

    var recipient by remember { mutableStateOf("") }
    var amount by remember { mutableStateOf("") }
    var memo by remember { mutableStateOf("") }
    var copiedDeviceId by remember { mutableStateOf(false) }

    Column(Modifier.fillMaxSize()) {
        BalanceCard(
            balance = balance,
            deviceId = viewModel.deviceId,
            copiedDeviceId = copiedDeviceId,
            onCopyDeviceId = {
                clipboard.setText(AnnotatedString(viewModel.deviceId))
                copiedDeviceId = true
            },
        )
        Spacer(Modifier.height(8.dp))

        SendCreditsCard(
            recipient = recipient,
            amount = amount,
            memo = memo,
            sendStatus = sendStatus,
            sendStatusIsError = sendStatusIsError,
            isSending = isSending,
            onRecipientChange = {
                recipient = it
                viewModel.clearSendStatus()
            },
            onAmountChange = {
                amount = it
                viewModel.clearSendStatus()
            },
            onMemoChange = {
                memo = it
                viewModel.clearSendStatus()
            },
            onSend = {
                viewModel.sendCredits(recipient, amount, memo) {
                    recipient = ""
                    amount = ""
                    memo = ""
                }
            },
        )

        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(R.string.wallet_transactions),
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
        )
        if (transactions.isEmpty()) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .padding(24.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    stringResource(R.string.wallet_empty),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            LazyColumn(
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                items(
                    items = transactions,
                    key = { entry -> entry.id },
                ) { entry ->
                    TransactionRow(entry)
                }
            }
        }
    }
}

@Composable
private fun BalanceCard(
    balance: BalanceSnapshot?,
    deviceId: String,
    copiedDeviceId: Boolean,
    onCopyDeviceId: () -> Unit,
) {
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
                Text(
                    stringResource(R.string.wallet_earned),
                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                    style = MaterialTheme.typography.labelSmall,
                )
                Text(
                    balance?.total_earned_credits?.let { "%,d".format(it) } ?: "—",
                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                )
            }
            Column {
                Text(
                    stringResource(R.string.wallet_spent),
                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                    style = MaterialTheme.typography.labelSmall,
                )
                Text(
                    balance?.total_spent_credits?.let { "%,d".format(it) } ?: "—",
                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                )
            }
            Column {
                Text(
                    stringResource(R.string.wallet_usdc),
                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                    style = MaterialTheme.typography.labelSmall,
                )
                Text(
                    balance?.usdc_cents?.let { "$%.2f".format(it / 100.0) } ?: "$0.00",
                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                )
            }
        }
        Spacer(Modifier.height(14.dp))
        Text(
            stringResource(R.string.wallet_device_id),
            color = MaterialTheme.colorScheme.onPrimaryContainer,
            style = MaterialTheme.typography.labelSmall,
        )
        Button(
            onClick = onCopyDeviceId,
            modifier = Modifier.padding(top = 6.dp),
        ) {
            Text(shortDeviceId(deviceId))
        }
        Text(
            if (copiedDeviceId) {
                stringResource(R.string.wallet_device_id_copied)
            } else {
                stringResource(R.string.wallet_device_id_note)
            },
            color = MaterialTheme.colorScheme.onPrimaryContainer,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.padding(top = 6.dp),
        )
    }
}

@Composable
private fun SendCreditsCard(
    recipient: String,
    amount: String,
    memo: String,
    sendStatus: String?,
    sendStatusIsError: Boolean,
    isSending: Boolean,
    onRecipientChange: (String) -> Unit,
    onAmountChange: (String) -> Unit,
    onMemoChange: (String) -> Unit,
    onSend: () -> Unit,
) {
    Column(
        modifier = Modifier
            .padding(horizontal = 16.dp)
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            stringResource(R.string.wallet_send_title),
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
        )
        OutlinedTextField(
            value = recipient,
            onValueChange = onRecipientChange,
            label = { Text(stringResource(R.string.wallet_send_recipient)) },
            supportingText = { Text(stringResource(R.string.wallet_send_recipient_note)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = amount,
            onValueChange = onAmountChange,
            label = { Text(stringResource(R.string.wallet_send_amount)) },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        OutlinedTextField(
            value = memo,
            onValueChange = onMemoChange,
            label = { Text(stringResource(R.string.wallet_send_memo)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )
        Button(
            onClick = onSend,
            enabled = !isSending,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                if (isSending) stringResource(R.string.wallet_send_sending)
                else stringResource(R.string.action_send)
            )
        }
        Text(
            stringResource(R.string.wallet_send_note),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (!sendStatus.isNullOrBlank()) {
            Text(
                sendStatus,
                style = MaterialTheme.typography.bodySmall,
                color = if (sendStatusIsError) Color(0xFFDC2626) else MaterialTheme.colorScheme.onSurfaceVariant,
            )
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

private fun shortDeviceId(value: String): String {
    if (value.length <= 16) return value
    return "${value.take(8)}...${value.takeLast(8)}"
}
