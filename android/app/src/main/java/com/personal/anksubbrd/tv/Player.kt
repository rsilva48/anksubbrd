@file:OptIn(ExperimentalTvMaterial3Api::class)

package com.personal.anksubbrd.tv

import android.view.KeyEvent
import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn as AndroidXOptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import androidx.tv.material3.Button
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Text
import java.util.Locale
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Full-screen Media3 player. Its controller handles the remote (center
 * shows the controls; the gear selects subtitles, audio and speed); with
 * the controls hidden, left/right seek 10 s.
 */
@AndroidXOptIn(UnstableApi::class)
@Composable
fun PlayerScreen(session: Session, initial: PlaybackRequest, onExit: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var request by remember { mutableStateOf(initial) }
    var error by remember { mutableStateOf<String?>(null) }
    var changing by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    val player = remember { ExoPlayer.Builder(context).setSeekBackIncrementMs(10_000).setSeekForwardIncrementMs(10_000).build() }

    fun entry(completed: Boolean? = null): HistoryEntry? {
        val position = player.currentPosition / 1000.0
        if (position <= 0) return null
        val duration = player.duration.takeIf { it != C.TIME_UNSET && it > 0 }?.let { it / 1000.0 }
        return HistoryEntry(
            seriesTitle = request.series.title,
            watchUrl = request.anime.watchUrl,
            imageUrl = request.anime.imageUrl ?: request.series.imageUrl,
            episode = request.episode.number,
            episodeTitle = request.episode.title,
            serverName = request.playback.serverName,
            positionSeconds = position,
            updatedAt = HistoryEntry.now(),
            titleJp = request.series.titleJp ?: request.anime.titleJp,
            serverKind = request.kind,
            durationSeconds = duration,
            completed = completed ?: reachedEnd(position, duration, request.playback.outro),
            totalEpisodes = request.series.totalEpisodes,
        )
    }

    fun save(completed: Boolean? = null) {
        val value = entry(completed) ?: return
        scope.launch { session.record(value) }
    }

    fun open(episode: Episode) {
        if (changing != null) return
        save()
        changing = "Abriendo el episodio ${episode.number}…"
        scope.launch {
            try {
                request = session.resolve(request.anime, request.series, episode, request.kind, request.playback.serverName)
                error = null
            } catch (failure: BridgeException) {
                error = "No se pudo abrir el episodio ${episode.number}. ${failure.message}"
            } finally {
                changing = null
            }
        }
    }

    // Loads each episode: Sub turns subtitles on (the configured language,
    // the device language or English); Dub leaves them to the stream.
    LaunchedEffect(request, attempt) {
        val preferences = session.preferences
        val subtitleLanguage = preferences.subtitleLanguage.takeUnless { it.isEmpty() || it == "off" } ?: Locale.getDefault().language
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, request.kind == "sub" && preferences.subtitleLanguage == "off")
            .setPreferredTextLanguages(*(if (request.kind == "sub") arrayOf(subtitleLanguage, "en") else emptyArray()))
            .setSelectUndeterminedTextLanguage(request.kind == "sub")
            .build()
        val start = session.position(request.anime.watchUrl, request.episode.number)
        player.setMediaItem(MediaItem.fromUri(request.playback.playbackUrl), (start * 1000).toLong())
        player.prepare()
        player.playWhenReady = true
    }

    // Progress every 10 s; automatic intro/outro skipping every second.
    LaunchedEffect(request) {
        var ticks = 0
        while (true) {
            delay(1000)
            val position = player.currentPosition / 1000.0
            val preferences = session.preferences
            request.playback.intro?.takeIf { preferences.autoSkipIntro && position >= it.start && position < it.end }?.let { player.seekTo((it.end * 1000).toLong()) }
            request.playback.outro?.takeIf { preferences.autoSkipOutro && position >= it.start && position < it.end }?.let { player.seekTo((it.end * 1000).toLong()) }
            if (++ticks % 10 == 0 && player.isPlaying) save()
        }
    }

    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (state != Player.STATE_ENDED) return
                save(completed = true)
                val next = request.series.episodeAfter(request.episode.number, request.kind)
                if (next != null && session.preferences.autoNext) open(next) else if (next == null) onExit()
            }

            override fun onPlayerError(failure: PlaybackException) {
                error = if (Connectivity.isOnline) "No se pudo reproducir este servidor (${failure.errorCodeName})." else "Sin conexión a internet."
            }
        }
        player.addListener(listener)
        onDispose {
            save()
            player.removeListener(listener)
            player.release()
        }
    }

    BackHandler { onExit() }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            factory = { viewContext ->
                PlayerView(viewContext).apply {
                    this.player = player
                    useController = true
                    setShowSubtitleButton(true)
                    // The player holds one episode; episodes change from the series.
                    setShowNextButton(false)
                    setShowPreviousButton(false)
                    keepScreenOn = true
                    // Left/right seek while the controls are hidden.
                    setOnKeyListener { _, keyCode, event ->
                        if (event.action != KeyEvent.ACTION_DOWN || isControllerFullyVisible) return@setOnKeyListener false
                        when (keyCode) {
                            KeyEvent.KEYCODE_DPAD_LEFT -> { player.seekBack(); true }
                            KeyEvent.KEYCODE_DPAD_RIGHT -> { player.seekForward(); true }
                            else -> false
                        }
                    }
                    requestFocus()
                }
            },
            modifier = Modifier.fillMaxSize(),
        )

        changing?.let {
            Text(it, modifier = Modifier.align(Alignment.Center).background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(12.dp)).padding(24.dp))
        }

        error?.let { message ->
            Column(
                modifier = Modifier.align(Alignment.Center).background(Color(0xEE1F1F2E), RoundedCornerShape(20.dp)).padding(32.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(message, style = MaterialTheme.typography.titleMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Button(onClick = { error = null; attempt++ }) { Text("Reintentar") }
                    request.series.episodeAfter(request.episode.number, request.kind)?.let { next ->
                        OutlinedButton(onClick = { error = null; open(next) }) { Text("Episodio ${next.number}") }
                    }
                    OutlinedButton(onClick = onExit) { Text("Salir") }
                }
            }
        }
    }
}

/** Watched once the outro starts or within the last stretch of the episode. */
private fun reachedEnd(position: Double, duration: Double?, outro: SkipRange?): Boolean {
    if (outro != null && outro.start > 60 && position >= outro.start) return true
    if (duration == null || duration <= 0) return false
    return position >= duration - minOf(120.0, duration * 0.1)
}
