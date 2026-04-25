package com.teale.android.data.chat

import kotlinx.coroutines.flow.Flow
import java.util.UUID

class ChatRepository(private val dao: ChatDao) {

    fun observeThreads(): Flow<List<ChatThreadEntity>> = dao.observeThreads()

    fun observeMessages(threadId: String): Flow<List<ChatMessageEntity>> =
        dao.observeMessages(threadId)

    suspend fun listMessages(threadId: String): List<ChatMessageEntity> = dao.listMessages(threadId)

    suspend fun ensureThread(defaultModelId: String?): ChatThreadEntity =
        dao.latestThread() ?: createThread(defaultModelId)

    suspend fun createThread(defaultModelId: String?): ChatThreadEntity {
        val now = System.currentTimeMillis()
        val thread = ChatThreadEntity(
            id = UUID.randomUUID().toString(),
            title = DEFAULT_THREAD_TITLE,
            selectedModelId = defaultModelId,
            updatedAt = now,
            createdAt = now,
        )
        dao.upsertThread(thread)
        return thread
    }

    suspend fun updateThreadModel(threadId: String, modelId: String?) {
        val thread = dao.getThread(threadId) ?: return
        dao.upsertThread(
            thread.copy(
                selectedModelId = modelId,
                updatedAt = System.currentTimeMillis(),
            )
        )
    }

    suspend fun renameThread(threadId: String, title: String) {
        val thread = dao.getThread(threadId) ?: return
        dao.upsertThread(
            thread.copy(
                title = title.ifBlank { DEFAULT_THREAD_TITLE },
                updatedAt = System.currentTimeMillis(),
            )
        )
    }

    suspend fun touchThread(threadId: String) {
        val thread = dao.getThread(threadId) ?: return
        dao.upsertThread(thread.copy(updatedAt = System.currentTimeMillis()))
    }

    suspend fun closeThread(threadId: String): ChatThreadEntity {
        dao.clearThread(threadId)
        dao.deleteThread(threadId)
        return dao.latestThread() ?: createThread(defaultModelId = null)
    }

    suspend fun appendUser(threadId: String, content: String): String {
        val id = UUID.randomUUID().toString()
        dao.upsert(
            ChatMessageEntity(
                id = id,
                threadId = threadId,
                role = "user",
                content = content,
                timestamp = System.currentTimeMillis(),
            )
        )
        touchThread(threadId)
        return id
    }

    suspend fun appendAssistant(
        threadId: String,
        content: String,
        tokenCount: Int?,
        tokenEstimated: Boolean,
    ): String {
        val id = UUID.randomUUID().toString()
        dao.upsert(
            ChatMessageEntity(
                id = id,
                threadId = threadId,
                role = "assistant",
                content = content,
                timestamp = System.currentTimeMillis(),
                tokenCount = tokenCount,
                tokenEstimated = tokenEstimated,
            )
        )
        touchThread(threadId)
        return id
    }

    suspend fun startAssistant(threadId: String): String {
        val id = UUID.randomUUID().toString()
        dao.upsert(
            ChatMessageEntity(
                id = id,
                threadId = threadId,
                role = "assistant",
                content = "",
                timestamp = System.currentTimeMillis(),
                streaming = true,
            )
        )
        touchThread(threadId)
        return id
    }

    suspend fun appendAssistantDelta(
        messageId: String,
        newContent: String,
        tokenCount: Int?,
        tokenEstimated: Boolean,
    ) {
        dao.updateContent(messageId, newContent, streaming = true)
        dao.updateUsage(messageId, tokenCount, tokenEstimated)
    }

    suspend fun finishAssistant(
        messageId: String,
        finalContent: String,
        tokenCount: Int?,
        tokenEstimated: Boolean,
    ) {
        dao.updateContent(messageId, finalContent, streaming = false)
        dao.updateUsage(messageId, tokenCount, tokenEstimated)
    }

    suspend fun updateMessageUsage(messageId: String, tokenCount: Int?, tokenEstimated: Boolean) {
        dao.updateUsage(messageId, tokenCount, tokenEstimated)
    }

    suspend fun clearThread(threadId: String) = dao.clearThread(threadId)

    suspend fun deleteMessage(messageId: String) = dao.deleteMessage(messageId)

    companion object {
        const val DEFAULT_THREAD_TITLE = "New thread"
    }
}
