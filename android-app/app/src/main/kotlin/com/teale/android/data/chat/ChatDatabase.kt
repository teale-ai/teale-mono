package com.teale.android.data.chat

import android.content.Context
import androidx.room.ColumnInfo
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Dao
import androidx.room.Insert
import androidx.room.PrimaryKey
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import kotlinx.coroutines.flow.Flow

@Entity(tableName = "chat_threads")
data class ChatThreadEntity(
    @PrimaryKey val id: String,
    val title: String,
    val selectedModelId: String? = null,
    val updatedAt: Long,
    val createdAt: Long,
)

@Entity(tableName = "chat_messages")
data class ChatMessageEntity(
    @PrimaryKey val id: String,
    @ColumnInfo(index = true) val threadId: String,
    val role: String,          // "user" | "assistant" | "system"
    val content: String,
    val timestamp: Long,
    val streaming: Boolean = false,
    val tokenCount: Int? = null,
    val tokenEstimated: Boolean = false,
)

@Entity(tableName = "automation_tasks")
data class AutomationTaskEntity(
    @PrimaryKey val id: String,
    val kind: String,
    val title: String,
    val description: String,
    val scheduleMinutes: Long,
    val requiresCharging: Boolean,
    val requiresUnmeteredNetwork: Boolean,
    val enabled: Boolean,
    val readiness: String,
    val lastRunAt: Long? = null,
    val lastRunStatus: String? = null,
    val lastRunSummary: String? = null,
)

@Dao
interface ChatDao {
    @Query("SELECT * FROM chat_threads ORDER BY updatedAt DESC")
    fun observeThreads(): Flow<List<ChatThreadEntity>>

    @Query("SELECT * FROM chat_messages WHERE threadId = :threadId ORDER BY timestamp ASC")
    fun observeMessages(threadId: String): Flow<List<ChatMessageEntity>>

    @Query("SELECT * FROM chat_messages WHERE threadId = :threadId ORDER BY timestamp ASC")
    suspend fun listMessages(threadId: String): List<ChatMessageEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(message: ChatMessageEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertThread(thread: ChatThreadEntity)

    @Query("UPDATE chat_messages SET content = :content, streaming = :streaming WHERE id = :id")
    suspend fun updateContent(id: String, content: String, streaming: Boolean)

    @Query("UPDATE chat_messages SET tokenCount = :tokenCount, tokenEstimated = :tokenEstimated WHERE id = :id")
    suspend fun updateUsage(id: String, tokenCount: Int?, tokenEstimated: Boolean)

    @Query("DELETE FROM chat_messages WHERE threadId = :threadId")
    suspend fun clearThread(threadId: String)

    @Query("DELETE FROM chat_messages WHERE id = :messageId")
    suspend fun deleteMessage(messageId: String)

    @Query("DELETE FROM chat_threads WHERE id = :threadId")
    suspend fun deleteThread(threadId: String)

    @Query("SELECT COUNT(*) FROM chat_threads")
    suspend fun threadCount(): Int

    @Query("SELECT * FROM chat_threads ORDER BY updatedAt DESC LIMIT 1")
    suspend fun latestThread(): ChatThreadEntity?

    @Query("SELECT * FROM chat_threads WHERE id = :threadId LIMIT 1")
    suspend fun getThread(threadId: String): ChatThreadEntity?
}

@Dao
interface TaskDao {
    @Query("SELECT * FROM automation_tasks ORDER BY title COLLATE NOCASE ASC")
    fun observeTasks(): Flow<List<AutomationTaskEntity>>

    @Query("SELECT * FROM automation_tasks WHERE id = :taskId LIMIT 1")
    suspend fun getTask(taskId: String): AutomationTaskEntity?

