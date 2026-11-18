package com.teale.android.service

import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.teale.android.TealeApplication
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Quick Settings tile that mirrors the supply toggle.
 *
 * The coroutine scope lives only between onStartListening and
 * onStopListening; DataStore reads happen off the main thread and tile
 * updates on it.
 */
class SupplyTileService : TileService() {

    private var scope: CoroutineScope? = null

    override fun onStartListening() {
        super.onStartListening()
        val listeningScope = MainScope()
        scope?.cancel()
        scope = listeningScope
        listeningScope.launch {
            val enabled = withContext(Dispatchers.IO) { readEnabled() }
            render(enabled)
        }
    }

    override fun onStopListening() {
        scope?.cancel()
        scope = null
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        val listeningScope = scope ?: MainScope().also { scope = it }
        listeningScope.launch {
            // Finish the toggle even if the panel closes mid-way.
            val next = withContext(NonCancellable + Dispatchers.IO) {
                val store = TealeApplication.instance.container.settingsStore
                val toggled = !store.snapshot.first().supplyEnabled
                store.setSupplyEnabled(toggled)
                toggled
            }
            withContext(NonCancellable) { SupplyService.toggle(applicationContext, next) }
            render(next)
        }
    }

    override fun onDestroy() {
        scope?.cancel()
        scope = null
        super.onDestroy()
    }

    private suspend fun readEnabled(): Boolean =
        TealeApplication.instance.container.settingsStore.snapshot.first().supplyEnabled

    private fun render(enabled: Boolean) {
        val tile = qsTile ?: return
        tile.state = if (enabled) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.updateTile()
    }
}
