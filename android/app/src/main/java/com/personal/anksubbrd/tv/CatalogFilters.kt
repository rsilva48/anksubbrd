@file:OptIn(ExperimentalTvMaterial3Api::class, ExperimentalLayoutApi::class)

package com.personal.anksubbrd.tv

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.tv.material3.Button
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.FilterChip
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Text
import java.util.Calendar
import kotlinx.serialization.Serializable

/**
 * Catalog filters, as on the phone: several values per category (a series
 * matches any of them), sent to the bridge as repeated query parameters.
 * The minimum score is applied here, to the results already loaded.
 */
data class CatalogFilters(
    val genres: Set<String> = emptySet(),
    val seasons: Set<String> = emptySet(),
    val years: Set<String> = emptySet(),
    val statuses: Set<String> = emptySet(),
    val mediaTypes: Set<String> = emptySet(),
    val sources: Set<String> = emptySet(),
    val ratings: Set<String> = emptySet(),
    /** Catalog order ("" = the bridge's default). */
    val sort: String = "",
    val episodes: EpisodeRange? = null,
    val minimumScore: Int = 0,
) {
    val isActive: Boolean get() = this != CatalogFilters()

    /** Chosen values, shown on the filter button. */
    val activeCount: Int
        get() = genres.size + seasons.size + years.size + statuses.size + mediaTypes.size + sources.size + ratings.size +
            listOf(sort.isNotEmpty(), episodes != null, minimumScore > 0).count { it }

    fun query(): List<Pair<String, String>> = buildList {
        listOf("genre" to genres, "season" to seasons, "year" to years, "status" to statuses, "mediaType" to mediaTypes, "source" to sources, "rating" to ratings)
            .forEach { (name, values) -> values.sorted().forEach { add(name to it) } }
        if (sort.isNotEmpty()) add("sort" to sort)
        episodes?.min?.let { add("minEpisodes" to it.toString()) }
        episodes?.max?.let { add("maxEpisodes" to it.toString()) }
    }

    fun allows(anime: Anime): Boolean = minimumScore == 0 || (anime.score ?: 0.0) >= minimumScore
}

/** Episode-count presets: typing numbers with a TV remote is slow. */
enum class EpisodeRange(val label: String, val min: Int?, val max: Int?) {
    Single("1 (película o especial)", 1, 1),
    Short("2 a 13", 2, 13),
    Season("12 a 26", 12, 26),
    Long("24 a 52", 24, 52),
    VeryLong("50 o más", 50, null),
}

@Serializable
data class FilterOption(val id: String, val label: String, val adult: Boolean = false)

/** Option lists published by the bridge; genre ids belong to the catalog. */
@Serializable
data class CatalogFilterOptions(
    val genres: List<FilterOption> = emptyList(),
    val mediaTypes: List<FilterOption> = emptyList(),
    val sources: List<FilterOption> = emptyList(),
    val sorts: List<FilterOption> = emptyList(),
)

internal object BuiltInFilters {
    val seasons = listOf("winter" to "Invierno", "spring" to "Primavera", "summer" to "Verano", "fall" to "Otoño").map { FilterOption(it.first, it.second) }
    val statuses = listOf("currently-airing" to "En emisión", "finished-airing" to "Finalizado", "not-yet-aired" to "Próximamente").map { FilterOption(it.first, it.second) }
    val ratings = listOf("G", "PG", "PG-13", "R", "R+", "Rx").map { FilterOption(it, it) }
    // For bridges without the option lists.
    val mediaTypes = listOf("TV", "Movie", "ONA", "OVA", "Special").map { FilterOption(it, it) }
    val years: List<FilterOption>
        get() = (Calendar.getInstance().get(Calendar.YEAR) + 1 downTo 1980).map { FilterOption(it.toString(), it.toString()) }
}

