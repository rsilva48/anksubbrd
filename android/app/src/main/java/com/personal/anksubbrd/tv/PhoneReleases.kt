package com.personal.anksubbrd.tv

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.Serializable

/** An episode the catalog expects to release (GET /api/schedule). */
@Serializable
data class ScheduleEntry(
    val watchUrl: String,
    val title: String,
    val titleJp: String? = null,
    val imageUrl: String? = null,
    val episode: Int,
    val kind: String,
    /** Unix seconds. */
    val airingAt: Double,
)

@Serializable
data class ScheduleReply(val entries: List<ScheduleEntry> = emptyList())

/**
 * Reminders of new episodes, as on iOS: for the series in Continue, in the
 * Sub/Dub kind being followed, after the episode last watched, five minutes
 * after the catalog's estimated time (at most 48). Rescheduled whenever the
 * app opens.
 */
internal object ReleaseReminders {
    private const val TAG = "release"
    private const val CHANNEL = "releases"
    private const val KEY_ENABLED = "releaseNotifications"
    private const val KEY_PROMPTED = "releaseNotificationsPrompted"

    /** A series to open from a tapped reminder. */
    val opened = MutableStateFlow<Anime?>(null)

    private fun prefs(context: Context) = context.getSharedPreferences("anksubbrd", Context.MODE_PRIVATE)

    fun isEnabled(context: Context) = prefs(context).getBoolean(KEY_ENABLED, false)
    fun wasPrompted(context: Context) = prefs(context).getBoolean(KEY_PROMPTED, false)
    fun markPrompted(context: Context) = prefs(context).edit().putBoolean(KEY_PROMPTED, true).apply()

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_ENABLED, enabled).putBoolean(KEY_PROMPTED, true).apply()
    }

    fun hasPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    suspend fun refresh(context: Context, session: Session?) {
        val work = WorkManager.getInstance(context)
        if (session == null || !isEnabled(context) || !hasPermission(context)) {
            work.cancelAllWorkByTag(TAG)
            return
        }
        // Offline or an older bridge: the reminders already scheduled stay.
        val entries = runCatching { session.client.schedule() }.getOrNull() ?: return
        val now = System.currentTimeMillis()
        val due = entries.mapNotNull { entry ->
            val at = ((entry.airingAt + 5 * 60) * 1000).toLong()
            val history = session.entry(entry.watchUrl) ?: return@mapNotNull null
            val kind = history.serverKind ?: session.preferences.defaultTrackType
            if (at <= now || entry.kind != kind || entry.episode <= history.episode) null else entry to at
        }.sortedBy { it.second }.take(48)
        work.cancelAllWorkByTag(TAG)
        for ((entry, at) in due) {
            val title = if (session.japanese) entry.titleJp ?: entry.title else entry.title
            val request = OneTimeWorkRequestBuilder<ReleaseWorker>()
                .setInitialDelay(at - now, TimeUnit.MILLISECONDS)
                .addTag(TAG)
                .setInputData(workDataOf(
                    "title" to title,
                    // The text is written when the reminder shows, in the app's language then.
                    "episode" to entry.episode,
                    "kind" to entry.kind,
                    "watchUrl" to entry.watchUrl,
                    "seriesTitle" to entry.title,
                    "titleJp" to entry.titleJp,
                    "imageUrl" to entry.imageUrl,
                ))
                .build()
            work.enqueueUniqueWork("release:${catalogPath(entry.watchUrl)}#${entry.episode}#${entry.kind}", ExistingWorkPolicy.REPLACE, request)
        }
    }

    fun channel(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        context.getSystemService(NotificationManager::class.java)
            .createNotificationChannel(NotificationChannel(CHANNEL, context.getString(R.string.releases_channel), NotificationManager.IMPORTANCE_DEFAULT))
    }

    /** Posts a reminder; tapping it opens the series. */
    fun notify(context: Context, title: String, body: String, anime: Anime) {
        if (!hasPermission(context)) return
        channel(context)
        val open = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            .putExtra(EXTRA_SERIES, BridgeClient.json.encodeToString(Anime.serializer(), anime))
        val pending = PendingIntent.getActivity(context, anime.watchUrl.hashCode(), open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setGroup(catalogPath(anime.watchUrl))
            .build()
        runCatching { NotificationManagerCompat.from(context).notify(anime.watchUrl.hashCode(), notification) }
    }

    const val EXTRA_SERIES = "com.personal.anksubbrd.tv.SERIES"
}

class ReleaseWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val watchUrl = inputData.getString("watchUrl") ?: return Result.success()
        val anime = Anime(
            title = inputData.getString("seriesTitle").orEmpty(),
            watchUrl = watchUrl,
            imageUrl = inputData.getString("imageUrl"),
            titleJp = inputData.getString("titleJp"),
        )
        val episode = inputData.getInt("episode", 0)
        val kind = if (inputData.getString("kind") == "dub") "Dub" else "Sub"
        // Reminders scheduled by older versions carry their text.
        val body = inputData.getString("body") ?: applicationContext.getString(R.string.release_body, episode, kind)
        ReleaseReminders.notify(applicationContext, inputData.getString("title").orEmpty(), body, anime)
        return Result.success()
    }
}
