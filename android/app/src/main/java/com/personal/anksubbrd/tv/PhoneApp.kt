@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.personal.anksubbrd.tv

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import coil3.compose.AsyncImage
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.CoroutineStart

/** The phone uses its own bridge identity; the token never goes into TV profile preferences. */
private class PhoneIdentity(context: Context) {
    private val prefs = context.getSharedPreferences("phone_identity", Context.MODE_PRIVATE)
    private val alias = "anibridge.phone.identity.v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    fun load(): Pair<String, String>? = runCatching {
        val url = prefs.getString("bridge", null) ?: return null
        val bytes = Base64.decode(prefs.getString("token", null) ?: return null, Base64.NO_WRAP)
        require(bytes.size > 12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        url to cipher.doFinal(bytes.copyOfRange(12, bytes.size)).toString(Charsets.UTF_8)
    }.getOrNull()
    fun save(url: String, token: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encoded = Base64.encodeToString(cipher.iv + cipher.doFinal(token.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
        prefs.edit().putString("bridge", url).putString("token", encoded).apply()
    }
}

@Composable
fun PhoneApp() {
    val context = LocalContext.current
    val dark = isSystemInDarkTheme()
    val colors = if (Build.VERSION.SDK_INT >= 31) {
        if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    } else if (dark) darkColorScheme(primary = Color(0xFFC4BEFF)) else lightColorScheme(primary = Color(0xFF5146C7))
    MaterialTheme(colorScheme = colors) {
        Surface(Modifier.fillMaxSize()) { PhoneRoot() }
    }
}

@Composable
private fun PhoneRoot() {
    val context = LocalContext.current
    val identity = remember { PhoneIdentity(context.applicationContext) }
    var credentials by remember { mutableStateOf(identity.load()) }
    var configuring by remember { mutableStateOf(credentials == null) }
    var confirmIdentityChange by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val session = remember(credentials) {
        credentials?.let { (url, token) ->
            val bytes = MessageDigest.getInstance("SHA-256").digest("$url\n$token".toByteArray())
            val scopeId = bytes.joinToString("") { "%02x".format(it) }
            Session(Profile(scopeId, "Teléfono", token), BridgeClient(url, token), context)
        }
    }
    var tab by remember { mutableIntStateOf(0) }
    var anime by remember { mutableStateOf<Anime?>(null) }
    var playback by remember { mutableStateOf<PlaybackRequest?>(null) }
    LaunchedEffect(session) { session?.refresh() }

    when {
        configuring -> PhoneSetup(credentials?.first.orEmpty(), onSave = { url, token ->
            identity.save(url, token)
            credentials = url to token
            configuring = false
        }, onCancel = if (credentials != null) ({ configuring = false }) else null)
        playback != null && session != null -> PhonePlayer(session, playback!!) { playback = null }
        anime != null && session != null -> PhoneDetails(session, anime!!, onBack = { anime = null }, onPlay = { playback = it })
        session != null -> Scaffold(
            topBar = { TopAppBar(title = { Text("AniBridge Player") }) },
            bottomBar = {
                NavigationBar {
                    listOf("Continuar", "Recientes", "Buscar", "Ajustes").forEachIndexed { index, label ->
                        NavigationBarItem(selected = tab == index, onClick = { tab = index },
                            icon = { Text(listOf("▶", "◷", "⌕", "⚙")[index]) }, label = { Text(label) })
                    }
                }
            },
        ) { padding ->
            Box(Modifier.fillMaxSize().padding(padding)) {
                when (tab) {
                    0 -> PhoneHistory(session, onOpen = { anime = it }, onRefresh = { scope.launch { session.refresh() } })
                    1 -> PhoneCatalog(session, searching = false, onOpen = { anime = it })
                    2 -> PhoneCatalog(session, searching = true, onOpen = { anime = it })
                    else -> Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        Text("Bridge", style = MaterialTheme.typography.titleLarge)
                        Text(credentials?.first.orEmpty())
                        Text("El historial y las preferencias se sincronizan con la identidad configurada en el bridge.")
                        OutlinedButton(onClick = { confirmIdentityChange = true }) { Text("Cambiar conexión o identidad") }
                    }
                }
            }
        }
    }
    if (confirmIdentityChange) AlertDialog(
        onDismissRequest = { confirmIdentityChange = false },
        title = { Text("¿Cambiar identidad?") },
        text = { Text("Guarda tu token actual antes de continuar. Si lo reemplazas y no tienes una copia, podrías perder acceso a tu historial. La nueva conexión solo se guardará tras probarla.") },
        confirmButton = { TextButton(onClick = { confirmIdentityChange = false; configuring = true }) { Text("Continuar") } },
        dismissButton = { TextButton(onClick = { confirmIdentityChange = false }) { Text("Cancelar") } },
    )
}

@Composable
private fun PhoneSetup(initialUrl: String, onSave: (String, String) -> Unit, onCancel: (() -> Unit)?) {
    var url by remember { mutableStateOf(initialUrl) }
    var token by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("Conecta tu bridge", style = MaterialTheme.typography.headlineMedium)
        Text("Usa la dirección y el token de tu identidad. El token se cifra con Android Keystore en este dispositivo.")
        OutlinedTextField(value = url, onValueChange = { url = it }, label = { Text("Dirección del bridge") }, singleLine = true, modifier = Modifier.fillMaxWidth())
        OutlinedTextField(value = token, onValueChange = { token = it }, label = { Text("Token de identidad") }, visualTransformation = PasswordVisualTransformation(), singleLine = true, modifier = Modifier.fillMaxWidth())
        error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
        Button(enabled = !busy, onClick = {
            scope.launch {
                busy = true
                try {
                    val raw = url.trim()
                    val scheme = if (raw.startsWith("http://")) "http" else "https"
                    val base = BridgeClient.canonicalUrl(scheme, raw) ?: throw BridgeException("La dirección no es válida.")
                    val client = BridgeClient(base, token.trim())
                    if (!client.health().ok) throw BridgeException("El bridge no respondió correctamente.")
                    client.history() // Validates the identity before replacing the previous one.
                    onSave(base, token.trim())
                } catch (e: Exception) { error = e.message ?: "No se pudo conectar." }
                finally { busy = false }
            }
        }) { Text(if (busy) "Conectando…" else "Probar y guardar") }
        onCancel?.let { OutlinedButton(onClick = it) { Text("Cancelar") } }
    }
}