/** Short description of the active filters, shown next to the Filtros button. */
fun CatalogFilters.summary(options: CatalogFilterOptions?): String {
    fun labels(values: Set<String>, list: List<FilterOption>) = list.filter { it.id in values }.map { it.label }
    val parts = labels(genres, options?.genres.orEmpty()) + labels(seasons, BuiltInFilters.seasons) + years.sortedDescending() +
        labels(statuses, BuiltInFilters.statuses) + labels(mediaTypes, options?.mediaTypes ?: BuiltInFilters.mediaTypes) +
        labels(sources, options?.sources.orEmpty()) + ratings.sorted() + listOfNotNull(
            options?.sorts?.firstOrNull { it.id == sort }?.label,
            episodes?.let { "${it.label} episodios" },
            minimumScore.takeIf { it > 0 }?.let { "★ $it+" },
        )
    return parts.joinToString(" · ")
}

/**
 * Full-screen filter picker: one row of chips per category, navigable with
 * the D-pad. Choices apply only with "Aplicar".
 */
@Composable
fun CatalogFiltersDialog(
    current: CatalogFilters,
    options: CatalogFilterOptions?,
    hideAdult: Boolean,
    onApply: (CatalogFilters) -> Unit,
    onDismiss: () -> Unit,
) {
    var draft by remember { mutableStateOf(current) }

    @Composable
    fun Section(title: String, list: List<FilterOption>, selected: Set<String>, update: (Set<String>) -> Unit) {
        if (list.isEmpty()) return
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                list.filter { !(hideAdult && it.adult) }.forEach { option ->
                    FilterChip(selected = option.id in selected, onClick = {
                        update(if (option.id in selected) selected - option.id else selected + option.id)
                    }) { Text(option.label) }
                }
            }
        }
    }

    @Composable
    fun <T> SingleChoice(title: String, choices: List<Pair<T, String>>, selected: T, update: (T) -> Unit) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                choices.forEach { (value, label) ->
                    FilterChip(selected = value == selected, onClick = { update(value) }) { Text(label) }
                }
            }
        }
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(Color(0xFF0B0B12)).padding(horizontal = 64.dp, vertical = 40.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Filtros", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(end = 24.dp))
                Button(onClick = { onApply(draft) }) { Text("Aplicar") }
                OutlinedButton(onClick = { draft = CatalogFilters() }, enabled = draft.isActive) { Text("Limpiar") }
                OutlinedButton(onClick = onDismiss) { Text("Cancelar") }
            }
            Text(
                "Puedes elegir varias opciones en cada filtro: aparecen las series que cumplan cualquiera de ellas.",
                color = Color.White.copy(alpha = 0.6f),
            )
            LazyColumn(verticalArrangement = Arrangement.spacedBy(24.dp), contentPadding = PaddingValues(bottom = 48.dp)) {
                item { Section("Género", options?.genres.orEmpty(), draft.genres) { draft = draft.copy(genres = it) } }
                item { Section("Temporada", BuiltInFilters.seasons, draft.seasons) { draft = draft.copy(seasons = it) } }
                item { Section("Año", BuiltInFilters.years, draft.years) { draft = draft.copy(years = it) } }
                item { Section("Estado", BuiltInFilters.statuses, draft.statuses) { draft = draft.copy(statuses = it) } }
                item { Section("Tipo", options?.mediaTypes ?: BuiltInFilters.mediaTypes, draft.mediaTypes) { draft = draft.copy(mediaTypes = it) } }
                item { Section("Origen", options?.sources.orEmpty(), draft.sources) { draft = draft.copy(sources = it) } }
                item { Section("Clasificación", BuiltInFilters.ratings, draft.ratings) { draft = draft.copy(ratings = it) } }
                if (options != null) item {
                    SingleChoice("Episodios", listOf<EpisodeRange?>(null) .plus(EpisodeRange.entries).map { it to (it?.label ?: "Cualquiera") }, draft.episodes) {
                        draft = draft.copy(episodes = it)
                    }
                }
                item {
                    SingleChoice("Puntuación mínima", listOf(0, 5, 6, 7, 8, 9).map { it to if (it == 0) "Cualquiera" else "$it.0+" }, draft.minimumScore) {
                        draft = draft.copy(minimumScore = it)
                    }
                }
                if (options != null && options.sorts.isNotEmpty()) item {
                    SingleChoice("Ordenar por", listOf("" to "Predeterminado") + options.sorts.map { it.id to it.label }, draft.sort) {
                        draft = draft.copy(sort = it)
                    }
                }
            }
        }
    }
}