    @Query("SELECT * FROM automation_tasks")
    suspend fun listTasks(): List<AutomationTaskEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertTask(task: AutomationTaskEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertTasks(tasks: List<AutomationTaskEntity>)

    @Query(
        """
        UPDATE automation_tasks
        SET enabled = :enabled,
            scheduleMinutes = :scheduleMinutes,
            requiresCharging = :requiresCharging,
            requiresUnmeteredNetwork = :requiresUnmeteredNetwork
        WHERE id = :taskId
        """
    )
    suspend fun updateSchedule(
        taskId: String,
        enabled: Boolean,
        scheduleMinutes: Long,
        requiresCharging: Boolean,
        requiresUnmeteredNetwork: Boolean,
    )

    @Query(
        """
        UPDATE automation_tasks
        SET lastRunAt = :lastRunAt,
            lastRunStatus = :lastRunStatus,
            lastRunSummary = :lastRunSummary
        WHERE id = :taskId
        """
    )
    suspend fun updateLastRun(
        taskId: String,
        lastRunAt: Long,
        lastRunStatus: String,
        lastRunSummary: String,
    )
}

@Database(
    entities = [ChatThreadEntity::class, ChatMessageEntity::class, AutomationTaskEntity::class],
    version = 2,
    exportSchema = false,
)
abstract class ChatDatabase : RoomDatabase() {
    abstract fun chatDao(): ChatDao
    abstract fun taskDao(): TaskDao

    companion object {
        private const val DEFAULT_THREAD_ID = "default"

        private val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS `chat_threads` (
                        `id` TEXT NOT NULL,
                        `title` TEXT NOT NULL,
                        `selectedModelId` TEXT,
                        `updatedAt` INTEGER NOT NULL,
                        `createdAt` INTEGER NOT NULL,
                        PRIMARY KEY(`id`)
                    )
                    """.trimIndent()
                )
                db.execSQL("ALTER TABLE `chat_messages` RENAME TO `chat_messages_old`")
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS `chat_messages` (
                        `id` TEXT NOT NULL,
                        `threadId` TEXT NOT NULL,
                        `role` TEXT NOT NULL,
                        `content` TEXT NOT NULL,
                        `timestamp` INTEGER NOT NULL,
                        `streaming` INTEGER NOT NULL,
                        `tokenCount` INTEGER,
                        `tokenEstimated` INTEGER NOT NULL DEFAULT 0,
                        PRIMARY KEY(`id`)
                    )
                    """.trimIndent()
                )
                db.execSQL(
                    """
                    INSERT INTO `chat_messages` (`id`, `threadId`, `role`, `content`, `timestamp`, `streaming`, `tokenCount`, `tokenEstimated`)
                    SELECT `id`, COALESCE(`sessionId`, '$DEFAULT_THREAD_ID'), `role`, `content`, `timestamp`, `streaming`, NULL, 0
                    FROM `chat_messages_old`
                    """.trimIndent()
                )
                db.execSQL("DROP TABLE `chat_messages_old`")
                db.execSQL("CREATE INDEX IF NOT EXISTS `index_chat_messages_threadId` ON `chat_messages` (`threadId`)")
                db.execSQL(
                    """
                    INSERT OR IGNORE INTO `chat_threads` (`id`, `title`, `selectedModelId`, `updatedAt`, `createdAt`)
                    SELECT `threadId`, 'New thread', NULL, MAX(`timestamp`), MIN(`timestamp`)
                    FROM `chat_messages`
                    GROUP BY `threadId`
                    """.trimIndent()
                )
                db.execSQL(
                    """
                    INSERT OR IGNORE INTO `chat_threads` (`id`, `title`, `selectedModelId`, `updatedAt`, `createdAt`)
                    VALUES ('$DEFAULT_THREAD_ID', 'New thread', NULL, 0, 0)
                    """.trimIndent()
                )
                db.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS `automation_tasks` (
                        `id` TEXT NOT NULL,
                        `kind` TEXT NOT NULL,
                        `title` TEXT NOT NULL,
                        `description` TEXT NOT NULL,
                        `scheduleMinutes` INTEGER NOT NULL,
                        `requiresCharging` INTEGER NOT NULL,
                        `requiresUnmeteredNetwork` INTEGER NOT NULL,
                        `enabled` INTEGER NOT NULL,
                        `readiness` TEXT NOT NULL,
                        `lastRunAt` INTEGER,
                        `lastRunStatus` TEXT,
                        `lastRunSummary` TEXT,
                        PRIMARY KEY(`id`)
                    )
                    """.trimIndent()
                )
            }
        }

        fun create(context: Context): ChatDatabase =
            Room.databaseBuilder(context, ChatDatabase::class.java, "teale_chat.db")
                .addMigrations(MIGRATION_1_2)
                .build()
    }
}
