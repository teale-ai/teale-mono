package com.teale.android.ui.chat

import com.teale.android.data.inference.ChatMessage
import kotlin.math.ceil

fun estimateChatTextTokens(text: String): Int {
    if (text.isBlank()) {
        return 0
    }
    return maxOf(1, ceil(text.toByteArray(Charsets.UTF_8).size / 4.0).toInt())
}

fun estimateChatPromptTokens(messages: List<ChatMessage>): Int {
    val promptBytes = messages.sumOf { it.content.toByteArray(Charsets.UTF_8).size }
    return ceil(promptBytes / 4.0).toInt() + 16
}

fun normalizeThreadTitle(text: String): String {
    val singleLine = text.trim().lineSequence().firstOrNull().orEmpty()
    return when {
        singleLine.isBlank() -> "New thread"
        singleLine.length <= 28 -> singleLine
        else -> singleLine.take(28).trimEnd() + "…"
    }
}
