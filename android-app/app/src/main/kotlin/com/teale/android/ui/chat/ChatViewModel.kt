package com.teale.android.ui.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.teale.android.TealeApplication
import com.teale.android.data.chat.ChatMessageEntity
import com.teale.android.data.chat.ChatRepository
import com.teale.android.data.chat.ChatThreadEntity
import com.teale.android.data.inference.ChatEvent
import com.teale.android.data.inference.ChatMessage as InferenceMessage
import com.teale.android.data.inference.GatewayClient
import com.teale.android.data.inference.NetworkModel
import com.teale.android.data.inference.NetworkStatsSnapshot
import com.teale.android.data.settings.SettingsStore
import com.teale.android.data.wallet.BalanceSnapshot
import com.teale.android.skills.CalendarSkill
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

data class InterruptedDraft(
    val text: String,
    val message: String,
)

@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModel : ViewModel() {
    private val container = TealeApplication.instance.container
    private val repository: ChatRepository = container.chatRepository
    private val client: GatewayClient = container.gatewayClient
    private val settings: SettingsStore = container.settingsStore
    private val walletRepo = container.walletRepository

    private val _selectedThreadId = MutableStateFlow<String?>(null)
    val selectedThreadId: StateFlow<String?> = _selectedThreadId.asStateFlow()

    private val _threads = MutableStateFlow<List<ChatThreadEntity>>(emptyList())
    val threads: StateFlow<List<ChatThreadEntity>> = _threads.asStateFlow()

    private val _networkModels = MutableStateFlow<List<NetworkModel>>(emptyList())
    val networkModels: StateFlow<List<NetworkModel>> = _networkModels.asStateFlow()

    private val _networkStats = MutableStateFlow<NetworkStatsSnapshot?>(null)
    val networkStats: StateFlow<NetworkStatsSnapshot?> = _networkStats.asStateFlow()

    val walletBalance: StateFlow<BalanceSnapshot?> =
        walletRepo.balance.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    val settingsSnapshot: StateFlow<SettingsStore.Snapshot> =
        settings.snapshot.stateIn(
            viewModelScope,
            SharingStarted.Eagerly,
            SettingsStore.Snapshot(
                username = "",
                phone = "",
                supplyEnabled = false,
                preferredModel = SettingsStore.DEFAULT_MODEL,
                supplyChargingOnly = SettingsStore.DEFAULT_SUPPLY_CHARGING_ONLY,
                supplyAccelerationMode = SettingsStore.DEFAULT_SUPPLY_ACCELERATION,
            )
        )

    val selectedThread: StateFlow<ChatThreadEntity?> =
        combine(_threads, _selectedThreadId) { threads, selectedId ->
            threads.firstOrNull { it.id == selectedId } ?: threads.firstOrNull()
        }.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    val messages: StateFlow<List<ChatMessageEntity>> =
        selectedThread
            .filterNotNull()
            .flatMapLatest { repository.observeMessages(it.id) }
            .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val _isThinking = MutableStateFlow(false)
    val isThinking: StateFlow<Boolean> = _isThinking.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private val _info = MutableStateFlow<String?>(null)
    val info: StateFlow<String?> = _info.asStateFlow()

    private val _interruptedDrafts = MutableStateFlow<Map<String, InterruptedDraft>>(emptyMap())
    val interruptedDrafts: StateFlow<Map<String, InterruptedDraft>> = _interruptedDrafts.asStateFlow()

    init {
        viewModelScope.launch {
            repository.ensureThread(settings.snapshot.first().preferredModel)
        }
        viewModelScope.launch {
            repository.observeThreads().collect { threads ->
                _threads.value = threads
                val currentSelection = _selectedThreadId.value
                if (threads.isNotEmpty() && threads.none { it.id == currentSelection }) {
                    _selectedThreadId.value = threads.first().id
                }
            }
        }
        viewModelScope.launch {
            while (true) {
                refreshHomeData()
                delay(30_000)
            }
        }
    }

    fun refresh() {
        viewModelScope.launch { refreshHomeData() }
    }

    fun selectThread(threadId: String) {
        _selectedThreadId.value = threadId
        _error.value = null
        _info.value = null
    }

    fun createThread() {
        if (_isThinking.value) return
        viewModelScope.launch {
            val thread = repository.createThread(defaultModelId())
            _selectedThreadId.value = thread.id
            _error.value = null
            _info.value = null
        }
    }

    fun closeThread(threadId: String) {
        if (_isThinking.value) return
        viewModelScope.launch {
            val next = repository.closeThread(threadId)
            _interruptedDrafts.value = _interruptedDrafts.value - threadId
            _selectedThreadId.value = next.id
        }
    }

    fun setThreadModel(modelId: String) {
        val thread = selectedThread.value ?: return
        viewModelScope.launch {
            repository.updateThreadModel(thread.id, modelId)
            _info.value = null
        }
    }

    fun send(text: String) {
        val input = text.trim()
        val thread = selectedThread.value
        if (input.isBlank() || _isThinking.value || thread == null) return

        viewModelScope.launch {
            _error.value = null
            _info.value = null
            _isThinking.value = true
            val modelId = resolveModelForThread(thread) ?: run {
                _error.value = "No network models are available yet."
                _isThinking.value = false
                return@launch
            }

            try {
                val existingMessages = repository.listMessages(thread.id)
                val skillContext = buildSkillContext(input)
                val requestHistory = buildList {
                    if (skillContext != null) {
                        add(InferenceMessage("system", skillContext))
                    }
                    addAll(existingMessages.filter { !it.streaming }.map {
                        InferenceMessage(it.role, it.content)
                    })
                    add(InferenceMessage("user", input))
                }
                val userMessageId = repository.appendUser(thread.id, input)
                val estimatedPromptTokens = estimateChatPromptTokens(requestHistory)
                repository.updateMessageUsage(userMessageId, estimatedPromptTokens, tokenEstimated = true)

                if (existingMessages.none { it.role == "user" }) {
                    repository.renameThread(thread.id, normalizeThreadTitle(input))
                }

                val assistantId = repository.startAssistant(thread.id)
                var promptTokens: Int? = estimatedPromptTokens
                var promptTokensEstimated = true
                var completionTokens: Int? = null
                var completionTokensEstimated = true
                var streamFailed = false
                val buffer = StringBuilder()

                client.streamChat(modelId, requestHistory).collect { event ->
                    when (event) {
                        is ChatEvent.Delta -> {
                            buffer.append(event.text)
                            if (completionTokens == null) {
                                completionTokens = estimateChatTextTokens(buffer.toString())
                                completionTokensEstimated = true
                            }
                            repository.appendAssistantDelta(
                                assistantId,
                                buffer.toString(),
                                tokenCount = completionTokens,
                                tokenEstimated = completionTokensEstimated,
                            )
                        }

                        is ChatEvent.Usage -> {
                            if (event.promptTokens != null) {
                                promptTokens = event.promptTokens
                                promptTokensEstimated = false
                            }
                            if (event.completionTokens != null) {
                                completionTokens = event.completionTokens
                                completionTokensEstimated = false
                                repository.appendAssistantDelta(
                                    assistantId,
                                    buffer.toString(),
                                    tokenCount = completionTokens,
                                    tokenEstimated = completionTokensEstimated,
                                )
                            }
                        }

                        ChatEvent.Final -> {
                            repository.updateMessageUsage(
                                userMessageId,
                                promptTokens,
                                tokenEstimated = promptTokensEstimated,
                            )
                            repository.finishAssistant(
                                assistantId,
                                finalContent = buffer.toString(),
                                tokenCount = completionTokens ?: estimateChatTextTokens(buffer.toString()),
                                tokenEstimated = completionTokens == null || completionTokensEstimated,
                            )
                        }

                        is ChatEvent.Error -> {
                            streamFailed = true
                            repository.updateMessageUsage(
                                userMessageId,
                                promptTokens,
                                tokenEstimated = promptTokensEstimated,
                            )
                            repository.deleteMessage(assistantId)
                            val partial = buffer.toString()
                            if (partial.isNotBlank()) {
                                _interruptedDrafts.value = _interruptedDrafts.value + (
                                    thread.id to InterruptedDraft(partial, event.message)
                                )
                            }
                            _error.value = event.message
                        }
                    }
                }

                if (!streamFailed) {
                    _interruptedDrafts.value = _interruptedDrafts.value - thread.id
                }
                walletRepo.refresh()
            } catch (t: Throwable) {
                _error.value = t.message ?: "unknown error"
            } finally {
                _isThinking.value = false
            }
        }
    }

    fun clearError() {
        _error.value = null
    }

    fun clearInfo() {
        _info.value = null
    }

    private suspend fun refreshHomeData() {
        runCatching { walletRepo.refresh() }
        val models = runCatching { client.listModels() }.getOrElse { emptyList() }
        _networkModels.value = models.sortedWith(
            compareByDescending<NetworkModel> { it.loadedDeviceCount ?: 0 }
                .thenBy { it.id }
        )
        _networkStats.value = runCatching { client.fetchNetworkStats() }.getOrNull()
        reconcileThreadModels()
    }

    private suspend fun reconcileThreadModels() {
        val availableList = _networkModels.value.map { it.id }
        if (availableList.isEmpty()) {
            return
        }
        val available = availableList.toSet()
        val fallbackModelId = settingsSnapshot.value.preferredModel.takeIf { it in available }
            ?: availableList.first()
        _threads.value.forEach { thread ->
            val selectedModelId = thread.selectedModelId
            if (selectedModelId != null && selectedModelId in available) {
                return@forEach
            }
            if (selectedModelId != fallbackModelId) {
                repository.updateThreadModel(thread.id, fallbackModelId)
                if (thread.id == _selectedThreadId.value && selectedModelId != null) {
                    _info.value =
                        "Switched to $fallbackModelId because $selectedModelId is not available right now."
                }
            }
        }
    }

    private fun resolveModelForThread(thread: ChatThreadEntity): String? {
        val availableIds = _networkModels.value.map { it.id }
        return when {
            thread.selectedModelId != null && availableIds.contains(thread.selectedModelId) ->
                thread.selectedModelId
            availableIds.isNotEmpty() ->
                availableIds.first()
            else -> null
        }
    }

    private fun defaultModelId(): String? {
        val preferred = settingsSnapshot.value.preferredModel
        return when {
            _networkModels.value.any { it.id == preferred } -> preferred
            _networkModels.value.isNotEmpty() -> _networkModels.value.first().id
            else -> preferred.takeIf { it.isNotBlank() }
        }
    }

    private fun buildSkillContext(text: String): String? {
        val wantsCalendar = text.contains("@calendar", ignoreCase = true) ||
            CALENDAR_TRIGGERS.any { it.containsMatchIn(text) }
        if (!wantsCalendar) return null
        val app = TealeApplication.instance
        if (!CalendarSkill.hasPermission(app)) {
            return app.getString(com.teale.android.R.string.calendar_permission_hint)
        }
        return CalendarSkill.upcomingSummary(app)
    }

    companion object {
        private val CALENDAR_TRIGGERS = listOf(
            Regex("(?i)\\b(my calendar|on my calendar|this week|next week|tomorrow)\\b"),
            Regex("(?i)\\b(meu calend[áa]rio|minha agenda|essa semana|pr[óo]xima semana|amanh[ãa])\\b"),
            Regex("日历|这周|下周|明天|日程"),
            Regex("(?i)\\b(kalendaryo ko|sa kalendaryo|linggong ito|susunod na linggo|bukas)\\b"),
            Regex("(?i)\\b(mi calendario|esta semana|pr[óo]xima semana|ma[ñn]ana|mi agenda)\\b"),
        )
    }
}
