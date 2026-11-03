@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.personal.anksubbrd.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private fun DeviceState.isActive(): Boolean = status != "idle" && seriesTitle != null

private fun DeviceState.isShowing(command: RemoteCommand): Boolean =
    status != "idle" && episode == command.episode && watchUrl != null && command.watchUrl != null &&
        catalogPath(watchUrl) == catalogPath(command.watchUrl)

/**
 * The TV remote, as on iOS: the chosen TV is remembered until
 * "Desconectar"; opening it only shows the TV's state, and an episode chosen
 * with "Ver en TV" is sent once (never restarting what the TV shows).
 */
@Composable
internal fun PhoneRemoteSheet(app: PhoneState, session: Session) {
    val scope = rememberCoroutineScope()
    var tvs by remember { mutableStateOf<List<RemoteTv>>(emptyList()) }
    var receivedAt by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    var loaded by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var pending by remember { mutableStateOf(app.tvPlay) }
    var scrub by remember { mutableStateOf<Float?>(null) }
    var seekTarget by remember { mutableStateOf<Pair<Double, Long>?>(null) }
    val connected = app.connectedTv
    val tv = tvs.firstOrNull { it.id == connected?.id }

    fun close() {
        app.remoteOpen = false
        app.tvPlay = null
    }

    suspend fun refresh() {
        try {
            tvs = session.client.tvs()
            receivedAt = System.currentTimeMillis()
            error = null
        } catch (failure: BridgeException) {
            error = if (failure.status == 404) "Este bridge todavía no admite el control remoto. Actualízalo a la última versión." else failure.message
        }
        loaded = true
    }

    fun send(command: RemoteCommand, to: String) {
        scope.launch {
            try {
                session.client.sendCommand(to, command)
                delay(500)
                refresh()
            } catch (failure: BridgeException) {
                error = failure.message
            }
        }
    }

    /** The "Ver en TV" episode, once, unless the TV already shows it. */
    fun startPending(target: RemoteTv) {
        val request = pending ?: return
        if (!request.autoplay) return
        pending = null
        if (target.state?.isShowing(request.command) == true) return
        send(request.command, target.id)
    }

    LaunchedEffect(Unit) {
        while (true) {
            refresh()
            tvs.firstOrNull { it.id == app.connectedTv?.id }?.let(::startPending)
            delay(if (app.connectedTv == null) 3000 else 1500)
        }
    }
    LaunchedEffect(Unit) {
        while (true) {
            now = System.currentTimeMillis()
            delay(1000)
        }
    }

    ModalBottomSheet(onDismissRequest = ::close) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(connected?.name ?: "Ver en TV", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                if (connected != null) TextButton(onClick = { app.connect(null) }) { Text("Desconectar", color = MaterialTheme.colorScheme.error) }
            }
            when {
                connected == null -> {
                    Text("Conectar a una TV", style = MaterialTheme.typography.titleSmall)
                    if (tvs.isEmpty()) {
                        Text(
                            if (loaded) "No hay TVs conectadas. Abre AniBridge Player en la TV con un perfil vinculado a esta identidad." else "Buscando TVs…",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    tvs.forEach { item ->
                        ListItem(
                            headlineContent = { Text(item.name) },
                            supportingContent = { Text(summary(item.state)) },
                            leadingContent = { Icon(PhoneIcons.Tv, contentDescription = null) },
                            modifier = Modifier.clickable {
                                app.connect(ConnectedTv(item.id, item.name))
                                startPending(item)
                            },
                        )
                    }
                    Text("La app recordará la TV elegida hasta que pulses Desconectar.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                tv == null -> {
                    Text(
                        if (loaded) "${connected.name} no está disponible. Enciende la TV y abre AniBridge Player con un perfil vinculado a esta identidad." else "Conectando…",
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    val here = pending?.playHere
                    if (loaded && here != null) Button(onClick = { close(); here() }) { Text("Reproducir en este teléfono") }
                }
                else -> {
                    val state = tv.state
                    val request = pending
                    if (request != null && !request.autoplay && state?.isShowing(request.command) != true) {
                        Button(onClick = { pending = null; send(request.command, tv.id) }, modifier = Modifier.fillMaxWidth()) {
                            Icon(Icons.Filled.PlayArrow, null)
                            Text(" Reproducir en la TV")
                        }
                        Text(request.title, style = MaterialTheme.typography.bodySmall)
                    }
                    if (state != null && state.isActive()) {
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            AsyncImage(
                                model = state.imageUrl,
                                contentDescription = null,
                                contentScale = ContentScale.Crop,
                                modifier = Modifier.width(56.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(8.dp)).background(MaterialTheme.colorScheme.surfaceVariant),
                            )
                            Column {
                                Text(state.seriesTitle.orEmpty(), style = MaterialTheme.typography.titleMedium, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                state.episode?.let { episode ->
                                    Text(state.episodeTitle?.let { "Episodio $episode · $it" } ?: "Episodio $episode", style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                }
                                if (state.status == "loading") Text("Cargando en la TV…", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                            }
                        }
                        val duration = state.duration
                        if (duration != null && duration > 0) {
                            // Between reports (every 5 s while playing) the position advances here.
                            var position = state.position ?: 0.0
                            if (state.status == "playing") position += (tv.stateAge ?: 0.0) / 1000 + (now - receivedAt) / 1000.0
                            seekTarget?.let { (target, until) -> if (now < until && kotlin.math.abs(position - target) > 3) position = target }
                            val shown = scrub?.toDouble() ?: position.coerceIn(0.0, duration)
                            Slider(
                                value = shown.toFloat(),
                                onValueChange = { scrub = it },
                                valueRange = 0f..duration.toFloat(),
                                onValueChangeFinished = {
                                    scrub?.let { target ->
                                        seekTarget = target.toDouble() to System.currentTimeMillis() + 6000
                                        send(RemoteCommand(type = "seek", position = target.toDouble()), tv.id)
                                    }
                                    scrub = null
                                },
                            )
                            Row {
                                Text(formatTime(shown), style = MaterialTheme.typography.labelSmall, modifier = Modifier.weight(1f))
                                Text(formatTime(duration), style = MaterialTheme.typography.labelSmall)
                            }
                        }
                        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
                            IconButton(onClick = { send(RemoteCommand(type = "previous"), tv.id) }) { Icon(PhoneIcons.SkipPrevious, "Episodio anterior") }
                            IconButton(onClick = { send(RemoteCommand(type = "seek", seconds = -10.0), tv.id) }) { Icon(PhoneIcons.Replay10, "Retroceder 10 segundos") }
                            FilledIconButton(onClick = { send(RemoteCommand(type = "toggle"), tv.id) }, modifier = Modifier.size(56.dp)) {
                                Icon(if (state.status == "playing") PhoneIcons.Pause else Icons.Filled.PlayArrow, if (state.status == "playing") "Pausar" else "Reproducir")
                            }
                            IconButton(onClick = { send(RemoteCommand(type = "seek", seconds = 10.0), tv.id) }) { Icon(PhoneIcons.Forward10, "Adelantar 10 segundos") }
                            IconButton(onClick = { send(RemoteCommand(type = "next"), tv.id) }) { Icon(PhoneIcons.SkipNext, "Siguiente episodio") }
                        }
                        state.skip?.let { label -> OutlinedButton(onClick = { send(RemoteCommand(type = "skip"), tv.id) }) { Text(label) } }
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (state.subtitles.isNotEmpty()) {
                                var menu by remember { mutableStateOf(false) }
                                Box(Modifier.weight(1f)) {
                                    OutlinedButton(onClick = { menu = true }) {
                                        Icon(PhoneIcons.Subtitles, null)
                                        Text(" " + (state.subtitles.firstOrNull { it.id == state.subtitle }?.label ?: "Desactivados"), maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    }
                                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                        DropdownMenuItem(text = { Text("Desactivados") }, onClick = { menu = false; send(RemoteCommand(type = "subtitles", track = "off"), tv.id) })
                                        state.subtitles.forEach { track ->
                                            DropdownMenuItem(text = { Text(track.label) }, onClick = { menu = false; send(RemoteCommand(type = "subtitles", track = track.id), tv.id) })
                                        }
                                    }
                                }
                            } else {
                                Box(Modifier.weight(1f))
                            }
                            IconButton(onClick = { send(RemoteCommand(type = "volume", steps = -1), tv.id) }) { Icon(PhoneIcons.VolumeDown, "Bajar volumen de la TV") }
                            IconButton(onClick = { send(RemoteCommand(type = "volume", steps = 1), tv.id) }) { Icon(PhoneIcons.VolumeUp, "Subir volumen de la TV") }
                        }
                        TextButton(onClick = { send(RemoteCommand(type = "stop"), tv.id) }) {
                            Icon(PhoneIcons.Stop, null, tint = MaterialTheme.colorScheme.error)
                            Text(" Detener en la TV", color = MaterialTheme.colorScheme.error)
                        }
                    } else if (request == null || request.autoplay) {
                        Text("La TV no está reproduciendo nada. En la ficha de una serie, usa «Ver en TV» para empezar un episodio ahí.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    if (tv.canOpen == false && state?.isActive() != true) {
                        Text(
                            "La TV sólo empieza episodios con AniBridge Player en pantalla. Para que se abra sola, pulsa «Abrir desde el teléfono» en la app de la TV.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
        }
    }
}

private fun summary(state: DeviceState?): String {
    if (state == null || !state.isActive()) return "En espera"
    val episode = state.episode?.let { " · episodio $it" }.orEmpty()
    val status = when (state.status) { "playing" -> "Reproduciendo"; "loading" -> "Cargando"; else -> "En pausa" }
    return "$status: ${state.seriesTitle}$episode"
}
