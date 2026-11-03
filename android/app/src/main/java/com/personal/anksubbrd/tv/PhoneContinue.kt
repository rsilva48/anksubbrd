@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)

package com.personal.anksubbrd.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import kotlinx.coroutines.launch

/**
 * Continue watching, in the same sections as on iOS and the TV: new
 * episodes first, then in progress, caught up and completed. Holding a
 * series offers to remove it (also on the other devices).
 */
@Composable
internal fun PhoneContinue(session: Session, onOpen: (Anime) -> Unit) {
    val app = LocalPhone.current
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf<HistoryEntry?>(null) }
    val entries = session.history
    val finished = entries.filter { it.isCompleted }.map { catalogPath(it.watchUrl) }.toSet()
    LaunchedEffect(finished) { session.loadStatuses() }
    val states = entries.associate { it.watchUrl to continueState(session, it) }
    fun title(entry: HistoryEntry) = if (session.japanese) entry.titleJp ?: entry.seriesTitle else entry.seriesTitle
    val sections = listOf(
        Triple("Nuevos episodios", null as String?, entries.filter { states[it.watchUrl]?.section == 0 }),
        Triple("En curso", null, entries.filter { states[it.watchUrl]?.section == 1 }),
        Triple("Al día", "Pasan a «Nuevos episodios» cuando sale el siguiente episodio en Sub o Dub, según lo que estabas viendo.", entries.filter { states[it.watchUrl]?.section == 2 }),
        Triple("Completados", null, entries.filter { states[it.watchUrl]?.section == 3 }),
    ).filter { it.third.isNotEmpty() }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Continuar viendo") },
            actions = {
                IconButton(onClick = { app.tvPlay = null; app.remoteOpen = true }) { Icon(PhoneIcons.Tv, contentDescription = "Ver en TV") }
            },
        )
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = { scope.launch { refreshing = true; session.refresh(); session.loadStatuses(); refreshing = false } },
            modifier = Modifier.fillMaxSize(),
        ) {
            if (entries.isEmpty()) {
                PhoneMessage("Nada para continuar", session.historyError ?: "Las series que reproduzcas con esta identidad aparecerán aquí con el segundo en que las dejaste.")
                return@PullToRefreshBox
            }
            LazyColumn(Modifier.fillMaxSize()) {
                for ((heading, footer, group) in sections) {
                    item(key = "section:$heading") {
                        Text(heading, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp))
                    }
                    items(group, key = { it.watchUrl }) { entry ->
                        val state = states.getValue(entry.watchUrl)
                        var menu by remember { mutableStateOf(false) }
                        Box {
                            ListItem(
                                headlineContent = { Text(title(entry), maxLines = 2, overflow = TextOverflow.Ellipsis) },
                                supportingContent = {
                                    Column {
                                        Text(
                                            state.label(entry),
                                            color = if (state.isNews) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                        Text(
                                            "${entry.serverName} · ${if (entry.serverKind == "dub") "Dub" else "Sub"}",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                                        )
                                    }
                                },
                                leadingContent = {
                                    AsyncImage(
                                        model = entry.imageUrl,
                                        contentDescription = null,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.width(56.dp).aspectRatio(2f / 3f).clip(RoundedCornerShape(8.dp)).background(MaterialTheme.colorScheme.surfaceVariant),
                                    )
                                },
                                modifier = Modifier.combinedClickable(
                                    onClick = {
                                        // A finished series with a new season opens that season.
                                        val next = (state as? ContinueState.NextSeason)?.season
                                        onOpen(next?.asAnime() ?: entry.asAnime())
                                    },
                                    onLongClick = { menu = true },
                                ),
                            )
                            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                                DropdownMenuItem(
                                    text = { Text("Quitar de Continuar") },
                                    leadingIcon = { Icon(Icons.Filled.Delete, contentDescription = null) },
                                    onClick = { menu = false; removing = entry },
                                )
                            }
                        }
                    }
                    footer?.let { text ->
                        item(key = "footer:$heading") {
                            Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
                        }
                    }
                }
            }
        }
    }

    removing?.let { entry ->
        AlertDialog(
            onDismissRequest = { removing = null },
            title = { Text("¿Quitar «${title(entry)}»?") },
            text = { Text("Se quita de Continuar también en tus otros dispositivos con esta identidad.") },
            confirmButton = {
                TextButton(onClick = {
                    removing = null
                    scope.launch { session.remove(entry) }
                }) { Text("Quitar") }
            },
            dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancelar") } },
        )
    }
}
