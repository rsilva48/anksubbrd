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
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.movableContentOf
import androidx.compose.foundation.layout.height
import androidx.compose.ui.platform.LocalDensity
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
    // Google Cast: while casting the receiver plays and this screen is its
    // remote; the local player is stopped so the phone does not stream too.
    var castShare by remember { mutableStateOf<CastShare?>(null) }
    var preparingCast by remember { mutableStateOf(false) }
    var castSubtitle by remember { mutableStateOf<Long?>(null) }
    var showCastDialog by remember { mutableStateOf(false) }
    /** After casting ends the episode continues here, paused. */
    var resumePaused by remember { mutableStateOf(false) }
    val castAvailable by PhoneCast.available.collectAsState()
    val castConnected by PhoneCast.connected.collectAsState()
    val castState by PhoneCast.state.collectAsState()
    val castPosition by PhoneCast.position.collectAsState()
    val castDuration by PhoneCast.duration.collectAsState()
    val castDevice by PhoneCast.deviceName.collectAsState()
    val castStarted by PhoneCast.sessionGeneration.collectAsState()
    val castEnded by PhoneCast.endedGeneration.collectAsState()
    val castFinished by PhoneCast.finished.collectAsState()
    val castFailure by PhoneCast.failure.collectAsState()
    /** Cast events from before this screen opened are not this episode's. */
    val castBaseline = remember { Triple(castStarted, castEnded, castFinished) }
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

    fun positionSeconds(): Double = if (castShare != null) PhoneCast.position.value else player.currentPosition / 1000.0

    fun seekTo(seconds: Double) {
        if (castShare != null) PhoneCast.seek(seconds) else player.seekTo((seconds * 1000).toLong())
    }

    fun entry(completed: Boolean? = null): HistoryEntry? {
        val position = positionSeconds()
        if (position <= 0) return null
        val duration = if (castShare != null) PhoneCast.duration.value.takeIf { it > 0 }
            else player.duration.takeIf { it != C.TIME_UNSET && it > 0 }?.let { it / 1000.0 }
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
        if (castShare != null) PhoneCast.pause()
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

    fun episodeEnded() {
        save(completed = true)
        val following = request.series.episodeAfter(request.episode.number, request.kind)
        if (following != null && session.preferences.autoNext) open(following, saveCurrent = false) else if (following == null) onExit()
    }

    /**
     * The same episode in the other version (Sub: Japanese audio with
     * subtitles; Dub: English audio) from the same position. The Default
     * Media Receiver cannot switch audio tracks inside a stream, so this is
     * also how the audio changes while casting.
     */
    fun switchKind(kind: String) {
        if (kind == request.kind || changing != null || request.downloaded) return
        val label = if (kind == "dub") "Dub" else "Sub"
        if (!request.episode.isAvailable(kind)) {
            error = Strings.get(R.string.kind_unavailable, request.episode.number, label)
            return
        }
        save()
        if (castShare != null) PhoneCast.pause()
        changing = Strings.get(R.string.opening_episode, request.episode.number)
        val current = request
        scope.launch {
            try {
                val resolved = session.resolve(current.anime, current.series, current.episode, kind, current.playback.serverName)
                // resolve() falls back to the other kind; that is not a switch.
                if (resolved.kind != kind) error = Strings.get(R.string.kind_unavailable, current.episode.number, label)
                else request = resolved
            } catch (failure: BridgeException) {
                error = Strings.get(R.string.kind_switch_failed, label, failure.message.orEmpty())
            } finally {
                changing = null
            }
        }
    }

    fun revoke(share: CastShare) {
        scope.launch { runCatching { session.client.revokeCast(share.id) } }
    }

    /** Sub: the identity's subtitle language, the device's, the bridge default or English; Dub: none. */
    fun castSubtitleFor(share: CastShare): Long? {
        val tracks = share.subtitles.filterNot { it.forced }
        val preference = session.preferences.subtitleLanguage
        if (request.kind != "sub" || preference == "off") return null
        fun matching(tag: String): CastSubtitle? = tracks.firstOrNull { it.language.equals(tag, ignoreCase = true) }
            ?: tracks.firstOrNull { it.language.startsWith("$tag-", ignoreCase = true) || tag.startsWith("${it.language}-", ignoreCase = true) }
        val device = Locale.getDefault()
        return (preference.takeIf { it.isNotEmpty() }?.let(::matching) ?: matching(device.toLanguageTag()) ?: matching(device.language)
            ?: tracks.firstOrNull { it.isDefault } ?: matching("en") ?: tracks.firstOrNull())?.id
    }

    /**
     * Sends the episode to the connected Cast device: the bridge makes a
     * temporary link without the identity token, the receiver loads it with
     * the subtitle files as tracks from [startSeconds].
     */
    fun startCasting(startSeconds: Double) {
        if (preparingCast || !PhoneCast.connected.value) return
        if (request.downloaded) {
            error = Strings.get(R.string.cast_download_local)
            return
        }
        player.stop()
        preparingCast = true
        val current = request
        scope.launch {
            try {
                val share = session.client.castShare(current.playback.playbackUrl)
                if (request !== current || !PhoneCast.connected.value) {
                    revoke(share)
                    return@launch
                }
                val subtitleId = castSubtitleFor(share)
                val title = (if (session.japanese) current.series.titleJp ?: current.anime.titleJp else null) ?: current.series.title
                val line = listOfNotNull(Strings.get(R.string.episode_number, current.episode.number), current.episode.subtitle, if (current.kind == "dub") "Dub" else "Sub").joinToString(" · ")
                if (!PhoneCast.load(share, title, line, current.anime.imageUrl ?: current.series.imageUrl, startSeconds, subtitleId)) {
                    revoke(share)
                    resumePaused = true
                    attempt++
                    return@launch
                }
                castShare?.let(::revoke)
                castShare = share
                castSubtitle = subtitleId
                error = null
            } catch (failure: BridgeException) {
                if (failure.status == 404) {
                    // The bridge forgot this playback (restart or 2 h expiry):
                    // a fresh one is resolved, and loading it casts it.
                    preparingCast = false
                    try {
                        request = session.resolve(current.anime, current.series, current.episode, current.kind, current.playback.serverName)
                    } catch (again: BridgeException) {
                        error = Strings.get(R.string.cast_failed, again.message.orEmpty())
                    }
                } else {
                    error = Strings.get(R.string.cast_failed, failure.message.orEmpty())
                    resumePaused = true
                    attempt++
                }
            } finally {
                preparingCast = false
            }
        }
    }

    // A Cast session started (or resumed with other media on the receiver).
    LaunchedEffect(castStarted) {
        if (castStarted == castBaseline.first || !PhoneCast.connected.value) return@LaunchedEffect
        val share = castShare
        if (share != null && PhoneCast.loadedUrl.value == share.url) return@LaunchedEffect
        save()
        startCasting(positionSeconds())
    }
    // The Cast session ended: continue here, paused, where the receiver was.
    LaunchedEffect(castEnded) {
        if (castEnded == castBaseline.second || (castShare == null && !preparingCast)) return@LaunchedEffect
        save()
        castShare?.let(::revoke)
        castShare = null
        castSubtitle = null
        resumePaused = true
        attempt++
    }
    LaunchedEffect(castFinished) {
        if (castFinished != castBaseline.third && castShare != null && changing == null) episodeEnded()
    }
    LaunchedEffect(castFailure) {
        val message = castFailure ?: return@LaunchedEffect
        if (castShare != null || preparingCast) {
            error = message
            PhoneCast.clearFailure()
        }
    }

    // Sub turns subtitles on (the identity's language, the device's or
    // English); Dub leaves them to the stream.
    LaunchedEffect(request, attempt) {
        // With a Cast device connected the episode goes there (downloads stay here).
        if (PhoneCast.connected.value && !request.downloaded) {
            startCasting(session.position(request.anime.watchUrl, request.episode.number))
            return@LaunchedEffect
        }
        castShare?.let {
            PhoneCast.pause()
            revoke(it)
            castShare = null
            castSubtitle = null
        }
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
        player.playWhenReady = !resumePaused
        resumePaused = false
    }

    // Progress every 10 s; automatic intro/outro skipping every second.
    LaunchedEffect(request) {
        skip = null
        var ticks = 0
        while (true) {
            delay(1000)
            val position = positionSeconds()
            val preferences = session.preferences
            request.playback.intro?.takeIf { preferences.autoSkipIntro && position >= it.start && position < it.end }?.let { seekTo(it.end) }
            request.playback.outro?.takeIf { preferences.autoSkipOutro && position >= it.start && position < it.end }?.let { seekTo(it.end) }
            skip = request.playback.intro?.takeIf { !preferences.autoSkipIntro && position >= it.start && position < it.end }?.let { Strings.get(R.string.skip_intro) to it }
                ?: request.playback.outro?.takeIf { !preferences.autoSkipOutro && position >= it.start && position < it.end }?.let { Strings.get(R.string.skip_outro) to it }
            val playing = if (castShare != null) PhoneCast.state.value == CastPlayback.Playing else player.isPlaying
            if (++ticks % 10 == 0 && playing) save()
        }
    }

    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (state != Player.STATE_ENDED || changing != null || castShare != null) return
                episodeEnded()
            }

            override fun onIsPlayingChanged(playing: Boolean) {
                isPlaying = playing
                if (!playing && castShare == null) save()
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

    /** Series, episode and version, Cast, previous and next episode. */
    val episodeBar: @Composable (Modifier) -> Unit = { modifier ->
        Row(
            modifier.fillMaxWidth()
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
            if (!request.downloaded) VersionMenu(request.kind, onSelect = { switchKind(it) })
            if (castAvailable) {
                IconButton(onClick = { showCastDialog = true }) {
                    Icon(if (castConnected) PhoneIcons.CastConnected else PhoneIcons.Cast, contentDescription = stringResource(R.string.cast), tint = Color.White)
                }
            }
            IconButton(onClick = { previous?.let { open(it) } }, enabled = previous != null && changing == null) {
                Icon(PhoneIcons.SkipPrevious, contentDescription = stringResource(R.string.previous_episode), tint = if (previous != null) Color.White else Color.White.copy(alpha = 0.4f))
            }
            IconButton(onClick = { next?.let { open(it) } }, enabled = next != null && changing == null) {
                Icon(PhoneIcons.SkipNext, contentDescription = stringResource(R.string.next_episode), tint = if (next != null) Color.White else Color.White.copy(alpha = 0.4f))
            }
        }
    }

    // The video view moves between the full-screen and tabletop layouts
    // without being recreated, so playback continues while folding.
    val video = remember {
        movableContentOf { modifier: Modifier ->
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
                modifier = modifier,
            )
        }
    }
    // Tabletop posture (half folded, hinge across the screen): the video on
    // the upper half and the episode bar on the lower one, nothing on the fold.
    val tabletop = rememberPhoneLayout().tabletopHinge?.takeIf { !inPip && castShare == null && !preparingCast }
    val density = LocalDensity.current

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        if (tabletop != null) {
            Column(Modifier.fillMaxSize()) {
                video(Modifier.fillMaxWidth().height(with(density) { tabletop.top.toDp() }))
                Spacer(Modifier.height(with(density) { tabletop.height.toDp() }))
                Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) { episodeBar(Modifier) }
            }
        } else {
            video(Modifier.fillMaxSize())
        }
        // Picture-in-picture shows only the video.
        if (inPip) return@Box

        if (castShare != null || preparingCast) {
            CastPanel(
                title = (if (session.japanese) request.series.titleJp ?: request.anime.titleJp else null) ?: request.series.title,
                line = listOfNotNull(stringResource(R.string.episode_number, request.episode.number), request.episode.subtitle).joinToString(" · "),
                device = castDevice ?: stringResource(R.string.cast),
                preparing = preparingCast,
                state = castState,
                position = castPosition,
                duration = castDuration,
                subtitles = castShare?.subtitles?.filterNot { it.forced }.orEmpty(),
                subtitle = castSubtitle,
                kind = request.kind,
                hasPrevious = previous != null && changing == null,
                hasNext = next != null && changing == null,
                onBack = onExit,
                onSeek = { seekTo(it) },
                onPrevious = { previous?.let { open(it) } },
                onNext = { next?.let { open(it) } },
                onSubtitle = { track ->
                    PhoneCast.setSubtitle(track?.id)
                    castSubtitle = track?.id
                    // A choice made in a Sub episode becomes the identity's preference.
                    if (request.kind == "sub") scope.launch { session.updatePreferences { it.copy(subtitleLanguage = track?.language ?: "off") } }
                },
                onKind = { switchKind(it) },
                onDevice = { showCastDialog = true },
            )
        } else if (tabletop == null && controlsVisible && error == null) {
            episodeBar(Modifier.align(Alignment.TopStart))
        }

        skip?.let { (label, range) ->
            if (error == null && changing == null) Button(
                onClick = { seekTo(range.end); skip = null },
                modifier = Modifier.align(Alignment.BottomEnd).padding(end = 24.dp, bottom = if (controlsVisible) 96.dp else 24.dp),
            ) { Text(label) }
        }

        if (showCastDialog) CastDialog(onDismiss = { showCastDialog = false })

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

