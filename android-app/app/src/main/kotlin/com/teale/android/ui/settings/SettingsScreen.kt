package com.teale.android.ui.settings

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.appcompat.app.AppCompatDelegate
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.core.os.LocaleListCompat
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.teale.android.R
import com.teale.android.TealeApplication
import com.teale.android.data.settings.SettingsStore
import com.teale.android.service.SupplyAccelerationMode
import com.teale.android.service.SupplyService
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class SettingsViewModel : ViewModel() {
    private val container = TealeApplication.instance.container
    private val store: SettingsStore = container.settingsStore

    private val _snapshot = MutableStateFlow(
        SettingsStore.Snapshot(
            username = "",
            phone = "",
            supplyEnabled = false,
            preferredModel = SettingsStore.DEFAULT_MODEL,
            supplyChargingOnly = SettingsStore.DEFAULT_SUPPLY_CHARGING_ONLY,
            supplyAccelerationMode = SettingsStore.DEFAULT_SUPPLY_ACCELERATION,
        )
    )
    val snapshot: StateFlow<SettingsStore.Snapshot> = _snapshot.asStateFlow()

    val deviceId: String = container.identity.deviceId()

    init {
        viewModelScope.launch {
            store.snapshot.collect { _snapshot.value = it }
        }
    }

    fun setUsername(v: String) = viewModelScope.launch {
        store.setUsername(v)
        runCatching { container.usernameClient.setUsername(v.trim()) }
    }
    fun setPhone(v: String) = viewModelScope.launch { store.setPhone(v) }
    fun setSupplyEnabled(v: Boolean) = viewModelScope.launch {
        store.setSupplyEnabled(v)
        SupplyService.toggle(TealeApplication.instance, v)
    }
    fun setPreferredModel(v: String) = viewModelScope.launch { store.setPreferredModel(v) }
    fun setSupplyChargingOnly(v: Boolean) = viewModelScope.launch {
        store.setSupplyChargingOnly(v)
        refreshSupplyIfActive()
    }
    fun setSupplyAccelerationMode(v: String) = viewModelScope.launch {
        store.setSupplyAccelerationMode(v)
        refreshSupplyIfActive()
    }

    suspend fun settings() = store.snapshot.first()

    private suspend fun refreshSupplyIfActive() {
        if (store.snapshot.first().supplyEnabled) {
            SupplyService.refresh(TealeApplication.instance)
        }
    }
}

