package com.personal.anksubbrd.tv

import android.app.PictureInPictureParams
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.os.Build
import android.util.Rational
import android.view.View
import androidx.activity.compose.BackHandler
import androidx.annotation.OptIn as AndroidXOptIn
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.app.PictureInPictureModeChangedInfo
import androidx.core.util.Consumer
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionParameters
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.mediacodec.MediaCodecUtil
import androidx.media3.session.MediaSession
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.media3.ui.PlayerView
import java.util.Locale
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The phone player: full screen in landscape, Media3's controls (seek bar,
 * subtitles, audio and speed in its settings) plus the series and episode,
 * previous/next episode of the same kind and the intro/outro skip.
 * Leaving the app while it plays continues in picture-in-picture.
 */
@AndroidXOptIn(UnstableApi::class)
@Composable
internal fun PhonePlayer(session: Session, initial: PlaybackRequest, onExit: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var request by remember { mutableStateOf(initial) }
    var error by remember { mutableStateOf<String?>(null) }
    var changing by remember { mutableStateOf<String?>(null) }
    var attempt by remember { mutableIntStateOf(0) }
    var skip by remember { mutableStateOf<Pair<String, SkipRange>?>(null) }
    var controlsVisible by remember { mutableStateOf(true) }
    /** Set while the app itself changes the track selection (not the viewer). */
    var applyingTracks by remember { mutableStateOf(false) }
    var inPip by remember { mutableStateOf(false) }
    var isPlaying by remember { mutableStateOf(false) }
    // Decoder fallback: if the preferred video decoder fails (some phones), try
    // the next one. Downloaded episodes are read from the app's storage.
    val player = remember {
        val renderers = DefaultRenderersFactory(context).setEnableDecoderFallback(true)
            // The emulator's "goldfish" H.264 decoder fails mid-stream; its software decoder works.
            .setMediaCodecSelector { mimeType, secure, tunneling ->
                MediaCodecUtil.getDecoderInfos(mimeType, secure, tunneling).filterNot { "goldfish" in it.name }
            }
        ExoPlayer.Builder(context, renderers)
            .setMediaSourceFactory(PhoneDownloads.mediaSourceFactory(context))
            .setSeekBackIncrementMs(10_000).setSeekForwardIncrementMs(10_000).build()
    }

    // Play/pause from picture-in-picture, headsets and the system's media controls.
    DisposableEffect(player) {
        val mediaSession = runCatching { MediaSession.Builder(context, player).setId("phone-player").build() }.getOrNull()
        onDispose { mediaSession?.release() }
    }

    // Picture-in-picture when leaving the app while the episode plays; the
    // overlays hide in the small window.
    val activity = remember { context.findActivity() as? MainActivity }
    val pipSupported = remember { context.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE) }
    fun pipParams(auto: Boolean): PictureInPictureParams = PictureInPictureParams.Builder().setAspectRatio(Rational(16, 9))
        .apply { if (Build.VERSION.SDK_INT >= 31) setAutoEnterEnabled(auto).setSeamlessResizeEnabled(true) }.build()
    LaunchedEffect(isPlaying) { if (pipSupported) runCatching { activity?.setPictureInPictureParams(pipParams(isPlaying)) } }
    DisposableEffect(activity) {
        val listener = Consumer<PictureInPictureModeChangedInfo> { inPip = it.isInPictureInPictureMode }
        activity?.addOnPictureInPictureModeChangedListener(listener)
        activity?.phonePip = { if (pipSupported && player.isPlaying) pipParams(false) else null }
        onDispose {
            activity?.removeOnPictureInPictureModeChangedListener(listener)
            activity?.phonePip = null
            if (pipSupported) runCatching { activity?.setPictureInPictureParams(pipParams(false)) }
        }
    }
    // Closing the picture-in-picture window, or locking the phone, pauses.
    LifecycleEventEffect(Lifecycle.Event.ON_STOP) { player.pause() }

    // Landscape, without system bars, while the player is open.
    DisposableEffect(Unit) {
        val activity = context.findActivity()
        val previous = activity?.requestedOrientation
        activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        val insets = activity?.window?.let { WindowCompat.getInsetsController(it, it.decorView) }
        insets?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        insets?.hide(WindowInsetsCompat.Type.systemBars())
        onDispose {
            insets?.show(WindowInsetsCompat.Type.systemBars())
            activity?.requestedOrientation = previous ?: ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
    }

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
        if (value.isCompleted) PhoneDownloads.markWatched(context, value.watchUrl, value.episode)
        // Starts at once so a save on close is not cancelled with the screen.
        scope.launch(start = CoroutineStart.UNDISPATCHED) { session.record(value) }
    }

    fun open(episode: Episode, saveCurrent: Boolean = true) {
        if (changing != null) return
        if (saveCurrent) save()
        // A downloaded episode plays from storage; among downloads the series stays theirs.
        PhoneDownloads.completed(request.anime.watchUrl, episode.number, request.kind)?.let { stored ->
            val local = PhoneDownloads.playback(stored)
            request = if (request.series.seriesKey.isEmpty()) local else local.copy(anime = request.anime, series = request.series)
            error = null
            return
        }
        changing = Strings.get(R.string.opening_episode, episode.number)
        scope.launch {
            try {
                request = session.resolve(request.anime, request.series, episode, request.kind, request.playback.serverName)
                error = null
            } catch (failure: BridgeException) {
                error = Strings.get(R.string.open_episode_failed, episode.number, failure.message.orEmpty())
            } finally {
                changing = null
            }
        }
    }

    val next = request.series.episodeAfter(request.episode.number, request.kind)
    val previous = request.series.episodeBefore(request.episode.number)

    // Sub turns subtitles on (the identity's language, the device's or
    // English); Dub leaves them to the stream.
    LaunchedEffect(request, attempt) {
        val preferences = session.preferences
        val language = preferences.subtitleLanguage.takeUnless { it.isEmpty() || it == "off" } ?: Locale.getDefault().language
        applyingTracks = true
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .clearOverridesOfType(C.TRACK_TYPE_TEXT)
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, request.kind == "sub" && preferences.subtitleLanguage == "off")
            .setPreferredTextLanguages(*(if (request.kind == "sub") arrayOf(language, "en") else emptyArray()))
            .setSelectUndeterminedTextLanguage(request.kind == "sub")
            .build()
        applyingTracks = false
        val start = session.position(request.anime.watchUrl, request.episode.number)
        val item = (if (request.downloaded) PhoneDownloads.mediaItem(request.playback.playbackUrl) else null) ?: MediaItem.fromUri(request.playback.playbackUrl)
        player.setMediaItem(item, (start * 1000).toLong())
        player.prepare()
        player.playWhenReady = true
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
            skip = request.playback.intro?.takeIf { !preferences.autoSkipIntro && position >= it.start && position < it.end }?.let { Strings.get(R.string.skip_intro) to it }
                ?: request.playback.outro?.takeIf { !preferences.autoSkipOutro && position >= it.start && position < it.end }?.let { Strings.get(R.string.skip_outro) to it }
            if (++ticks % 10 == 0 && player.isPlaying) save()
        }
    }

    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (state != Player.STATE_ENDED || changing != null) return
                save(completed = true)
                val following = request.series.episodeAfter(request.episode.number, request.kind)
                if (following != null && session.preferences.autoNext) open(following, saveCurrent = false) else if (following == null) onExit()
            }

            override fun onIsPlayingChanged(playing: Boolean) {
                isPlaying = playing
                if (!playing) save()
            }

            // A subtitle chosen in a Sub episode becomes the identity's
            // preference (the next episodes and other devices follow it).
            override fun onTrackSelectionParametersChanged(parameters: TrackSelectionParameters) {
                if (applyingTracks || request.kind != "sub") return
                val chosen = when {
                    C.TRACK_TYPE_TEXT in parameters.disabledTrackTypes -> "off"
                    else -> player.currentTracks.groups.firstOrNull { it.type == C.TRACK_TYPE_TEXT && it.isSelected }
                        ?.let { group -> (0 until group.length).firstOrNull { group.isTrackSelected(it) }?.let { group.getTrackFormat(it).language } }
                } ?: return
                if (chosen != session.preferences.subtitleLanguage) scope.launch { session.updatePreferences { it.copy(subtitleLanguage = chosen) } }
            }

            override fun onPlayerError(failure: PlaybackException) {
                error = when {
                    failure.errorCode in 4000..4999 -> Strings.get(R.string.decode_failed, failure.errorCodeName)
                    request.downloaded -> Strings.get(R.string.download_open_failed, failure.errorCodeName)
                    Connectivity.isOnline -> Strings.get(R.string.server_failed, failure.errorCodeName)
                    else -> Strings.get(R.string.offline_downloads_available)
                }
            }
        }
        player.addListener(listener)
        onDispose {
            save()
            player.removeListener(listener)
            player.release()
            PhoneDownloads.cleanUp(context, session)
        }
    }

    BackHandler { onExit() }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            factory = { viewContext ->
                PlayerView(viewContext).apply {
                    this.player = player
                    setShowSubtitleButton(true)
                    setShowNextButton(false)
                    setShowPreviousButton(false)
                    keepScreenOn = true
                    setControllerVisibilityListener(PlayerView.ControllerVisibilityListener { controlsVisible = it == View.VISIBLE })
                }
            },
            update = { view ->
                view.useController = !inPip
                if (inPip) view.hideController()
            },
            modifier = Modifier.fillMaxSize(),
        )
        // Picture-in-picture shows only the video.
        if (inPip) return@Box

        if (controlsVisible && error == null) {
            Row(
                Modifier.align(Alignment.TopStart).fillMaxWidth()
                    .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.7f), Color.Transparent)))
                    .padding(horizontal = 8.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onExit) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.close), tint = Color.White) }
                Column(Modifier.weight(1f)) {
                    Text(
                        (if (session.japanese) request.series.titleJp ?: request.anime.titleJp else null) ?: request.series.title,
                        style = MaterialTheme.typography.titleMedium,
                        color = Color.White,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        listOfNotNull(stringResource(R.string.episode_number, request.episode.number), request.episode.subtitle, if (request.kind == "dub") "Dub" else "Sub").joinToString(" · "),
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.White.copy(alpha = 0.8f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                IconButton(onClick = { previous?.let { open(it) } }, enabled = previous != null && changing == null) {
                    Icon(PhoneIcons.SkipPrevious, contentDescription = stringResource(R.string.previous_episode), tint = if (previous != null) Color.White else Color.White.copy(alpha = 0.4f))
                }
                IconButton(onClick = { next?.let { open(it) } }, enabled = next != null && changing == null) {
                    Icon(PhoneIcons.SkipNext, contentDescription = stringResource(R.string.next_episode), tint = if (next != null) Color.White else Color.White.copy(alpha = 0.4f))
                }
            }
        }

        skip?.let { (label, range) ->
            if (error == null && changing == null) Button(
                onClick = { player.seekTo((range.end * 1000).toLong()); skip = null },
                modifier = Modifier.align(Alignment.BottomEnd).padding(end = 24.dp, bottom = if (controlsVisible) 96.dp else 24.dp),
            ) { Text(label) }
        }

        changing?.let {
            Text(it, color = Color.White, modifier = Modifier.align(Alignment.Center).background(Color.Black.copy(alpha = 0.6f), RoundedCornerShape(12.dp)).padding(20.dp))
        }

        error?.let { message ->
            Column(
                Modifier.align(Alignment.Center).padding(24.dp).background(Color(0xEE1F1F2E), RoundedCornerShape(20.dp)).padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(message, color = Color.White, style = MaterialTheme.typography.titleSmall)
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Button(onClick = {
                        // A fresh URL from the same server, from the saved position.
                        save()
                        error = null
                        if (request.downloaded) {
                            attempt++
                            return@Button
                        }
                        changing = Strings.get(R.string.retrying)
                        scope.launch {
                            try {
                                request = session.resolve(request.anime, request.series, request.episode, request.kind, request.playback.serverName)
                                attempt++
                            } catch (failure: BridgeException) {
                                error = Strings.get(R.string.retry_failed, failure.message.orEmpty())
                            } finally {
                                changing = null
                            }
                        }
                    }) { Text(stringResource(R.string.retry)) }
                    OutlinedButton(onClick = onExit) { Text(stringResource(R.string.close_player)) }
                }
            }
        }
    }
}
