@file:OptIn(ExperimentalTvMaterial3Api::class)

package com.personal.anksubbrd.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.tv.material3.Button
import androidx.tv.material3.Card
import androidx.tv.material3.CardDefaults
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.ListItem
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Tab
import androidx.tv.material3.TabRow
import androidx.tv.material3.Text
import coil3.compose.AsyncImage
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

@Composable
fun HomeScreen(session: Session, onOpen: (Anime) -> Unit, onSwitchProfile: () -> Unit) {
    val tabs = listOf("Continuar", "Recientes", "Buscar")
    var selected by remember { mutableIntStateOf(0) }

    var initialLoading by remember(session) { mutableStateOf(session.history.isEmpty()) }
    LaunchedEffect(session) {
        try {
            if (withTimeoutOrNull(8_000) { session.refresh(); true } == null) session.initialLoadTimedOut()
        } finally {
            initialLoading = false
        }
    }
    val context = LocalContext.current
    val historyImages = session.history.mapNotNull { it.imageUrl?.takeIf(String::isNotBlank) }.distinct()
    LaunchedEffect(historyImages) {
        val loader = SingletonImageLoader.get(context)
        for (url in historyImages) {
            loader.execute(ImageRequest.Builder(context).data(url).size(360, 540).build())
        }
    }

    if (initialLoading) {
        StartupScreen()
        return
    }

    Column(Modifier.fillMaxSize().padding(horizontal = 48.dp, vertical = 24.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            TabRow(selectedTabIndex = selected, modifier = Modifier.weight(1f)) {
                tabs.forEachIndexed { index, title ->
                    Tab(selected = selected == index, onFocus = { selected = index }, onClick = { selected = index }) {
                        Text(title, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                    }
                }
            }
            RemoteAccessControl()
            TVUpdateControl()
            Spacer(Modifier.width(12.dp))
            OutlinedButton(onClick = onSwitchProfile) { Text("Perfil: ${session.profile.name}") }
        }
        Spacer(Modifier.height(20.dp))
        when (selected) {
            0 -> ContinueTab(session, onOpen)
            1 -> CatalogTab(session, onOpen, searching = false)
            else -> CatalogTab(session, onOpen, searching = true)
        }
    }
}

@Composable
private fun StartupScreen() {
    Box(Modifier.fillMaxSize().background(Color(0xFF0B0B12)), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp)) {
            Image(
                painter = painterResource(R.drawable.ic_launcher),
                contentDescription = null,
                modifier = Modifier.size(96.dp).clip(RoundedCornerShape(24.dp)),
            )
            Text("AniBridge Player", style = MaterialTheme.typography.headlineMedium, color = Color.White)
            Text("Preparando tu biblioteca", style = MaterialTheme.typography.bodyLarge, color = Color.White.copy(alpha = 0.65f))
            AndroidView(
                factory = { context -> android.widget.ProgressBar(context).apply {
                    isIndeterminate = true
                    indeterminateTintList = android.content.res.ColorStateList.valueOf(android.graphics.Color.rgb(129, 140, 248))
                } },
                modifier = Modifier.size(32.dp),
            )
        }
    }
}

@Composable
private fun ContinueTab(session: Session, onOpen: (Anime) -> Unit) {
    val entries = session.history
    when {
        entries.isEmpty() && session.historyError != null -> Message(session.historyError.orEmpty())
        entries.isEmpty() -> Message("Las series que veas en este perfil (aquí o en el teléfono) aparecerán aquí.")
        else -> LazyRow(horizontalArrangement = Arrangement.spacedBy(20.dp), contentPadding = PaddingValues(vertical = 12.dp)) {
            items(entries, key = { it.watchUrl }) { entry ->
                val label = if (entry.isCompleted) "Episodio ${entry.episode} · visto" else "Episodio ${entry.episode} · ${formatTime(entry.positionSeconds)}"
                PosterCard(
                    title = if (session.japanese) entry.titleJp ?: entry.seriesTitle else entry.seriesTitle,
                    subtitle = label,
                    imageUrl = entry.imageUrl,
                    modifier = Modifier.width(180.dp),
                    onClick = { onOpen(entry.asAnime()) },
                )
            }
        }
    }
}

