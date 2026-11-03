@file:OptIn(androidx.tv.material3.ExperimentalTvMaterial3Api::class)

package com.personal.anksubbrd.tv

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.core.content.IntentCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.tv.material3.Button
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray

private const val APK_NAME = "AniBridgePlayer-TV.apk"
private val unknownAppsSetting: String get() = Strings.get(R.string.unknown_apps_setting)
private const val MAX_APK_BYTES = 200L * 1024 * 1024
private val http = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS)
    .readTimeout(60, TimeUnit.SECONDS).followSslRedirects(false).build()

internal data class TVUpdate(val version: List<Int>, val tag: String, val url: String, val digest: String)

private fun versionOf(value: String): List<Int>? {
    val parts = Regex("^v?(\\d+)\\.(\\d+)\\.(\\d+)$").matchEntire(value)?.groupValues ?: return null
    return parts.drop(1).map { it.toIntOrNull() ?: return null }
}

private fun newer(a: List<Int>, b: List<Int>): Boolean =
    a.zip(b).firstOrNull { (x, y) -> x != y }?.let { (x, y) -> x > y } ?: false

// Android-only releases deliberately do not replace GitHub's iOS "latest".
// Find the newest stable release containing an APK instead.
internal suspend fun findUpdate(installed: String): TVUpdate? = withContext(Dispatchers.IO) {
    val current = versionOf(installed) ?: error(Strings.get(R.string.update_unknown_version))
    val request = Request.Builder().url("https://api.github.com/repos/rsilva48/anksubbrd/releases?per_page=100")
        .header("Accept", "application/vnd.github+json").build()
    http.newCall(request).execute().use { response ->
        if (!response.isSuccessful) error(Strings.get(R.string.update_github_status, response.code))
        val releases = JSONArray(response.body.string())
        var latest: TVUpdate? = null
        for (i in 0 until releases.length()) {
            val release = releases.getJSONObject(i)
            if (release.optBoolean("draft") || release.optBoolean("prerelease")) continue
            val tag = release.optString("tag_name")
            val version = versionOf(tag) ?: continue
            if (!newer(version, current) || (latest != null && !newer(version, latest.version))) continue
            val assets = release.optJSONArray("assets") ?: continue
            for (j in 0 until assets.length()) {
                val asset = assets.getJSONObject(j)
                if (asset.optString("name") != APK_NAME || asset.optString("state") != "uploaded") continue
                val url = asset.optString("browser_download_url")
                val expectedPrefix = "https://github.com/rsilva48/anksubbrd/releases/download/$tag/$APK_NAME"
                val digest = asset.optString("digest").removePrefix("sha256:")
                if (url != expectedPrefix || !digest.matches(Regex("[0-9a-f]{64}"))) continue
                latest = TVUpdate(version, tag, url, digest)
                break
            }
        }
        latest
    }
}

internal suspend fun downloadUpdate(context: Context, update: TVUpdate): File = withContext(Dispatchers.IO) {
    val directory = File(context.cacheDir, "updates").apply { mkdirs() }
    val file = File(directory, APK_NAME)
    try {
        val digest = MessageDigest.getInstance("SHA-256")
        http.newCall(Request.Builder().url(update.url).build()).execute().use { response ->
            if (!response.isSuccessful) error(Strings.get(R.string.update_download_failed, response.code))
            val body = response.body
            if (body.contentLength() > MAX_APK_BYTES) error(Strings.get(R.string.update_too_large))
            var total = 0L
            body.byteStream().use { input -> file.outputStream().use { output ->
                val buffer = ByteArray(32 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > MAX_APK_BYTES) error(Strings.get(R.string.update_too_large))
                    digest.update(buffer, 0, count)
                    output.write(buffer, 0, count)
                }
            } }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (actual != update.digest) error(Strings.get(R.string.update_digest_mismatch))
        file
    } catch (e: Exception) {
        file.delete()
        throw e
    }
}

/** Why the last install did not finish, reported by [UpdateResultReceiver]. */
private val installFailure = MutableStateFlow<String?>(null)

