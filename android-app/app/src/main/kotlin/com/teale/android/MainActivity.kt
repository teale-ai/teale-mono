package com.teale.android

import android.os.Bundle
import android.util.Log
import androidx.activity.compose.setContent
import androidx.appcompat.app.AppCompatActivity
import androidx.compose.material3.Surface
import androidx.core.view.WindowCompat
import androidx.lifecycle.lifecycleScope
import com.teale.android.ui.TealeNavHost
import com.teale.android.ui.theme.TealeTheme
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)

        // Kick off identity + token exchange + wallet refresh eagerly.
        val container = (application as TealeApplication).container
        lifecycleScope.launch {
            runCatching {
                Log.i("Teale", "deviceID=${container.identity.deviceId()}")
                val token = container.tokenClient.bearer()
                Log.i("Teale", "token exchanged: ${token.take(16)}…")
                container.walletRepository.refresh()
            }.onFailure { Log.w("Teale", "initial bootstrap: ${it.message}") }
        }

        setContent {
            TealeTheme { Surface { TealeNavHost() } }
        }
    }
}
