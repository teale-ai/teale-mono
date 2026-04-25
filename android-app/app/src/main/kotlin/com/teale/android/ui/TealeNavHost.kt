package com.teale.android.ui

import androidx.annotation.StringRes
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountBalanceWallet
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.TaskAlt
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.res.stringResource
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.teale.android.R
import com.teale.android.ui.chat.ChatScreen
import com.teale.android.ui.settings.SettingsScreen
import com.teale.android.ui.tasks.TasksScreen
import com.teale.android.ui.wallet.WalletScreen

enum class Tab(val route: String, @StringRes val labelRes: Int, val icon: ImageVector) {
    Home("home", R.string.tab_home, Icons.Filled.Home),
    Tasks("tasks", R.string.tab_tasks, Icons.Filled.TaskAlt),
    Wallet("wallet", R.string.tab_wallet, Icons.Filled.AccountBalanceWallet),
    Account("account", R.string.tab_account, Icons.Filled.Person),
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
                    Tab.Home.route -> R.string.tab_home
                    Tab.Tasks.route -> R.string.tab_tasks
                    Tab.Wallet.route -> R.string.tab_wallet
                    Tab.Account.route -> R.string.tab_account
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
            startDestination = Tab.Home.route,
            modifier = Modifier.padding(padding),
        ) {
            composable(Tab.Home.route) { ChatScreen() }
            composable(Tab.Tasks.route) { TasksScreen() }
            composable(Tab.Wallet.route) { WalletScreen() }
            composable(Tab.Account.route) { SettingsScreen() }
        }
    }
}
