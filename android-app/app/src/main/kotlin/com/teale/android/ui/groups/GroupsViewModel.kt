package com.teale.android.ui.groups

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.teale.android.TealeApplication
import com.teale.android.data.groups.GroupMessage
import com.teale.android.data.groups.GroupSummary
import com.teale.android.data.inference.ChatEvent
import com.teale.android.data.inference.ChatMessage as InferenceMessage
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class GroupsViewModel : ViewModel() {
    private val container = TealeApplication.instance.container
    private val repo = container.groupRepository
    private val gateway = container.gatewayClient
    private val settings = container.settingsStore

    private val _groups = MutableStateFlow<List<GroupSummary>>(emptyList())
    val groups: StateFlow<List<GroupSummary>> = _groups.asStateFlow()

    private val _messages = MutableStateFlow<List<GroupMessage>>(emptyList())
    val messages: StateFlow<List<GroupMessage>> = _messages.asStateFlow()

    private val _isSending = MutableStateFlow(false)
    val isSending: StateFlow<Boolean> = _isSending.asStateFlow()

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error.asStateFlow()

    private var activeGroup: String? = null
    private var pollJob: Job? = null

    fun refreshList() {
        viewModelScope.launch {
            try {
                _groups.value = repo.listMine()
            } catch (t: Throwable) {
                _error.value = t.message
            }
        }
    }

    fun createGroup(title: String, onCreated: (String) -> Unit = {}) {
        viewModelScope.launch {
            try {
                val g = repo.create(title)
                if (g != null) {
                    _groups.value = listOf(g) + _groups.value
                    onCreated(g.groupID)
                }
            } catch (t: Throwable) {
                _error.value = t.message
            }
        }
    }

    fun openGroup(groupId: String) {
        if (activeGroup == groupId) return
        activeGroup = groupId
        pollJob?.cancel()
        _messages.value = emptyList()
        pollJob = viewModelScope.launch {
            while (true) {
                try {
                    val since = _messages.value.maxOfOrNull { it.timestamp } ?: 0
                    val newer = repo.listMessages(groupId, since)
                    if (newer.isNotEmpty()) {
                        // Merge: drop any we already have (server timestamps == our
                        // latest), keep older in place, append new ones sorted.
                        val existingIds = _messages.value.map { it.id }.toSet()
                        val additions = newer.filter { it.id !in existingIds }
                        if (additions.isNotEmpty()) {
                            _messages.value = (_messages.value + additions)
                                .sortedBy { it.timestamp }
                        }
                    }
                } catch (_: Throwable) { /* keep polling */ }
                delay(2_000)
            }
        }
    }

    fun leaveGroup() {
        activeGroup = null
        pollJob?.cancel()
        _messages.value = emptyList()
    }

    /**
     * Post a human message. If it contains `@teale`, also synthesize an AI
     * response by calling /v1/chat/completions with the group history as
     * context, then post the response as a message with type="ai".
     */
    fun sendMessage(groupId: String, content: String) {
        val trimmed = content.trim()
        if (trimmed.isEmpty() || _isSending.value) return
        viewModelScope.launch {
            _isSending.value = true
            _error.value = null
            try {
                val human = repo.postMessage(groupId, trimmed, type = "text")
                if (human != null) {
                    val merged = (_messages.value + human).sortedBy { it.timestamp }
                    _messages.value = merged
                }

                if (trimmed.contains("@teale", ignoreCase = true)) {
                    val history = buildAiContext(trimmed)
                    val model = settings.snapshot.first().preferredModel
                    val buffer = StringBuilder()
                    gateway.streamChat(model, history).collect { ev ->
                        when (ev) {
                            is ChatEvent.Delta -> buffer.append(ev.text)
                            is ChatEvent.Final -> {}
                            is ChatEvent.Error -> _error.value = ev.message
                        }
                    }
                    val reply = buffer.toString().trim()
                    if (reply.isNotEmpty()) {
                        val posted = repo.postMessage(groupId, reply, type = "ai")
                        if (posted != null) {
                            _messages.value = (_messages.value + posted).sortedBy { it.timestamp }
                        }
                    }
                }
            } catch (t: Throwable) {
                _error.value = t.message
            } finally {
                _isSending.value = false
            }
        }
    }

    private fun buildAiContext(latest: String): List<InferenceMessage> {
        val systemMsg = InferenceMessage(
            "system",
            TealeApplication.instance.getString(com.teale.android.R.string.group_ai_system_prompt)
        )
        val historyMessages = _messages.value.takeLast(20).map { m ->
            val role = when (m.type) {
                "ai" -> "assistant"
                else -> "user"
            }
            InferenceMessage(role, m.content)
        }
        return listOf(systemMsg) + historyMessages + InferenceMessage("user", latest)
    }

    fun clearError() { _error.value = null }

    override fun onCleared() {
        pollJob?.cancel()
        super.onCleared()
    }
}
