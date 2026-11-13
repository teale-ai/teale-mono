package com.teale.android.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.teale.android.TealeApplication
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Restarts supply after a reboot or an app update when the user left it
 * enabled. The service itself still applies the charging / thermal gates.
 */
class SupplyBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val enabled = TealeApplication.instance.container.settingsStore
                    .snapshot.first().supplyEnabled
                if (enabled) {
                    Log.i(TAG, "supply enabled; starting after ${intent.action}")
                    SupplyService.toggle(context.applicationContext, true)
                }
            } catch (t: Exception) {
                Log.w(TAG, "could not restart supply: ${t.message}")
            } finally {
                pending.finish()
            }
        }
    }

    private companion object {
        const val TAG = "SupplyBootReceiver"
    }
}
