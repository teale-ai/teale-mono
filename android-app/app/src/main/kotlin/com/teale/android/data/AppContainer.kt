package com.teale.android.data

import android.content.Context
import com.teale.android.BuildConfig
import com.teale.android.data.auth.TokenExchangeClient
import com.teale.android.data.auth.UsernameClient
import com.teale.android.data.chat.ChatDatabase
import com.teale.android.data.chat.ChatRepository
import com.teale.android.data.groups.GroupRepository
import com.teale.android.data.identity.KeyStorage
import com.teale.android.data.identity.WanIdentity
import com.teale.android.data.inference.GatewayClient
import com.teale.android.data.settings.SettingsStore
import com.teale.android.data.wallet.WalletRepository

/**
 * Hand-wired DI container. Not using Hilt for MVP simplicity — every
 * screen grabs its dependencies from `TealeApplication.instance.container`.
 */
class AppContainer(private val app: Context) {
    val keyStorage: KeyStorage = KeyStorage(app)
    val identity: WanIdentity = WanIdentity(keyStorage)
    val settingsStore: SettingsStore = SettingsStore(app)

    val tokenClient: TokenExchangeClient = TokenExchangeClient(
        baseUrl = BuildConfig.GATEWAY_BASE_URL,
        identity = identity,
    )

    val usernameClient: UsernameClient = UsernameClient(
        baseUrl = BuildConfig.GATEWAY_BASE_URL,
        tokenClient = tokenClient,
    )

    val gatewayClient: GatewayClient = GatewayClient(
        baseUrl = BuildConfig.GATEWAY_BASE_URL,
        tokenClient = tokenClient,
    )

    val walletRepository: WalletRepository = WalletRepository(
        baseUrl = BuildConfig.GATEWAY_BASE_URL,
        tokenClient = tokenClient,
    )

    val chatDatabase: ChatDatabase = ChatDatabase.create(app)
    val chatRepository: ChatRepository = ChatRepository(chatDatabase.chatDao())

    val groupRepository: GroupRepository = GroupRepository(
        baseUrl = BuildConfig.GATEWAY_BASE_URL,
        tokenClient = tokenClient,
    )
}
