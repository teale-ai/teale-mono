package com.teale.android.ui.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat

// ── Brand palette ────────────────────────────────────────────────────────────
// Primary = #009999. Same teal the mac-app uses (Swift Color.teale).
val TealePrimary = Color(0xFF009999)
val TealePrimaryDark = Color(0xFF007272)
val TealePrimaryLight = Color(0xFF33B3B3)
val TealeAccent = Color(0xFF14B8A6)
val TealeSurfaceLight = Color(0xFFFAFAFA)
val TealeSurfaceDark = Color(0xFF0A0F11)
val TealeOnLightSecondary = Color(0xFF475157)
val TealeOnDarkSecondary = Color(0xFFB8C2C7)

private val LightColors = lightColorScheme(
    primary = TealePrimary,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFCCECEC),
    onPrimaryContainer = TealePrimaryDark,
    secondary = TealePrimaryDark,
    onSecondary = Color.White,
    tertiary = TealeAccent,
    onTertiary = Color.White,
    tertiaryContainer = Color(0xFFD4F4EE),
    onTertiaryContainer = Color(0xFF004F45),
    background = TealeSurfaceLight,
    onBackground = Color(0xFF0F1720),
    surface = Color.White,
    onSurface = Color(0xFF0F1720),
    surfaceVariant = Color(0xFFEDF2F2),
    onSurfaceVariant = TealeOnLightSecondary,
    outline = Color(0xFFC8D1D3),
    outlineVariant = Color(0xFFE2E8E9),
    error = Color(0xFFBA1A1A),
    onError = Color.White,
    errorContainer = Color(0xFFFFDAD6),
    onErrorContainer = Color(0xFF410002),
)

private val DarkColors = darkColorScheme(
    // On dark backgrounds the user asked for teal *text*. We keep the primary
    // saturated enough for ink-on-ink and use the lighter accent as text.
    primary = TealePrimaryLight,
    onPrimary = Color(0xFF00302F),
    primaryContainer = Color(0xFF004D4D),
    onPrimaryContainer = Color(0xFFA8EAEA),
    secondary = TealeAccent,
    onSecondary = Color.Black,
    tertiary = TealeAccent,
    onTertiary = Color.Black,
    tertiaryContainer = Color(0xFF003D33),
    onTertiaryContainer = Color(0xFF9EEDDE),
    background = TealeSurfaceDark,
    onBackground = Color(0xFFE7EDEF),
    surface = Color(0xFF0F1518),
    onSurface = Color(0xFFE7EDEF),
    surfaceVariant = Color(0xFF1C2327),
    onSurfaceVariant = TealeOnDarkSecondary,
    outline = Color(0xFF3A4449),
    outlineVariant = Color(0xFF242A2E),
    error = Color(0xFFFFB4AB),
    onError = Color(0xFF690005),
    errorContainer = Color(0xFF93000A),
    onErrorContainer = Color(0xFFFFDAD6),
)

private val TealeTypography = Typography(
    titleLarge = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.sp),
    titleMedium = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.15.sp),
    titleSmall = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.1.sp),
    bodyLarge = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Normal, lineHeight = 22.sp),
    bodyMedium = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.Normal, lineHeight = 20.sp),
    bodySmall = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Normal, lineHeight = 18.sp),
    labelLarge = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.1.sp),
    labelMedium = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.5.sp),
    labelSmall = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.5.sp),
)

@Composable
fun TealeTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val colors = if (darkTheme) DarkColors else LightColors

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = colors.background.toArgb()
            window.navigationBarColor = colors.background.toArgb()
            val controller = WindowCompat.getInsetsController(window, view)
            controller.isAppearanceLightStatusBars = !darkTheme
            controller.isAppearanceLightNavigationBars = !darkTheme
        }
    }

    MaterialTheme(
        colorScheme = colors,
        typography = TealeTypography,
        content = content,
    )
}
