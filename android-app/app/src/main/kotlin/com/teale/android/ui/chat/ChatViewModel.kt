package com.teale.android.ui.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.teale.android.TealeApplication
import com.teale.android.data.chat.ChatMessageEntity
import com.teale.android.data.chat.ChatRepository
import com.teale.android.data.inference.ChatEvent
import com.teale.android.data.inference.GatewayClient
import com.teale.android.data.inference.ChatMessage as InferenceMessage
import com.teale.android.data.settings.SettingsStore
import com.teale.android.skills.CalendarSkill
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class ChatViewModel : ViewModel() {
    private val container = TealeApplication.instance.container
    private val repository: ChatRepository = container.chatRepository
    private val client: GatewayClient = container.gatewayClient
    private val settings: SettingsStore = container.settingsStore
    private val walletRepo = container.walletRepository

    val sessionId = "default"

    val messages: StateFlow<List<ChatMessageEntity>> =
        repository.observeMessages(sessionId)
            .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    private val _isThinking = MutableStateFlow(false)
    val isThinking: StateFlow<Boolean> = _isThinking.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    fun send(text: String) {
        if (text.isBlank() || _isThinking.value) return
        viewModelScope.launch {
            _error.value = null
            _isThinking.value = true
            try {
                repository.appendUser(sessionId, text.trim())
                val skillContext = buildSkillContext(text.trim())
                val history = buildList {
                    if (skillContext != null) add(InferenceMessage("system", skillContext))
                    addAll(messages.value.map { InferenceMessage(it.role, it.content) })
                    add(InferenceMessage("user", text.trim()))
                }
                val assistantId = repository.startAssistant(sessionId)
                val model = settings.snapshot.first().preferredModel
                val buffer = StringBuilder()
                client.streamChat(model, history).collect { ev ->
                    when (ev) {
                        is ChatEvent.Delta -> {
                            buffer.append(ev.text)
                            repository.appendAssistantDelta(assistantId, buffer.toString())
                        }
                        is ChatEvent.Final -> {
                            repository.finishAssistant(assistantId, buffer.toString())
                        }
                        is ChatEvent.Error -> {
                            _error.value = ev.message
                            repository.finishAssistant(
                                assistantId,
                                if (buffer.isNotEmpty()) buffer.toString()
                                else "⚠️ ${ev.message}"
                            )
                        }
                    }
                }
                walletRepo.refresh()
            } catch (t: Throwable) {
                _error.value = t.message ?: "unknown error"
            } finally {
                _isThinking.value = false
            }
        }
    }

    fun clearError() { _error.value = null }

    private fun buildSkillContext(text: String): String? {
        // Trigger on @calendar or on common calendar-intent phrases in the
        // five languages we ship. The LLM does the heavy lifting once we
        // hand it the events; this regex just decides whether to inject.
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
            // en
            Regex("(?i)\\b(my calendar|on my calendar|this week|next week|tomorrow)\\b"),
            // pt-BR
            Regex("(?i)\\b(meu calend[áa]rio|minha agenda|essa semana|pr[óo]xima semana|amanh[ãa])\\b"),
            // zh-CN
            Regex("日历|这周|下周|明天|日程"),
            // fil
            Regex("(?i)\\b(kalendaryo ko|sa kalendaryo|linggong ito|susunod na linggo|bukas)\\b"),
            // es
            Regex("(?i)\\b(mi calendario|esta semana|pr[óo]xima semana|ma[ñn]ana|mi agenda)\\b"),
        )
    }
}
