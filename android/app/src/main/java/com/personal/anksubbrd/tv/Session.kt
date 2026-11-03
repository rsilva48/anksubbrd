package com.personal.anksubbrd.tv

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.serialization.builtins.ListSerializer

/** An episode ready to play, with what is needed to move to the next one. */
data class PlaybackRequest(
    val anime: Anime,
    val series: Series,
    val episode: Episode,
    val kind: String,
    val playback: Playback,
)

/** The active profile: its preferences and its watch history (shared with the phone). */
class Session(val profile: Profile, val client: BridgeClient, context: Context) {
    private val storage = context.applicationContext.getSharedPreferences("anksubbrd", Context.MODE_PRIVATE)
    private val historyKey = "history.${profile.id}"
    private val historySerializer = ListSerializer(HistoryEntry.serializer())
    var preferences by mutableStateOf(Preferences())
        private set
    var history by mutableStateOf(loadHistory())
        private set
    var historyError by mutableStateOf<String?>(null)
        private set

    val japanese: Boolean get() = preferences.titleLanguage == "jp"

    private fun loadHistory(): List<HistoryEntry> = storage.getString(historyKey, null)
        ?.let { runCatching { BridgeClient.json.decodeFromString(historySerializer, it) }.getOrNull() }
        ?: emptyList()

    private fun persistHistory() {
        storage.edit().putString(historyKey, BridgeClient.json.encodeToString(historySerializer, history)).apply()
    }

    fun initialLoadTimedOut() {
        if (history.isEmpty()) historyError = "No se pudo cargar el historial. Comprueba la conexión con el bridge."
    }

    suspend fun refresh() {
        runCatching { client.preferences() }.onSuccess { preferences = it }
        try {
            history = client.history().entries.sortedByDescending { it.updatedAt }
            persistHistory()
            historyError = null
        } catch (error: BridgeException) {
            historyError = error.message
        }
    }

    fun entry(watchUrl: String): HistoryEntry? = history.firstOrNull { catalogPath(it.watchUrl) == catalogPath(watchUrl) }

    /** Where an episode resumes; a finished episode starts over. */
    fun position(watchUrl: String, episode: Int): Double =
        entry(watchUrl)?.takeIf { it.episode == episode && !it.isCompleted }?.positionSeconds ?: 0.0

    /** Saves progress locally and on the bridge (newest wins there). */
    suspend fun record(entry: HistoryEntry) {
        history = listOf(entry) + history.filterNot { catalogPath(it.watchUrl) == catalogPath(entry.watchUrl) }
        persistHistory()
        runCatching { client.saveHistory(listOf(entry)) }
    }

    /** Removes a series from Continue, here and (as a deletion) on the bridge and the phone. */
    suspend fun remove(entry: HistoryEntry) {
        history = history.filterNot { catalogPath(it.watchUrl) == catalogPath(entry.watchUrl) }
        persistHistory()
        runCatching { client.saveHistory(emptyList(), listOf(HistoryDeletion(entry.watchUrl, HistoryEntry.now()))) }
    }

    /**
     * Resolves an episode: the preferred server first, then the other
     * servers of the same kind (servers differ between episodes and can
     * fail), then any. An expired series session is reloaded once.
     */
    suspend fun resolve(anime: Anime, series: Series, episode: Episode, kind: String, preferredServer: String?): PlaybackRequest {
        var current = series
        suspend fun <T> retrying(block: suspend (Series) -> T): T = try {
            block(current)
        } catch (error: BridgeException) {
            if (error.status != 410) throw error
            current = client.series(anime.watchUrl)
            block(current)
        }

        val servers = retrying { client.servers(it.seriesKey, episode.number) }
        val ofKind = servers.filter { it.type == kind }
        val ordered = ofKind.filter { it.name == preferredServer } + ofKind.filter { it.name != preferredServer } + servers.filter { it.type != kind }
        if (ordered.isEmpty()) throw BridgeException("El episodio ${episode.number} no publicó servidores.")
        var lastError: Exception? = null
        for (server in ordered) {
            try {
                val playback = retrying { client.play(it.seriesKey, episode.number, server.index) }
                return PlaybackRequest(anime, current, episode, playback.serverKind ?: server.type, playback)
            } catch (error: BridgeException) {
                if (error.offline) throw error
                lastError = error
            }
        }
        throw lastError ?: BridgeException("No se pudo abrir el episodio ${episode.number}.")
    }
}