@Composable
fun SettingsScreen(viewModel: SettingsViewModel = viewModel()) {
    val snapshot by viewModel.snapshot.collectAsState()
    val ctx = LocalContext.current
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // Identity card
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .padding(16.dp),
        ) {
            Text(stringResource(R.string.settings_device_id), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(4.dp))
            Text(
                viewModel.deviceId.chunked(8).joinToString(" "),
                style = MaterialTheme.typography.bodySmall,
            )
        }

        ClaudeGatewayCard()

        OutlinedTextField(
            value = snapshot.username,
            onValueChange = viewModel::setUsername,
            label = { Text(stringResource(R.string.settings_username_label)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
        )

        OutlinedTextField(
            value = snapshot.phone,
            onValueChange = viewModel::setPhone,
            label = { Text(stringResource(R.string.settings_phone_label)) },
            singleLine = true,
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                keyboardType = KeyboardType.Phone
            ),
            modifier = Modifier.fillMaxWidth(),
        )

        OutlinedTextField(
            value = snapshot.preferredModel,
            onValueChange = viewModel::setPreferredModel,
            label = { Text(stringResource(R.string.settings_model_label)) },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
            supportingText = { Text(stringResource(R.string.settings_model_supporting)) },
        )

        LanguagePicker()

        // Supply toggle
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.settings_supply_title), fontWeight = FontWeight.SemiBold)
                Text(
                    if (snapshot.supplyEnabled)
                        stringResource(R.string.settings_supply_on)
                    else
                        stringResource(R.string.settings_supply_off),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Switch(
                checked = snapshot.supplyEnabled,
                onCheckedChange = viewModel::setSupplyEnabled,
            )
        }

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(MaterialTheme.colorScheme.surfaceVariant)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                stringResource(R.string.settings_supply_beta_title),
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                stringResource(R.string.settings_supply_beta_body),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(
                        stringResource(R.string.settings_supply_charging_only_title),
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        stringResource(R.string.settings_supply_charging_only_body),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Switch(
                    checked = snapshot.supplyChargingOnly,
                    onCheckedChange = viewModel::setSupplyChargingOnly,
                )
            }

            SupplyAccelerationPicker(
                value = snapshot.supplyAccelerationMode,
                onChange = viewModel::setSupplyAccelerationMode,
            )
        }

        // Invite
        val inviteBody = stringResource(
            R.string.invite_sms_body,
            viewModel.deviceId.take(6),
        )
        Button(
            onClick = {
                val smsIntent = Intent(Intent.ACTION_SENDTO).apply {
                    data = android.net.Uri.parse("smsto:")
                    putExtra("sms_body", inviteBody)
                }
                runCatching { ctx.startActivity(smsIntent) }
            },
            modifier = Modifier.fillMaxWidth(),
        ) { Text(stringResource(R.string.settings_invite)) }

        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(R.string.settings_scale_title),
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
        )
        Text(
            stringResource(R.string.settings_scale_body),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

// ── Language picker ──────────────────────────────────────────────────────────
// Languages listed here must also appear in res/xml/locales_config.xml and
// ship a values-<tag>/strings.xml. Switching calls AppCompatDelegate which
// restarts the activity with the new locale.

private data class Language(val tag: String, val nameRes: Int)
private data class SupplyAccelerationOption(
    val value: String,
    val labelRes: Int,
    val bodyRes: Int,
)

private val SUPPORTED_LANGUAGES = listOf(
    Language("en", R.string.lang_en),
    Language("pt-BR", R.string.lang_pt_br),
    Language("zh-CN", R.string.lang_zh_cn),
    Language("fil", R.string.lang_fil),
    Language("es", R.string.lang_es),
)

private val SUPPLY_ACCELERATION_OPTIONS = listOf(
    SupplyAccelerationOption(
        value = SupplyAccelerationMode.Auto.storageValue,
        labelRes = R.string.settings_supply_acceleration_auto,
        bodyRes = R.string.settings_supply_acceleration_auto_body,
    ),
    SupplyAccelerationOption(
        value = SupplyAccelerationMode.CpuOnly.storageValue,
        labelRes = R.string.settings_supply_acceleration_cpu,
        bodyRes = R.string.settings_supply_acceleration_cpu_body,
    ),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun LanguagePicker() {
    var expanded by remember { mutableStateOf(false) }
    val currentTag = AppCompatDelegate.getApplicationLocales()
        .toLanguageTags().takeIf { it.isNotEmpty() }
    val currentLabel = SUPPORTED_LANGUAGES.firstOrNull { it.tag == currentTag }
        ?.let { stringResource(it.nameRes) }
        ?: stringResource(R.string.settings_language_system)

    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = !expanded },
    ) {
        OutlinedTextField(
            readOnly = true,
            value = currentLabel,
            onValueChange = { },
            label = { Text(stringResource(R.string.settings_language_title)) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
            modifier = Modifier.fillMaxWidth().menuAnchor(),
        )
        ExposedDropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
            DropdownMenuItem(
                text = { Text(stringResource(R.string.settings_language_system)) },
                onClick = {
                    AppCompatDelegate.setApplicationLocales(LocaleListCompat.getEmptyLocaleList())
                    expanded = false
                },
            )
            SUPPORTED_LANGUAGES.forEach { lang ->
                DropdownMenuItem(
                    text = { Text(stringResource(lang.nameRes)) },
                    onClick = {
                        AppCompatDelegate.setApplicationLocales(
                            LocaleListCompat.forLanguageTags(lang.tag)
                        )
                        expanded = false
                    },
                )
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SupplyAccelerationPicker(
    value: String,
    onChange: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val current = SUPPLY_ACCELERATION_OPTIONS.firstOrNull { it.value == value }
        ?: SUPPLY_ACCELERATION_OPTIONS.first()

    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = !expanded },
    ) {
        OutlinedTextField(
            readOnly = true,
            value = stringResource(current.labelRes),
            onValueChange = { },
            label = { Text(stringResource(R.string.settings_supply_acceleration_title)) },
            supportingText = { Text(stringResource(current.bodyRes)) },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
            modifier = Modifier.fillMaxWidth().menuAnchor(),
        )
        ExposedDropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
            SUPPLY_ACCELERATION_OPTIONS.forEach { option ->
                DropdownMenuItem(
                    text = { Text(stringResource(option.labelRes)) },
                    onClick = {
                        onChange(option.value)
                        expanded = false
                    },
                )
            }
        }
    }
}

private const val CLAUDE_GATEWAY_SNIPPET = """Claude Desktop:
inferenceProvider = gateway
inferenceGatewayBaseUrl = https://gateway.teale.com
inferenceGatewayAuthScheme = bearer
inferenceGatewayHeaders = ["X-Teale-Prefer-Linked-Device: true"]
disabledBuiltinTools = ["WebSearch"]

Claude Code:
ANTHROPIC_BASE_URL=https://gateway.teale.com"""

@Composable
private fun ClaudeGatewayCard() {
    val clipboard = LocalClipboardManager.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant)
            .padding(16.dp),
    ) {
        Text(
            "Claude Desktop / Claude Code",
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(4.dp))
        Text(
            "Point Claude Desktop or Claude Code at gateway.teale.com using a key created from the Teale desktop app.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            CLAUDE_GATEWAY_SNIPPET,
            style = MaterialTheme.typography.bodySmall,
            fontFamily = FontFamily.Monospace,
        )
        Spacer(Modifier.height(8.dp))
        TextButton(
            onClick = { clipboard.setText(AnnotatedString(CLAUDE_GATEWAY_SNIPPET)) },
            contentPadding = PaddingValues(0.dp),
        ) {
            Text("Copy config")
        }
    }
}
