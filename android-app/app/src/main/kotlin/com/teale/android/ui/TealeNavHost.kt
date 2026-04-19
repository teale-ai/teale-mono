package com.teale.android.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Chat
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.AccountBalanceWallet
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.teale.android.R
import com.teale.android.ui.chat.ChatScreen
import com.teale.android.ui.groups.GroupChatScreen
import com.teale.android.ui.groups.GroupsListScreen
import com.teale.android.ui.settings.SettingsScreen
import com.teale.android.ui.wallet.WalletScreen

enum class Tab(val route: String, @StringRes val labelRes: Int, val icon: ImageVector) {
    Chats("chats", R.string.tab_chats, Icons.Filled.Chat),
    Groups("groups", R.string.tab_groups, Icons.Filled.Groups),
    Wallet("wallet", R.string.tab_wallet, Icons.Filled.AccountBalanceWallet),
    Settings("settings", R.string.tab_settings, Icons.Filled.Settings),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TealeNavHost() {
    val navController = rememberNavController()
    val backStack by navController.currentBackStackEntryAsState()
    val currentRoute = backStack?.destination?.route
    val inTopLevelRoute = Tab.values().any { it.route == currentRoute }

    Scaffold(
        topBar = {
            if (inTopLevelRoute) {
                val titleRes = when (currentRoute) {
                    Tab.Chats.route -> R.string.app_name
                    Tab.Groups.route -> R.string.tab_groups
                    Tab.Wallet.route -> R.string.tab_wallet
                    Tab.Settings.route -> R.string.tab_settings
                    else -> R.string.app_name
                }
                TopAppBar(
                    title = {
                        Text(
                            stringResource(titleRes),
                            style = MaterialTheme.typography.titleMedium,
                        )
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = MaterialTheme.colorScheme.surface,
                    )
                )
            }
        },
        bottomBar = {
            if (inTopLevelRoute) {
                NavigationBar {
                    Tab.values().forEach { tab ->
                        val label = stringResource(tab.labelRes)
                        NavigationBarItem(
                            selected = backStack?.destination?.hierarchy
                                ?.any { it.route == tab.route } == true,
                            onClick = {
                                navController.navigate(tab.route) {
                                    popUpTo(navController.graph.findStartDestination().id) {
                                        saveState = true
                                    }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            },
                            icon = { Icon(tab.icon, contentDescription = label) },
                            label = { Text(label) },
                        )
                    }
                }
            }
        }
    ) { padding ->
        NavHost(
            navController = navController,
            startDestination = Tab.Chats.route,
            modifier = Modifier.padding(padding),
        ) {
            composable(Tab.Chats.route) { ChatScreen() }
            composable(Tab.Groups.route) {
                GroupsListScreen(onOpenGroup = { id -> navController.navigate("group/$id") })
            }
            composable(
                "group/{groupId}",
                arguments = listOf(navArgument("groupId") { type = NavType.StringType }),
            ) { entry ->
                val id = entry.arguments?.getString("groupId") ?: return@composable
                GroupChatScreen(groupId = id, onBack = { navController.popBackStack() })
            }
            composable(Tab.Wallet.route) { WalletScreen() }
            composable(Tab.Settings.route) { SettingsScreen() }
        }
    }
}
