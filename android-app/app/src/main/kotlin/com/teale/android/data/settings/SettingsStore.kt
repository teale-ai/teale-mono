package com.teale.android.data.settings

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.dataStore by preferencesDataStore(name = "teale_settings")

class SettingsStore(private val context: Context) {

    data class Snapshot(
        val username: String,
        val phone: String,
        val supplyEnabled: Boolean,
        val preferredModel: String,
    )

    val snapshot: Flow<Snapshot> = context.dataStore.data.map { prefs ->
        Snapshot(
            username = prefs[KEY_USERNAME].orEmpty(),
            phone = prefs[KEY_PHONE].orEmpty(),
            supplyEnabled = prefs[KEY_SUPPLY] ?: false,
            preferredModel = prefs[KEY_MODEL] ?: DEFAULT_MODEL,
        )
    }

    suspend fun setUsername(v: String) = context.dataStore.edit { it[KEY_USERNAME] = v }
    suspend fun setPhone(v: String) = context.dataStore.edit { it[KEY_PHONE] = v }
    suspend fun setSupplyEnabled(v: Boolean) = context.dataStore.edit { it[KEY_SUPPLY] = v }
    suspend fun setPreferredModel(v: String) = context.dataStore.edit { it[KEY_MODEL] = v }

    companion object {
        const val DEFAULT_MODEL = "nousresearch/hermes-3-llama-3.1-8b"
        private val KEY_USERNAME = stringPreferencesKey("username")
        private val KEY_PHONE = stringPreferencesKey("phone")
        private val KEY_SUPPLY = booleanPreferencesKey("supply_enabled")
        private val KEY_MODEL = stringPreferencesKey("preferred_model")
    }
}