/** Recents (Sub/Dub/both, the configured kind first) or search results, paged. */
@Composable
private fun CatalogTab(session: Session, onOpen: (Anime) -> Unit, searching: Boolean) {
    var language by remember { mutableStateOf(session.preferences.defaultTrackType) }
    var query by remember { mutableStateOf("") }
    var submitted by remember { mutableStateOf("") }
    var items by remember { mutableStateOf<List<Anime>>(emptyList()) }
    var page by remember { mutableIntStateOf(0) }
    var hasNext by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    suspend fun load(next: Int) {
        if (searching && submitted.isBlank()) return
        loading = true
        error = null
        try {
            val reply = if (searching) {
                session.client.latest(next, keyword = submitted)
            } else {
                session.client.latest(next, language = language)
            }
            items = if (next == 1) reply.results else (items + reply.results).distinctBy { it.watchUrl }
            page = next
            hasNext = reply.hasNext
        } catch (failure: BridgeException) {
            error = failure.message
        } finally {
            loading = false
        }
    }

    LaunchedEffect(language, submitted) {
        items = emptyList()
        load(1)
    }

    val visible = items.filter { !(session.preferences.hideAdult && it.isAdult) }

    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        if (searching) {
            TvTextField(
                value = query,
                onValueChange = { query = it },
                placeholder = "Título de la serie",
                imeAction = ImeAction.Search,
                onSubmit = { submitted = query.trim() },
                modifier = Modifier.width(640.dp),
            )
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                listOf("sub" to "Sub", "dub" to "Dub", "all" to "Sub y Dub").forEach { (value, label) ->
                    if (language == value) Button(onClick = { language = value }) { Text(label) }
                    else OutlinedButton(onClick = { language = value }) { Text(label) }
                }
            }
        }
        when {
            visible.isEmpty() && loading -> Message("Cargando…")
            visible.isEmpty() && error != null -> Message(error.orEmpty())
            visible.isEmpty() && searching && submitted.isBlank() -> Message("Escribe un título y pulsa Buscar en el teclado.")
            visible.isEmpty() -> Message("Sin resultados.")
            else -> LazyVerticalGrid(
                columns = GridCells.Adaptive(160.dp),
                horizontalArrangement = Arrangement.spacedBy(20.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp),
                contentPadding = PaddingValues(bottom = 48.dp),
            ) {
                itemsIndexed(visible, key = { _, anime -> anime.watchUrl }) { index, anime ->
                    if (index == visible.lastIndex && hasNext && !loading) {
                        LaunchedEffect(page) { scope.launch { load(page + 1) } }
                    }
                    PosterCard(
                        title = anime.displayTitle(session.japanese),
                        subtitle = listOfNotNull(anime.episode?.let { "EP $it" }, if (anime.isAdult) "+18" else null, anime.mediaType).joinToString(" · "),
                        imageUrl = anime.imageUrl,
                        onClick = { onOpen(anime) },
                    )
                }
            }
        }
    }
}

@Composable
fun PosterCard(title: String, subtitle: String, imageUrl: String?, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Card(onClick = onClick, modifier = Modifier.fillMaxWidth().aspectRatio(2f / 3f), scale = CardDefaults.scale(focusedScale = 1f)) {
            AsyncImage(model = imageUrl, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
        Text(title, style = MaterialTheme.typography.titleSmall, maxLines = 2, overflow = TextOverflow.Ellipsis)
        if (subtitle.isNotEmpty()) {
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.6f), maxLines = 1)
        }
    }
}

@Composable
fun Message(text: String) {
    Box(Modifier.fillMaxWidth().padding(vertical = 48.dp), contentAlignment = Alignment.Center) {
        Text(text, style = MaterialTheme.typography.titleMedium, color = Color.White.copy(alpha = 0.7f))
    }
}