/** "Sub ▾" / "Dub ▾": the same episode in the other version. */
@Composable
private fun VersionMenu(kind: String, onSelect: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { open = true }) { Text(if (kind == "dub") "Dub ▾" else "Sub ▾", color = Color.White) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            listOf("sub" to R.string.audio_japanese, "dub" to R.string.audio_english).forEach { (option, detail) ->
                DropdownMenuItem(
                    text = { Text("${if (option == "dub") "Dub" else "Sub"} · ${stringResource(detail)}") },
                    onClick = {
                        open = false
                        onSelect(option)
                    },
                    trailingIcon = { if (option == kind) Text("✓") },
                )
            }
        }
    }
}

/**
 * The remote of a Cast receiver: what plays and where, transport, position,
 * subtitle tracks, the Sub/Dub version and the device (volume, disconnect).
 */
@Composable
private fun CastPanel(
    title: String,
    line: String,
    device: String,
    preparing: Boolean,
    state: CastPlayback,
    position: Double,
    duration: Double,
    subtitles: List<CastSubtitle>,
    subtitle: Long?,
    kind: String,
    hasPrevious: Boolean,
    hasNext: Boolean,
    onBack: () -> Unit,
    onSeek: (Double) -> Unit,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onSubtitle: (CastSubtitle?) -> Unit,
    onKind: (String) -> Unit,
    onDevice: () -> Unit,
) {
    var scrubbing by remember { mutableStateOf<Float?>(null) }
    var subtitlesOpen by remember { mutableStateOf(false) }
    val playing = state == CastPlayback.Playing || state == CastPlayback.Buffering || state == CastPlayback.Loading
    Column(
        Modifier.fillMaxSize().background(Color(0xFF0B0B12)).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.SpaceBetween,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.close), tint = Color.White) }
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleMedium, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(line, style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.8f), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            VersionMenu(kind, onSelect = onKind)
            Box {
                IconButton(onClick = { subtitlesOpen = true }, enabled = !preparing) {
                    Icon(PhoneIcons.Subtitles, contentDescription = stringResource(R.string.cast_subtitles), tint = if (subtitle != null) Color.White else Color.White.copy(alpha = 0.6f))
                }
                DropdownMenu(expanded = subtitlesOpen, onDismissRequest = { subtitlesOpen = false }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.subtitles_off)) },
                        onClick = { subtitlesOpen = false; onSubtitle(null) },
                        trailingIcon = { if (subtitle == null) Text("✓") },
                    )
                    subtitles.forEach { track ->
                        DropdownMenuItem(
                            text = { Text(track.name) },
                            onClick = { subtitlesOpen = false; onSubtitle(track) },
                            trailingIcon = { if (subtitle == track.id) Text("✓") },
                        )
                    }
                }
            }
            IconButton(onClick = onDevice) { Icon(PhoneIcons.CastConnected, contentDescription = stringResource(R.string.cast), tint = Color.White) }
        }

        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Icon(PhoneIcons.CastConnected, contentDescription = null, tint = Color.White.copy(alpha = 0.8f), modifier = Modifier.size(40.dp))
            Text(
                stringResource(if (preparing) R.string.cast_sending_to else R.string.cast_casting_to, device),
                style = MaterialTheme.typography.titleMedium,
                color = Color.White,
            )
        }

        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onPrevious, enabled = hasPrevious) {
                Icon(PhoneIcons.SkipPrevious, contentDescription = stringResource(R.string.previous_episode), tint = Color.White.copy(alpha = if (hasPrevious) 1f else 0.4f))
            }
            Spacer(Modifier.width(12.dp))
            IconButton(onClick = { onSeek((position - 10).coerceAtLeast(0.0)) }, enabled = !preparing) {
                Icon(PhoneIcons.Replay10, contentDescription = stringResource(R.string.cast_back10), tint = Color.White)
            }
            Spacer(Modifier.width(12.dp))
            IconButton(onClick = { if (playing) PhoneCast.pause() else PhoneCast.play() }, enabled = !preparing, modifier = Modifier.size(64.dp)) {
                Icon(
                    if (playing) PhoneIcons.Pause else Icons.Filled.PlayArrow,
                    contentDescription = stringResource(if (playing) R.string.cast_pause else R.string.cast_play),
                    tint = Color.White,
                    modifier = Modifier.size(48.dp),
                )
            }
            Spacer(Modifier.width(12.dp))
            IconButton(onClick = { onSeek(position + 10) }, enabled = !preparing) {
                Icon(PhoneIcons.Forward10, contentDescription = stringResource(R.string.cast_forward10), tint = Color.White)
            }
            Spacer(Modifier.width(12.dp))
            IconButton(onClick = onNext, enabled = hasNext) {
                Icon(PhoneIcons.SkipNext, contentDescription = stringResource(R.string.next_episode), tint = Color.White.copy(alpha = if (hasNext) 1f else 0.4f))
            }
        }

        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            val shown = scrubbing?.toDouble() ?: position
            Text(formatTime(shown), color = Color.White, style = MaterialTheme.typography.labelMedium)
            Slider(
                value = shown.toFloat().coerceIn(0f, duration.toFloat().coerceAtLeast(1f)),
                onValueChange = { scrubbing = it },
                onValueChangeFinished = {
                    scrubbing?.let { onSeek(it.toDouble()) }
                    scrubbing = null
                },
                valueRange = 0f..duration.toFloat().coerceAtLeast(1f),
                enabled = !preparing && duration > 0,
                modifier = Modifier.weight(1f),
            )
            Text(formatTime(duration), color = Color.White, style = MaterialTheme.typography.labelMedium)
        }
    }
}
