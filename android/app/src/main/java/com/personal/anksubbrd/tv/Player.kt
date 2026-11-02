@file:OptIn(ExperimentalTvMaterial3Api::class)

package com.personal.anksubbrd.tv

import android.view.KeyEvent
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
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
    var skip by remember { mutableStateOf<Pair<String, SkipRange>?>(null) }
    var consumeConfirmKeyUp by remember { mutableStateOf(false) }
    var playerView by remember { mutableStateOf<PlayerView?>(null) }
    /** "−10 s · 01:38" after seeking with the controls hidden. */
    var seekNotice by remember { mutableStateOf<String?>(null) }
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

    fun open(episode: Episode, saveCurrent: Boolean = true) {
        if (changing != null) return
        if (saveCurrent) save()
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
        playerView?.hideController()
    }

    // Commands from the phone's remote control.
    LaunchedEffect(Unit) {
        Remote.playerCommands.collect { command ->
            when (command.type) {
                "pause" -> player.pause()
                "resume" -> player.play()
                "toggle" -> if (player.isPlaying) player.pause() else player.play()
                "seek" -> when {
                    command.position != null -> player.seekTo((command.position * 1000).toLong().coerceAtLeast(0))
                    command.seconds != null -> player.seekTo((player.currentPosition + command.seconds * 1000).toLong().coerceAtLeast(0))
                }
                "skip" -> skip?.second?.let { range ->
                    player.seekTo((range.end * 1000).toLong())
                    skip = null
                }
                "next" -> request.series.episodeAfter(request.episode.number, request.kind)?.let { open(it) }
                "previous" -> request.series.episodeBefore(request.episode.number)?.let { open(it) }
                "stop" -> onExit()
            }
        }
    }

    // Progress every 10 s; automatic intro/outro skipping every second.
    LaunchedEffect(request) {
        skip = null
        var ticks = 0
        while (true) {
            delay(1000)
            val position = player.currentPosition / 1000.0
            val preferences = session.preferences
            request.playback.intro?.takeIf { preferences.autoSkipIntro && position >= it.start && position < it.end }?.let { player.seekTo((it.end * 1000).toLong()) }
            request.playback.outro?.takeIf { preferences.autoSkipOutro && position >= it.start && position < it.end }?.let { player.seekTo((it.end * 1000).toLong()) }
            skip = request.playback.intro?.takeIf { !preferences.autoSkipIntro && position >= it.start && position < it.end }?.let { "Saltar intro" to it }
                ?: request.playback.outro?.takeIf { !preferences.autoSkipOutro && position >= it.start && position < it.end }?.let { "Saltar outro" to it }
            if (++ticks % 10 == 0 && player.isPlaying) save()
            Remote.state.value = DeviceState(
                status = when {
                    player.isPlaying -> "playing"
                    player.playbackState == Player.STATE_BUFFERING || changing != null -> "loading"
                    else -> "paused"
                },
                watchUrl = request.anime.watchUrl,
                seriesTitle = request.series.title,
                titleJp = request.series.titleJp ?: request.anime.titleJp,
                imageUrl = request.anime.imageUrl ?: request.series.imageUrl,
                episode = request.episode.number,
                episodeTitle = request.episode.subtitle,
                kind = request.kind,
                position = player.currentPosition / 1000.0,
                duration = player.duration.takeIf { it != C.TIME_UNSET && it > 0 }?.let { it / 1000.0 },
                skip = skip?.first,
            )
        }
    }

    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (state != Player.STATE_ENDED || changing != null) return
                save(completed = true)
                val next = request.series.episodeAfter(request.episode.number, request.kind)
                if (next != null && session.preferences.autoNext) open(next, saveCurrent = false) else if (next == null) onExit()
            }

            // Paused, the controls stay on screen (OK then resumes from the
            // focused play button); playing, they hide after a few seconds.
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                val view = playerView ?: return
                if (isPlaying) {
                    view.controllerShowTimeoutMs = 4000
                    if (view.isControllerFullyVisible) view.showController()
                } else if (player.playbackState == Player.STATE_READY && !player.playWhenReady) {
                    view.controllerShowTimeoutMs = 0
                    view.showController()
                }
            }

            override fun onPlayerError(failure: PlaybackException) {
                error = if (Connectivity.isOnline) "No se pudo reproducir este servidor (${failure.errorCodeName})." else "Sin conexión a internet."
            }
        }
        player.addListener(listener)
        onDispose {
            Remote.state.value = DeviceState()
            save()
            player.removeListener(listener)
            player.release()
        }
    }

    // Back hides the controls first; a second Back leaves the player.
    BackHandler {
        val view = playerView
        if (view != null && view.isControllerFullyVisible) view.hideController() else onExit()
    }

    /**
     * Remote keys. The PlayerView lives inside Compose, which does not hand
     * it focus by itself: with no focused control, OK went nowhere and the
     * first arrow landed on "rewind". So the play/pause button is focused
     * explicitly whenever the controls show, and keys reach the PlayerView
     * directly. With the controls hidden, OK skips the intro/outro when that
     * is offered, otherwise it pauses and shows the controls.
     */
    fun handleKey(event: KeyEvent): Boolean {
        val view = playerView ?: return false
        if (error != null || changing != null) return false
        val isConfirm = event.keyCode == KeyEvent.KEYCODE_DPAD_CENTER || event.keyCode == KeyEvent.KEYCODE_ENTER || event.keyCode == KeyEvent.KEYCODE_NUMPAD_ENTER
        if (isConfirm && event.action == KeyEvent.ACTION_UP && consumeConfirmKeyUp) {
            consumeConfirmKeyUp = false
            return true
        }
        if (isConfirm && event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) consumeConfirmKeyUp = false
        if (isConfirm && event.action == KeyEvent.ACTION_DOWN && !view.isControllerFullyVisible) {
            if (event.repeatCount > 0) return true
            consumeConfirmKeyUp = true
            val available = skip
            val position = player.currentPosition / 1000.0
            if (available != null && position >= available.second.start && position < available.second.end) {
                player.seekTo((available.second.end * 1000).toLong())
                skip = null
            } else {
                player.pause()
                view.showController()
                focusPlayPause(view)
            }
            return true
        }
        // Left/right with the controls hidden seek 10 s (PlayerView would only
        // show the controls), with a short notice of the new position.
        val isSeek = event.keyCode == KeyEvent.KEYCODE_DPAD_LEFT || event.keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
        if (isSeek && !view.isControllerFullyVisible) {
            if (event.action == KeyEvent.ACTION_DOWN) {
                val forward = event.keyCode == KeyEvent.KEYCODE_DPAD_RIGHT
                if (forward) player.seekForward() else player.seekBack()
                seekNotice = "${if (forward) "+" else "−"}10 s · ${formatTime(player.currentPosition / 1000.0)}"
            }
            return true
        }
        // Controls visible: keep a control focused so OK and the arrows act on it.
        if (view.isControllerFullyVisible && view.findFocus() == null) focusPlayPause(view)
        return false
    }

    DisposableEffect(context) {
        val activity = context as? MainActivity
        val handler: (KeyEvent) -> Boolean = { handleKey(it) }
        activity?.playerKeyHandler = handler
        onDispose { if (activity?.playerKeyHandler === handler) activity.playerKeyHandler = null }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            factory = { viewContext ->
                PlayerView(viewContext).apply {
                    playerView = this
                    this.player = player
                    useController = true
                    setControllerAutoShow(false)
                    setShowSubtitleButton(true)
                    // The player holds one episode; episodes change from the series.
                    setShowNextButton(false)
                    setShowPreviousButton(false)
                    keepScreenOn = true
                    // A control owned by PlayerView stays visible independently of
                    // the controller's auto-hide state and never steals D-pad focus.
                    val density = resources.displayMetrics.density
                    val skipControl = android.widget.Button(viewContext).apply {
                        tag = "skip-control"
                        visibility = View.GONE
                        isFocusable = false
                        isFocusableInTouchMode = false
                        setOnClickListener {
                            skip?.second?.let { range ->
                                player.seekTo((range.end * 1000).toLong())
                                skip = null
                            }
                        }
                    }
                    addView(skipControl, FrameLayout.LayoutParams(
                        FrameLayout.LayoutParams.WRAP_CONTENT,
                        FrameLayout.LayoutParams.WRAP_CONTENT,
                        Gravity.BOTTOM or Gravity.END,
                    ).apply {
                        marginEnd = (48 * density).toInt()
                        bottomMargin = (96 * density).toInt()
                    })
                    // The play/pause button gets the focus every time the controls show.
                    setControllerVisibilityListener(PlayerView.ControllerVisibilityListener { visibility ->
                        if (visibility == View.VISIBLE) focusPlayPause(this) else requestFocus()
                    })
                    hideController()
                    post { requestFocus() }
                }
            },
            modifier = Modifier.fillMaxSize(),
            update = { view ->
                view.findViewWithTag<android.widget.Button>("skip-control")?.apply {
                    val available = skip
                    text = available?.let { "OK · ${it.first}" }.orEmpty()
                    visibility = if (available != null && error == null && changing == null) View.VISIBLE else View.GONE
                    if (visibility == View.VISIBLE) bringToFront()
                }
            },
        )

        seekNotice?.let { notice ->
            LaunchedEffect(notice) {
                delay(2000)
                seekNotice = null
            }
            Text(notice, modifier = Modifier.align(Alignment.TopCenter).padding(top = 48.dp).background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(12.dp)).padding(horizontal = 20.dp, vertical = 10.dp))
        }

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

/** Moves the focus to the play/pause button once the controls are laid out. */
@AndroidXOptIn(UnstableApi::class)
private fun focusPlayPause(view: PlayerView) {
    view.post { view.findViewById<View>(androidx.media3.ui.R.id.exo_play_pause)?.requestFocus() }
}

/** Watched once the outro starts or within the last stretch of the episode. */
private fun reachedEnd(position: Double, duration: Double?, outro: SkipRange?): Boolean {
    if (outro != null && outro.start > 60 && position >= outro.start) return true
    if (duration == null || duration <= 0) return false
    return position >= duration - minOf(120.0, duration * 0.1)
}