// A PackageInstaller session goes straight to the system confirmation; an
// ACTION_VIEW of the APK would also offer other apps that open APKs.
internal suspend fun installUpdate(context: Context, file: File) = withContext(Dispatchers.IO) {
    val installer = context.packageManager.packageInstaller
    val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        .apply { setAppPackageName(context.packageName) }
    val id = installer.createSession(params)
    try {
        installer.openSession(id).use { session ->
            session.openWrite(APK_NAME, 0, file.length()).use { output ->
                file.inputStream().use { it.copyTo(output) }
                session.fsync(output)
            }
            // The system fills in the result, so the intent must be mutable.
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            val result = PendingIntent.getBroadcast(context, id, Intent(context, UpdateResultReceiver::class.java), flags)
            session.commit(result.intentSender)
        }
    } catch (e: Exception) {
        installer.abandonSession(id)
        throw e
    }
}

/** Shows the system confirmation for the update and reports failures to the dialog. */
class UpdateResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_INTENT, Intent::class.java) ?: return
                context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            PackageInstaller.STATUS_SUCCESS -> installFailure.value = null
            PackageInstaller.STATUS_FAILURE_ABORTED -> installFailure.value = context.getString(R.string.install_cancelled)
            else -> installFailure.value = context.getString(
                R.string.install_failed,
                intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: context.getString(R.string.unknown_error),
            )
        }
    }
}

@Composable
fun TVUpdateControl() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var update by remember { mutableStateOf<TVUpdate?>(null) }
    var busy by remember { mutableStateOf(false) }
    var show by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    // Set while the user is in Settings granting "install unknown apps".
    var awaitingPermission by remember { mutableStateOf<TVUpdate?>(null) }

    suspend fun install(candidate: TVUpdate) {
        busy = true
        try {
            installUpdate(context, downloadUpdate(context, candidate))
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { message = context.getString(R.string.install_failed, e.message.orEmpty()) }
        finally { busy = false }
    }

    // Back from Settings: continue the install, or explain why it is still
    // not allowed (on TVs with a work profile the wrong copy is often listed).
    LifecycleResumeEffect(Unit) {
        awaitingPermission?.let { candidate ->
            awaitingPermission = null
            if (context.packageManager.canRequestPackageInstalls()) scope.launch { install(candidate) }
            else message = context.getString(R.string.not_allowed_yet, specialAccessHint(context, unknownAppsSetting))
        }
        onPauseOrDispose { }
    }

    suspend fun check(manual: Boolean) {
        busy = true
        try {
            val current = context.packageManager.getPackageInfo(context.packageName, 0).versionName.orEmpty()
            update = findUpdate(current)
            if (update != null) { message = null; show = true }
            else if (manual) { message = context.getString(R.string.no_update); show = true }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { if (manual) { message = context.getString(R.string.check_failed, e.message.orEmpty()); show = true } }
        finally { busy = false }
    }

    // Automatic checks at most every 6 hours: GitHub allows 60 anonymous
    // API requests per hour per IP. The button always checks.
    LaunchedEffect(Unit) {
        val storage = context.getSharedPreferences("anksubbrd", Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        if (now - storage.getLong("updates.lastCheck", 0) < 6 * 60 * 60 * 1000L) return@LaunchedEffect
        storage.edit().putLong("updates.lastCheck", now).apply()
        check(false)
    }
    LaunchedEffect(Unit) {
        installFailure.collect { failure ->
            if (failure != null) { message = failure; show = true; installFailure.value = null }
        }
    }
    OutlinedButton(onClick = { scope.launch { check(true) } }, enabled = !busy) {
        Text(stringResource(if (busy) R.string.checking else R.string.updates))
    }
    if (show) Dialog(onDismissRequest = { if (!busy) show = false }) {
        Surface(shape = RoundedCornerShape(24.dp)) {
            Column(Modifier.padding(32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(update?.let { stringResource(R.string.update_title, it.tag) } ?: stringResource(R.string.updates), style = MaterialTheme.typography.titleLarge)
                Text(message ?: stringResource(R.string.update_available_tv))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    update?.let { candidate ->
                        Button(enabled = !busy, onClick = {
                            if (!context.packageManager.canRequestPackageInstalls()) {
                                message = context.getString(R.string.install_permission_needed, specialAccessHint(context, unknownAppsSetting))
                                if (openSpecialAccess(context, Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)) awaitingPermission = candidate
                                else message = context.getString(R.string.open_setting_failed, unknownAppsSetting)
                            } else scope.launch { install(candidate) }
                        }) { Text(stringResource(if (busy) R.string.downloading else R.string.install)) }
                    }
                    OutlinedButton(enabled = !busy, onClick = { show = false }) { Text(stringResource(R.string.close)) }
                }
            }
        }
    }
}