/** Series: synopsis, the next episode to watch, seasons and episodes. */
@Composable
fun DetailsScreen(session: Session, anime: Anime, onPlay: (PlaybackRequest) -> Unit) {
    var current by remember { mutableStateOf(anime) }
    var series by remember { mutableStateOf<Series?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val playFocus = remember { FocusRequester() }

    LaunchedEffect(current.watchUrl) {
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

    fun play(episode: Episode) {
        val loaded = series ?: return
        if (busy != null) return
        busy = "Preparando el episodio ${episode.number}…"
        scope.launch {
            try {
                val preferred = entry?.serverName?.takeIf { entry.serverKind == kind }
                onPlay(session.resolve(current, loaded, episode, kind, preferred))
            } catch (failure: BridgeException) {
                error = failure.message
            } finally {
                busy = null
            }
        }
    }

    Row(Modifier.fillMaxSize().padding(horizontal = 64.dp, vertical = 40.dp), horizontalArrangement = Arrangement.spacedBy(48.dp)) {
        Column(Modifier.width(300.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            AsyncImage(
                model = current.imageUrl ?: series?.imageUrl,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxWidth().aspectRatio(2f / 3f).background(Color.White.copy(alpha = 0.08f), RoundedCornerShape(12.dp)),
            )
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            val loaded = series
            Text(loaded?.title ?: current.title, style = MaterialTheme.typography.headlineMedium, maxLines = 2)
            if (session.japanese) (loaded?.titleJp ?: current.titleJp)?.let { Text(it, color = Color.White.copy(alpha = 0.6f)) }
            if (loaded != null) {
                val meta = listOfNotNull(
                    loaded.mediaType,
                    when (loaded.status) { "airing" -> "En emisión"; "finished" -> "Finalizado"; "upcoming" -> "Próximamente"; else -> null },
                    loaded.score?.let { "★ %.1f".format(it) },
                    loaded.rating,
                    "${loaded.episodes.size}${loaded.totalEpisodes?.let { "/$it" } ?: ""} episodios",
                )
                Text(meta.joinToString(" · "), color = Color.White.copy(alpha = 0.6f))
                loaded.synopsis?.let { Text(it, maxLines = 4, overflow = TextOverflow.Ellipsis, color = Color.White.copy(alpha = 0.85f)) }
                val next = when {
                    entry == null -> loaded.episodes.firstOrNull()
                    !entry.isCompleted -> loaded.episodes.firstOrNull { it.number == entry.episode }
                    else -> loaded.episodeAfter(entry.episode, kind)
                }
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (next != null) {
                        val label = when {
                            entry != null && !entry.isCompleted && next.number == entry.episode -> "Continuar episodio ${next.number} · ${formatTime(entry.positionSeconds)}"
                            entry != null -> "Ver episodio ${next.number} · siguiente"
                            else -> "Empezar con el episodio ${next.number}"
                        }
                        Button(onClick = { play(next) }, modifier = Modifier.focusRequester(playFocus)) { Text(label) }
                        LaunchedEffect(current.watchUrl, next.number) { playFocus.requestFocus() }
                    } else if (entry != null) {
                        Text("Estás al día: viste el episodio ${entry.episode}.", color = Color.White.copy(alpha = 0.7f))
                    }
                }
                if (loaded.seasons.size > 1) {
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(loaded.seasons, key = { it.watchUrl }) { season ->
                            if (catalogPath(season.watchUrl) == catalogPath(current.watchUrl)) {
                                Button(onClick = {}) { Text(season.displayLabel, maxLines = 1) }
                            } else {
                                OutlinedButton(onClick = { current = season.asAnime() }) { Text(season.displayLabel, maxLines = 1) }
                            }
                        }
                    }
                }
                busy?.let { Text(it, color = MaterialTheme.colorScheme.primary) }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp), contentPadding = PaddingValues(bottom = 48.dp)) {
                    items(loaded.episodes, key = { it.number }) { episode ->
                        val watched = entry != null && (episode.number < entry.episode || (episode.number == entry.episode && entry.isCompleted))
                        val progress = entry?.takeIf { it.episode == episode.number && !it.isCompleted }?.positionSeconds
                        ListItem(
                            selected = false,
                            onClick = { play(episode) },
                            headlineContent = { Text("${episode.number}. ${episode.subtitle ?: "Episodio ${episode.number}"}", maxLines = 1) },
                            supportingContent = {
                                val notes = listOfNotNull(
                                    progress?.let { "Visto hasta ${formatTime(it)}" },
                                    if (watched) "Visto" else null,
                                    if (!episode.isAvailable(kind)) "Aún sin ${if (kind == "dub") "Dub" else "Sub"}" else null,
                                )
                                if (notes.isNotEmpty()) Text(notes.joinToString(" · "))
                            },
                        )
                    }
                }
            } else {
                Text(error ?: "Cargando episodios…", color = if (error != null) MaterialTheme.colorScheme.error else Color.White.copy(alpha = 0.7f))
            }
        }
    }
}