@Composable
private fun PhoneHistory(session: Session, onOpen: (Anime) -> Unit, onRefresh: () -> Unit) {
    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Text("Continuar viendo", style = MaterialTheme.typography.headlineSmall)
            TextButton(onClick = onRefresh) { Text("Actualizar") }
        } }
        if (session.history.isEmpty()) item { Text(session.historyError ?: "Tu historial aparecerá aquí.") }
        items(session.history, key = { it.watchUrl }) { entry ->
            PhoneAnimeRow(entry.asAnime(), "Episodio ${entry.episode} · ${formatTime(entry.positionSeconds)}", session.japanese) { onOpen(entry.asAnime()) }
        }
    }
}

@Composable
private fun PhoneAnimeRow(anime: Anime, subtitle: String, japanese: Boolean, onClick: () -> Unit) {
    ListItem(modifier = Modifier.clickable(onClick = onClick), headlineContent = { Text(anime.displayTitle(japanese), maxLines = 2, overflow = TextOverflow.Ellipsis) },
        supportingContent = { if (subtitle.isNotBlank()) Text(subtitle) },
        leadingContent = { AsyncImage(model = anime.imageUrl, contentDescription = null, modifier = Modifier.size(width = 58.dp, height = 82.dp)) })
}

@Composable
private fun PhoneCatalog(session: Session, searching: Boolean, onOpen: (Anime) -> Unit) {
    var text by remember { mutableStateOf("") }
    var query by remember { mutableStateOf("") }
    var results by remember { mutableStateOf<List<Anime>>(emptyList()) }
    var page by remember { mutableIntStateOf(0) }
    var more by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    suspend fun load(n: Int) {
        if (searching && query.isBlank()) return
        busy = true
        try {
            val response = session.client.latest(n, language = if (searching) null else session.preferences.defaultTrackType, keyword = if (searching) query else null)
            results = if (n == 1) response.results else (results + response.results).distinctBy { it.watchUrl }
            page = n; more = response.hasNext; error = null
        } catch (e: BridgeException) { error = e.message }
        finally { busy = false }
    }
    LaunchedEffect(searching, query) { results = emptyList(); load(1) }
    LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item {
            if (searching) Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(text, { text = it }, label = { Text("Buscar anime") }, singleLine = true, modifier = Modifier.weight(1f))
                TextButton(onClick = { query = text.trim() }) { Text("Buscar") }
            } else Text("Episodios recientes", style = MaterialTheme.typography.headlineSmall)
        }
        error?.let { message -> item { Text(message, color = MaterialTheme.colorScheme.error) } }
        items(results.filter { !(session.preferences.hideAdult && it.isAdult) }, key = { it.watchUrl }) { anime ->
            PhoneAnimeRow(anime, anime.episode?.let { "Episodio $it" }.orEmpty(), session.japanese) { onOpen(anime) }
        }
        if (more || busy) item { TextButton(enabled = !busy, onClick = { scope.launch { load(page + 1) } }) { Text(if (busy) "Cargando…" else "Cargar más") } }
    }
}

