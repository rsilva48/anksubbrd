@file:OptIn(androidx.tv.material3.ExperimentalTvMaterial3Api::class)

package com.personal.anksubbrd.tv

import android.content.Intent
import android.net.Uri
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.core.content.FileProvider
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
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray

private const val APK_NAME = "AniBridgePlayer-TV.apk"
private const val MAX_APK_BYTES = 200L * 1024 * 1024
private val http = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS)
    .readTimeout(60, TimeUnit.SECONDS).followSslRedirects(false).build()

private data class TVUpdate(val version: List<Int>, val tag: String, val url: String, val digest: String)

private fun versionOf(value: String): List<Int>? {
    val parts = Regex("^v?(\\d+)\\.(\\d+)\\.(\\d+)$").matchEntire(value)?.groupValues ?: return null
    return parts.drop(1).map { it.toIntOrNull() ?: return null }
}

private fun newer(a: List<Int>, b: List<Int>): Boolean =
    a.zip(b).firstOrNull { (x, y) -> x != y }?.let { (x, y) -> x > y } ?: false

// Android-only releases deliberately do not replace GitHub's iOS "latest".
// Find the newest stable release containing an APK instead.
private suspend fun findUpdate(installed: String): TVUpdate? = withContext(Dispatchers.IO) {
    val current = versionOf(installed) ?: error("Versión instalada desconocida")
    val request = Request.Builder().url("https://api.github.com/repos/rsilva48/anksubbrd/releases?per_page=100")
        .header("Accept", "application/vnd.github+json").build()
    http.newCall(request).execute().use { response ->
        if (!response.isSuccessful) error("GitHub respondió ${response.code}")
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

private suspend fun downloadUpdate(context: android.content.Context, update: TVUpdate): File = withContext(Dispatchers.IO) {
    val directory = File(context.cacheDir, "updates").apply { mkdirs() }
    val file = File(directory, APK_NAME)
    try {
        val digest = MessageDigest.getInstance("SHA-256")
        http.newCall(Request.Builder().url(update.url).build()).execute().use { response ->
            if (!response.isSuccessful) error("No se pudo descargar el APK (${response.code})")
            val body = response.body
            if (body.contentLength() > MAX_APK_BYTES) error("El APK es demasiado grande")
            var total = 0L
            body.byteStream().use { input -> file.outputStream().use { output ->
                val buffer = ByteArray(32 * 1024)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    if (total > MAX_APK_BYTES) error("El APK es demasiado grande")
                    digest.update(buffer, 0, count)
                    output.write(buffer, 0, count)
                }
            } }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (actual != update.digest) error("El APK no coincide con la huella publicada por GitHub")
        file
    } catch (e: Exception) {
        file.delete()
        throw e
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

    suspend fun check(manual: Boolean) {
        busy = true
        try {
            val current = context.packageManager.getPackageInfo(context.packageName, 0).versionName.orEmpty()
            update = findUpdate(current)
            if (update != null) { message = null; show = true }
            else if (manual) { message = "No hay una actualización disponible."; show = true }
        } catch (e: CancellationException) { throw e }
        catch (e: Exception) { if (manual) { message = "No se pudo buscar: ${e.message}"; show = true } }
        finally { busy = false }
    }

    // Automatic checks at most every 6 hours: GitHub allows 60 anonymous
    // API requests per hour per IP. The button always checks.
    LaunchedEffect(Unit) {
        val storage = context.getSharedPreferences("anksubbrd", android.content.Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        if (now - storage.getLong("updates.lastCheck", 0) < 6 * 60 * 60 * 1000L) return@LaunchedEffect
        storage.edit().putLong("updates.lastCheck", now).apply()
        check(false)
    }
    OutlinedButton(onClick = { scope.launch { check(true) } }, enabled = !busy) {
        Text(if (busy) "Buscando…" else "Actualizaciones")
    }
    if (show) Dialog(onDismissRequest = { if (!busy) show = false }) {
        Surface(shape = RoundedCornerShape(24.dp)) {
            Column(Modifier.padding(32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(update?.let { "Actualización ${it.tag}" } ?: "Actualizaciones", style = MaterialTheme.typography.titleLarge)
                Text(message ?: "Hay una versión nueva para Android TV. Android pedirá confirmar la instalación.")
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    update?.let { candidate ->
                        Button(enabled = !busy, onClick = {
                            if (!context.packageManager.canRequestPackageInstalls()) {
                                message = "Permite instalar aplicaciones desde esta app y luego vuelve a pulsar Instalar."
                                try {
                                    context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}")))
                                } catch (e: Exception) { message = "No se pudo abrir el permiso de instalación: ${e.message}" }
                            } else scope.launch {
                                busy = true
                                try {
                                    val file = downloadUpdate(context, candidate)
                                    val uri = FileProvider.getUriForFile(context, "${context.packageName}.updates", file)
                                    context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                                } catch (e: CancellationException) { throw e }
                                catch (e: Exception) { message = "No se pudo instalar: ${e.message}" }
                                finally { busy = false }
                            }
                        }) { Text(if (busy) "Descargando…" else "Instalar") }
                    }
                    OutlinedButton(enabled = !busy, onClick = { show = false }) { Text("Cerrar") }
                }
            }
        }
    }
}
