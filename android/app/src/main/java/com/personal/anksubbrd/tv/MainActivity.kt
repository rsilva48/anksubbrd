@file:OptIn(ExperimentalTvMaterial3Api::class)

package com.personal.anksubbrd.tv

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.LocalContentColor
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.darkColorScheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Connectivity.start(applicationContext)
        val state = AppState(applicationContext)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme(primary = Color(0xFF818CF8), secondary = Color(0xFF6366F1))) {
                // Text inherits white; screens have no Surface to provide it.
                CompositionLocalProvider(LocalContentColor provides Color.White) {
                    Box(Modifier.fillMaxSize().background(Color(0xFF0B0B12))) {
                        App(state)
                    }
                }
            }
        }
    }
}

sealed interface Route {
    data object Setup : Route
    data object Profiles : Route
    data object Pairing : Route
    data object Home : Route
    data class Details(val anime: Anime) : Route
    data class Watch(val request: PlaybackRequest) : Route
}

@Composable
private fun App(state: AppState) {
    val stack = remember {
        mutableStateListOf<Route>(
            when {
                state.bridgeUrl == null -> Route.Setup
                state.profiles.isEmpty() -> Route.Pairing
                state.profiles.size == 1 || state.activeProfile != null -> Route.Home
                else -> Route.Profiles
            },
        )
    }
    // One session per profile: its preferences and its watch history.
    val profile = state.activeProfile ?: state.profiles.singleOrNull()
    val session = remember(profile) { profile?.let { Session(it, state.client(it)) } }

    fun push(route: Route) = stack.add(route)
    fun reset(vararg routes: Route) {
        stack.clear()
        stack.addAll(routes)
    }

    BackHandler(enabled = stack.size > 1) { stack.removeAt(stack.lastIndex) }

    when (val route = stack.last()) {
        Route.Setup -> SetupScreen(state) { reset(if (state.profiles.isEmpty()) Route.Pairing else Route.Profiles) }
        Route.Profiles -> ProfilesScreen(
            state = state,
            onSelect = {
                state.selectProfile(it)
                reset(Route.Profiles, Route.Home)
            },
            onAdd = { push(Route.Pairing) },
            onChangeBridge = { push(Route.Setup) },
        )
        Route.Pairing -> PairingScreen(
            state = state,
            onPaired = { reset(Route.Profiles, Route.Home) },
            onChangeBridge = { push(Route.Setup) },
        )
        Route.Home -> session?.let { current ->
            HomeScreen(
                session = current,
                onOpen = { push(Route.Details(it)) },
                onSwitchProfile = {
                    state.selectProfile(null)
                    reset(Route.Profiles)
                },
            )
        } ?: LaunchedEffect(Unit) { reset(Route.Profiles) }
        is Route.Details -> session?.let { current ->
            DetailsScreen(session = current, anime = route.anime, onPlay = { push(Route.Watch(it)) })
        }
        is Route.Watch -> session?.let { current ->
            PlayerScreen(session = current, initial = route.request, onExit = { stack.removeAt(stack.lastIndex) })
        }
    }
}