@Composable
private fun PhoneDetails(session: Session, anime: Anime, onBack: () -> Unit, onPlay: (PlaybackRequest) -> Unit) {
    var series by remember(anime) { mutableStateOf<Series?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    BackHandler(onBack = onBack)
    LaunchedEffect(anime.watchUrl) { try { series = session.client.series(anime.watchUrl) } catch (e: BridgeException) { error = e.message } }
    Scaffold(topBar = { TopAppBar(title = { Text(anime.displayTitle(session.japanese), maxLines = 1) }, navigationIcon = { TextButton(onClick = onBack) { Text("‹") } }) }) { padding ->
        LazyColumn(Modifier.padding(padding), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item { AsyncImage(model = anime.imageUrl, contentDescription = null, modifier = Modifier.height(220.dp).fillMaxWidth()) }
            series?.synopsis?.let { synopsis -> item { Text(synopsis, maxLines = 5, overflow = TextOverflow.Ellipsis) } }
            item { Text(if (busy) "Preparando episodio…" else error ?: if (series == null) "Cargando…" else "Episodios", style = MaterialTheme.typography.titleMedium) }
            series?.let { loaded -> items(loaded.episodes, key = { it.number }) { episode ->
                ListItem(modifier = Modifier.clickable(enabled = !busy) {
                    scope.launch {
                        busy = true
                        try {
                            val entry = session.entry(anime.watchUrl)
                            onPlay(session.resolve(anime, loaded, episode, entry?.serverKind ?: session.preferences.defaultTrackType, entry?.serverName))
                        } catch (e: BridgeException) { error = e.message }
                        finally { busy = false }
                    }
                }, headlineContent = { Text("Episodio ${episode.number}") }, supportingContent = { episode.subtitle?.let { Text(it) } })
            } }
        }
    }
}

@Composable
private fun PhonePlayer(session: Session, request: PlaybackRequest, onExit: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val player = remember { ExoPlayer.Builder(context).build() }
    fun save() {
        val seconds = player.currentPosition / 1000.0
        if (seconds <= 0) return
        val duration = player.duration.takeIf { it > 0 && it != C.TIME_UNSET }?.div(1000.0)
        val entry = HistoryEntry(seriesTitle = request.series.title, watchUrl = request.anime.watchUrl, imageUrl = request.anime.imageUrl,
            episode = request.episode.number, episodeTitle = request.episode.title, serverName = request.playback.serverName,
            positionSeconds = seconds, updatedAt = HistoryEntry.now(), titleJp = request.series.titleJp, serverKind = request.kind,
            durationSeconds = duration, completed = duration != null && seconds >= duration - minOf(120.0, duration * 0.1))
        // Persist locally before disposal cancels the screen's coroutine scope.
        scope.launch(start = CoroutineStart.UNDISPATCHED) { session.record(entry) }
    }
    LaunchedEffect(request) {
        player.setMediaItem(MediaItem.fromUri(request.playback.playbackUrl), (session.position(request.anime.watchUrl, request.episode.number) * 1000).toLong())
        player.prepare(); player.playWhenReady = true
        while (true) { delay(10_000); if (player.isPlaying) save() }
    }
    DisposableEffect(player) { onDispose { save(); player.release() } }
    BackHandler { onExit() }
    AndroidView(factory = { PlayerView(it).apply { this.player = player; setShowSubtitleButton(true) } }, modifier = Modifier.fillMaxSize())
}
