@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)

package com.personal.anksubbrd.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import kotlinx.coroutines.launch

private val extraSeason = Regex("\\b(specials?|mini anime|recap|ova|oad|movie|film)\\b", RegexOption.IGNORE_CASE)

/** Episodes of a series and what to play next; seasons replace the screen in place. */
@Composable
internal fun PhoneSeries(session: Session, anime: Anime, onBack: () -> Unit) {
    val app = LocalPhone.current
    val scope = rememberCoroutineScope()
    var current by remember(anime.watchUrl) { mutableStateOf(anime) }
    var series by remember { mutableStateOf<Series?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf<String?>(null) }
    var serverChoice by remember { mutableStateOf<Pair<Episode, List<Server>>?>(null) }
    var synopsisExpanded by remember { mutableStateOf(false) }
    var reload by remember { mutableStateOf(0) }

    LaunchedEffect(current.watchUrl, reload) {
        series = null
        error = null
        try {
            series = session.client.series(current.watchUrl)
        } catch (failure: BridgeException) {
            error = failure.message
        }
    }

    val entry = session.entry(current.watchUrl)
    val kind = entry?.serverKind ?: session.preferences.defaultTrackType
    val title = current.displayTitle(session.japanese)

    // Series sessions on the bridge expire after 20 minutes (HTTP 410).
    suspend fun <T> withSeries(block: suspend (Series) -> T): T {
        val loaded = series ?: throw BridgeException("La serie aún no se cargó.")
        return try {
            block(loaded)
        } catch (failure: BridgeException) {
            if (failure.status != 410) throw failure
            val fresh = session.client.series(current.watchUrl)
            series = fresh
            block(fresh)
        }
    }

    fun play(episode: Episode, preferredServer: String?, playKind: String) {
        val loaded = series ?: return
        if (busy != null) return
        busy = "Preparando reproducción…"
        scope.launch {
            try {
                app.playing = session.resolve(current, loaded, episode, playKind, preferredServer)
            } catch (failure: BridgeException) {
                error = failure.message
            } finally {
                busy = null
            }
        }
    }

    fun chooseServer(episode: Episode) {
        if (busy != null) return
        busy = "Cargando servidores del episodio ${episode.number}…"
        scope.launch {
            try {
                serverChoice = episode to withSeries { session.client.servers(it.seriesKey, episode.number) }
            } catch (failure: BridgeException) {
                error = failure.message
            } finally {
                busy = null
            }
        }
    }

    fun playServer(episode: Episode, server: Server) {
        busy = "Preparando reproducción…"
        scope.launch {
            try {
                val playback = withSeries { session.client.play(it.seriesKey, episode.number, server.index) }
                app.playing = PlaybackRequest(current, series ?: return@launch, episode, playback.serverKind ?: server.type, playback)
            } catch (failure: BridgeException) {
                error = failure.message
            } finally {
                busy = null
            }
        }
    }

    fun tvCommand(episode: Episode) = RemoteCommand(type = "play", watchUrl = current.watchUrl, episode = episode.number, kind = kind)

    /** With a TV connected the episode goes there; otherwise the server picker. */
    fun open(episode: Episode) {
        if (!app.playOnTv(tvCommand(episode), "$title · episodio ${episode.number}") { chooseServer(episode) }) chooseServer(episode)
    }

    /** Continue and next: the saved server and kind, straight away (or on the TV). */
    fun resume(episode: Episode, preferredServer: String?, playKind: String) {
        if (!app.playOnTv(tvCommand(episode), "$title · episodio ${episode.number}") { play(episode, preferredServer, playKind) }) {
            play(episode, preferredServer, playKind)
        }
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
            navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Atrás") } },
            actions = {
                val loaded = series
                if (loaded != null) IconButton(onClick = {
                    // Opens the remote; the episode is offered, not sent.
                    val suggested = suggestedEpisode(loaded, entry, current)
                    app.tvPlay = suggested?.let { TvPlayRequest(tvCommand(it), "$title · episodio ${it.number}", autoplay = false) }
                    app.remoteOpen = true
                }) { Icon(PhoneIcons.Tv, contentDescription = "Ver en TV") }
            },
        )
        busy?.let {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            Text(it, style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
        }
        val loaded = series
        LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
            item {
                Row(Modifier.padding(16.dp), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    AsyncImage(
                        model = current.imageUrl ?: loaded?.imageUrl,
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.width(120.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(10.dp)).background(MaterialTheme.colorScheme.surfaceVariant),
                    )
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(loaded?.title ?: current.title, style = MaterialTheme.typography.titleLarge)
                        if (session.japanese) (loaded?.titleJp ?: current.titleJp)?.let {
                            Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        if (loaded?.adult == true || current.isAdult) PhoneBadge("+18", androidx.compose.ui.graphics.Color(0xFFDC2626))
                        if (loaded != null) {
                            val meta = listOfNotNull(
                                loaded.mediaType,
                                when (loaded.status) { "airing" -> "En emisión"; "finished" -> "Finalizado"; "upcoming" -> "Próximamente"; else -> null },
                                loaded.score?.let { "★ %.1f".format(it) },
                                // The catalog sends "?" when it has no rating.
                                loaded.rating?.takeUnless { it == "?" },
                            ).joinToString(" · ")
                            if (meta.isNotEmpty()) Text(meta, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            val total = loaded.totalEpisodes
                            Text(
                                if (total != null && total > loaded.episodes.size) "${loaded.episodes.size} de $total episodios" else "${loaded.episodes.size} episodios",
                                style = MaterialTheme.typography.bodySmall,
                            )
                            airingLabel(loaded.nextEpisodeAt)?.let {
                                Text("Próximo episodio: $it", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
                            }
                        }
                    }
                }
            }
            if (loaded == null) {
                item {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(error ?: "Cargando episodios…", color = if (error != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
                        if (error != null) OutlinedButton(onClick = { reload++ }) { Icon(Icons.Filled.Refresh, null); Text(" Reintentar") }
                    }
                }
                return@LazyColumn
            }
            item {
                Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    PrimaryAction(session, loaded, current, entry, kind, playIcon = app.connectedTv != null,
                        onResume = ::resume, onOpen = ::open, onSeason = { current = it.asAnime() })
                    error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                }
            }
            loaded.synopsis?.let { synopsis ->
                item {
                    Column(Modifier.padding(16.dp).clickable { synopsisExpanded = !synopsisExpanded }) {
                        Text("Sinopsis", style = MaterialTheme.typography.titleSmall)
                        Text(synopsis, style = MaterialTheme.typography.bodyMedium, maxLines = if (synopsisExpanded) Int.MAX_VALUE else 4, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            if (loaded.seasons.size > 1) item {
                var menu by remember { mutableStateOf(false) }
                val selected = loaded.seasons.firstOrNull { catalogPath(it.watchUrl) == catalogPath(current.watchUrl) }
                Box(Modifier.padding(horizontal = 16.dp)) {
                    OutlinedButton(onClick = { menu = true }) {
                        Text("Temporada: ${selected?.displayLabel ?: "—"}", maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Icon(Icons.Filled.ArrowDropDown, contentDescription = null)
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        loaded.seasons.forEach { season ->
                            DropdownMenuItem(
                                text = { Text(season.displayLabel) },
                                leadingIcon = { if (season == selected) Icon(Icons.Filled.Check, contentDescription = null) },
                                onClick = { menu = false; current = season.asAnime() },
                            )
                        }
                    }
                }
            }
            item { Text("Episodios", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(start = 16.dp, top = 16.dp)) }
            items(loaded.episodes, key = { it.number }) { episode ->
                var menu by remember { mutableStateOf(false) }
                val watched = entry != null && (episode.number < entry.episode || (episode.number == entry.episode && entry.isCompleted))
                val progress = entry?.takeIf { it.episode == episode.number && !it.isCompleted }?.positionSeconds
                Box {
                    ListItem(
                        headlineContent = { Text("${episode.number}. ${episode.subtitle ?: "Episodio ${episode.number}"}", maxLines = 2, overflow = TextOverflow.Ellipsis) },
                        supportingContent = {
                            val notes = listOfNotNull(
                                progress?.let { "Visto hasta ${formatTime(it)}" },
                                if (episode.number == current.episode) "Nuevo" else null,
                                if (!episode.isAvailable(kind)) "Aún sin ${if (kind == "dub") "Dub" else "Sub"}" else null,
                            )
                            if (notes.isNotEmpty()) Text(notes.joinToString(" · "))
                        },
                        trailingContent = {
                            Icon(if (watched) Icons.Filled.Check else if (app.connectedTv != null) PhoneIcons.Tv else Icons.Filled.PlayArrow, contentDescription = null)
                        },
                        modifier = Modifier.combinedClickable(onClick = { open(episode) }, onLongClick = { menu = true }),
                    )
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("Ver en TV") }, leadingIcon = { Icon(PhoneIcons.Tv, null) }, onClick = {
                            menu = false
                            app.tvPlay = TvPlayRequest(tvCommand(episode), "$title · episodio ${episode.number}", autoplay = true) { chooseServer(episode) }
                            app.remoteOpen = true
                        })
                        if (app.connectedTv != null) DropdownMenuItem(text = { Text("Ver en este teléfono") }, leadingIcon = { Icon(Icons.Filled.PlayArrow, null) }, onClick = {
                            menu = false
                            chooseServer(episode)
                        })
                        DropdownMenuItem(text = { Text("Elegir servidor en línea") }, onClick = { menu = false; chooseServer(episode) })
                    }
                }
            }
        }
    }

    serverChoice?.let { (episode, servers) ->
        PhoneServerPicker(episode, servers, defaultKind = kind, onDismiss = { serverChoice = null }) { server ->
            serverChoice = null
            playServer(episode, server)
        }
    }
}

/** The episode "Ver en TV" offers: in progress, else the next of the same kind, else the newest or the first. */
private fun suggestedEpisode(series: Series, entry: HistoryEntry?, anime: Anime): Episode? {
    if (entry == null) return series.episodes.firstOrNull { it.number == anime.episode } ?: series.episodes.firstOrNull()
    if (!entry.isCompleted) return series.episodes.firstOrNull { it.number == entry.episode }
    return series.episodeAfter(entry.episode, entry.serverKind ?: "sub") ?: series.episodes.firstOrNull { it.number == entry.episode }
}

@Composable
private fun PrimaryAction(
    session: Session,
    series: Series,
    anime: Anime,
    entry: HistoryEntry?,
    kind: String,
    playIcon: Boolean,
    onResume: (Episode, String?, String) -> Unit,
    onOpen: (Episode) -> Unit,
    onSeason: (Season) -> Unit,
) {
    val icon = if (playIcon) PhoneIcons.Tv else Icons.Filled.PlayArrow
    val watchedEpisode = entry?.let { saved -> series.episodes.firstOrNull { it.number == saved.episode } }
    if (entry != null && watchedEpisode != null) {
        val playKind = entry.serverKind ?: session.preferences.defaultTrackType
        if (!entry.isCompleted) {
            Button(onClick = { onResume(watchedEpisode, entry.serverName, playKind) }, modifier = Modifier.fillMaxWidth()) {
                Icon(icon, null)
                Text(" Continuar episodio ${entry.episode} · ${formatTime(entry.positionSeconds)}")
            }
            return
        }
        val next = series.episodeAfter(entry.episode, kind)
        if (next != null) {
            Button(onClick = { onResume(next, entry.serverName, kind) }, modifier = Modifier.fillMaxWidth()) {
                Icon(icon, null)
                Text(" Ver episodio ${next.number} · siguiente")
            }
            return
        }
        val latest = series.episodes.lastOrNull()?.number
        val total = series.totalEpisodes
        val finished = if (total != null) entry.episode >= total else series.status == "finished" && entry.episode >= (latest ?: entry.episode)
        val following = series.seasons.indexOfFirst { catalogPath(it.watchUrl) == catalogPath(anime.watchUrl) }.takeIf { it >= 0 }
            ?.let { index -> series.seasons.drop(index + 1) }.orEmpty()
        val nextSeason = following.firstOrNull { !extraSeason.containsMatchIn(it.title) } ?: following.firstOrNull()
        if (finished && nextSeason != null) {
            Button(onClick = { onSeason(nextSeason) }, modifier = Modifier.fillMaxWidth()) { Text("Ver ${nextSeason.displayLabel}") }
        }
        Text(
            if (finished) "Serie completada · viste los ${entry.episode} episodios"
            else "Estás al día: viste el episodio ${entry.episode}. Aparecerá aquí cuando salga el siguiente en ${if (kind == "dub") "Dub" else "Sub"}.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        FilledTonalButton(onClick = { onResume(watchedEpisode, entry.serverName, playKind) }, modifier = Modifier.fillMaxWidth()) {
            Text("Volver a ver el episodio ${entry.episode}")
        }
        return
    }
    val first = series.episodes.firstOrNull { it.number == anime.episode } ?: series.episodes.firstOrNull() ?: return
    Button(onClick = { onOpen(first) }, modifier = Modifier.fillMaxWidth()) {
        Icon(icon, null)
        Text(if (first.number == anime.episode) " Ver episodio ${first.number} (nuevo)" else " Empezar con el episodio ${first.number}")
    }
}

/** Servers of an episode, Sub or Dub; playback starts once the sheet closes. */
@Composable
internal fun PhoneServerPicker(episode: Episode, servers: List<Server>, defaultKind: String, onDismiss: () -> Unit, onPick: (Server) -> Unit) {
    val kinds = listOf("sub", "dub")
    var selected by remember { mutableStateOf(if (servers.any { it.type == defaultKind }) defaultKind else servers.firstOrNull()?.type ?: "sub") }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Episodio ${episode.number}", style = MaterialTheme.typography.titleLarge)
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                kinds.forEachIndexed { index, value ->
                    SegmentedButton(
                        selected = selected == value,
                        onClick = { selected = value },
                        shape = SegmentedButtonDefaults.itemShape(index, kinds.size),
                    ) { Text(if (value == "dub") "Dub" else "Sub") }
                }
            }
            Text(
                if (selected == "dub") "Audio en inglés" else "Audio en japonés con subtítulos",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            val ofKind = servers.filter { it.type == selected }
            if (ofKind.isEmpty()) {
                Text("Este episodio no publicó fuentes ${if (selected == "dub") "Dub" else "Sub"}.", modifier = Modifier.padding(vertical = 24.dp))
            }
            ofKind.forEach { server ->
                ListItem(
                    headlineContent = { Text(server.name) },
                    trailingContent = { Icon(Icons.Filled.PlayArrow, null) },
                    modifier = Modifier.clickable { onPick(server) },
                )
            }
            Box(Modifier.padding(bottom = 24.dp))
        }
    }
}
