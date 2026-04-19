package com.teale.android.service

import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.teale.android.TealeApplication
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

/** Quick Settings tile that mirrors the supply toggle. */
class SupplyTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        refresh()
    }

    override fun onClick() {
        super.onClick()
        val app = TealeApplication.instance
        CoroutineScope(Dispatchers.IO).launch {
            val current = app.container.settingsStore.snapshot.first().supplyEnabled
            val next = !current
            app.container.settingsStore.setSupplyEnabled(next)
            SupplyService.toggle(applicationContext, next)
            refreshOnUi()
        }
    }

    private fun refresh() {
        val app = TealeApplication.instance
        val enabled = runBlocking { app.container.settingsStore.snapshot.first().supplyEnabled }
        qsTile?.state = if (enabled) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        qsTile?.updateTile()
    }

    private fun refreshOnUi() {
        qsTile ?: return
        refresh()
    }
}
