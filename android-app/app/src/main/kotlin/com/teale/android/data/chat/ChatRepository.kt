package com.teale.android.data.chat

import kotlinx.coroutines.flow.Flow
import java.util.UUID

class ChatRepository(private val dao: ChatDao) {

    fun observeMessages(sessionId: String): Flow<List<ChatMessageEntity>> =
        dao.observeMessages(sessionId)

    suspend fun appendUser(sessionId: String, content: String): String {
        val id = UUID.randomUUID().toString()
        dao.upsert(
            ChatMessageEntity(
                id = id,
                sessionId = sessionId,
                role = "user",
                content = content,
                timestamp = System.currentTimeMillis(),
            )
        )
        return id
    }

    suspend fun startAssistant(sessionId: String): String {
        val id = UUID.randomUUID().toString()
        dao.upsert(
            ChatMessageEntity(
                id = id,
                sessionId = sessionId,
                role = "assistant",
                content = "",
                timestamp = System.currentTimeMillis(),
                streaming = true,
            )
        )
        return id
    }

    suspend fun appendAssistantDelta(messageId: String, newContent: String) {
        dao.updateContent(messageId, newContent, streaming = true)
    }

    suspend fun finishAssistant(messageId: String, finalContent: String) {
        dao.updateContent(messageId, finalContent, streaming = false)
    }

    suspend fun clearSession(sessionId: String) = dao.clearSession(sessionId)
}
