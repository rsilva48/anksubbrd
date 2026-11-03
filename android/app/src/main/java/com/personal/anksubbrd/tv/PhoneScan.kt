package com.personal.anksubbrd.tv

import android.content.Context
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.google.android.gms.tasks.Task
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine

/** A TV's QR read on the phone: a profile to use here, or a TV to pair with this identity. */
internal sealed interface ScannedLink {
    /** "Take to phone": anksubbrd://identity?bridge=&token=&label= */
    data class Identity(val bridge: String, val token: String, val label: String) : ScannedLink

    /** A TV pairing: anksubbrd://pair?bridge=&code= or the bridge's https://…/setup?code= page. */
    data class Pairing(val bridge: String, val code: String) : ScannedLink

    companion object {
        fun parse(text: String): ScannedLink? {
            val uri = runCatching { Uri.parse(text.trim()) }.getOrNull() ?: return null
            val scheme = uri.scheme?.lowercase()
            fun bridgeOf(value: String?): String? {
                val url = value?.let { runCatching { Uri.parse(it) }.getOrNull() } ?: return null
                val host = url.authority ?: return null
                return BridgeClient.canonicalUrl(url.scheme ?: return null, host)
            }
            if (scheme == "anksubbrd" && uri.host == "identity") {
                val bridge = bridgeOf(uri.getQueryParameter("bridge")) ?: return null
                val token = uri.getQueryParameter("token")?.lowercase()?.takeIf { Regex("^[a-f0-9]{64}$").matches(it) } ?: return null
                return Identity(bridge, token, uri.getQueryParameter("label")?.trim()?.ifEmpty { null } ?: Strings.get(R.string.default_profile_name))
            }
            val code = uri.getQueryParameter("code")?.takeIf { it.isNotBlank() } ?: return null
            if (scheme == "anksubbrd" && uri.host == "pair") return bridgeOf(uri.getQueryParameter("bridge"))?.let { Pairing(it, code) }
            if ((scheme == "https" || scheme == "http") && uri.path == "/setup") return bridgeOf(text.trim())?.let { Pairing(it, code) }
            return null
        }
    }
}

/** Links opened from the camera (MainActivity) wait here for the phone screens. */
internal object PhoneLinks {
    val pending = MutableStateFlow<ScannedLink?>(null)
}

private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { continuation ->
    addOnSuccessListener { continuation.resume(it) }
    addOnFailureListener { continuation.resumeWithException(it) }
    addOnCanceledListener { continuation.cancel() }
}

/**
 * Scans a TV's QR with Google's code scanner (no camera permission: the
 * scanner runs in Google Play services). Null when cancelled; throws when
 * the code is not one of this app's.
 */
internal suspend fun scanTvCode(context: Context): ScannedLink? {
    val options = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
    val barcode = runCatching { GmsBarcodeScanning.getClient(context, options).startScan().await() }.getOrElse {
        if (it is kotlinx.coroutines.CancellationException) return null
        throw BridgeException(Strings.get(R.string.scanner_failed, it.message.orEmpty()))
    }
    val text = barcode.rawValue ?: return null
    return ScannedLink.parse(text) ?: throw BridgeException(Strings.get(R.string.not_our_code))
}

/** Uses a TV profile on this phone (same Continue and preferences); a different bridge is tested first. */
@Composable
internal fun IdentityImportDialog(app: PhoneState, link: ScannedLink.Identity, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    val sameBridge = app.bridge == link.bridge
    val inUse = sameBridge && app.token == link.token
    val replaces = sameBridge && app.token != null && !inUse
    var confirmed by remember { mutableStateOf(!replaces) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(stringResource(R.string.use_profile_title, link.label)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (inUse) {
                    Text(stringResource(R.string.profile_in_use))
                } else {
                    Text(stringResource(R.string.use_profile_text))
                    if (!sameBridge) Text(
                        app.bridge?.let { stringResource(R.string.other_bridge_switch, link.bridge, it) }
                            ?: stringResource(R.string.connect_bridge, link.bridge),
                    )
                    if (replaces) Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable { confirmed = !confirmed }) {
                        Checkbox(checked = confirmed, onCheckedChange = { confirmed = it })
                        Text(stringResource(R.string.saved_current_token_replace))
                    }
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            if (!inUse) TextButton(enabled = confirmed && !busy, onClick = {
                busy = true
                error = null
                scope.launch {
                    try {
                        if (!sameBridge) {
                            if (!BridgeClient(link.bridge, "").health().ok) throw BridgeException(Strings.get(R.string.bridge_unexpected))
                            app.useBridge(link.bridge)
                        }
                        app.useToken(link.token)
                        app.session?.refresh()
                        onDismiss()
                    } catch (failure: BridgeException) {
                        error = failure.message
                    } finally {
                        busy = false
                    }
                }
            }) { Text(stringResource(if (busy) R.string.connecting else R.string.use_this_profile)) }
        },
        dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text(stringResource(if (inUse) R.string.close else R.string.cancel)) } },
    )
}

/** Approves a TV pairing with this phone's identity: the TV shares its Continue and preferences. */
@Composable
internal fun PairTvDialog(app: PhoneState, link: ScannedLink.Pairing, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    var label by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var done by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val matches = app.bridge != null && app.bridge == link.bridge
    val defaultName = stringResource(R.string.default_profile_name)
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text(stringResource(R.string.link_a_tv)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                when {
                    done -> Text(stringResource(R.string.tv_linked, label.ifBlank { defaultName }))
                    !matches -> Text(stringResource(R.string.tv_other_bridge, link.bridge))
                    else -> {
                        Text(stringResource(R.string.link_tv_text))
                        OutlinedTextField(value = label, onValueChange = { label = it.take(40) }, label = { Text(stringResource(R.string.tv_profile_name)) }, placeholder = { Text(stringResource(R.string.tv_profile_placeholder)) }, singleLine = true)
                    }
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            if (matches && !done) TextButton(enabled = !busy, onClick = {
                busy = true
                error = null
                scope.launch {
                    try {
                        app.session?.client?.approvePairing(link.code, label.ifBlank { defaultName }) ?: throw BridgeException(Strings.get(R.string.setup_bridge_first))
                        done = true
                    } catch (failure: BridgeException) {
                        error = failure.message
                    } finally {
                        busy = false
                    }
                }
            }) { Text(stringResource(if (busy) R.string.linking else R.string.link_tv)) }
        },
        dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text(stringResource(if (done) R.string.done else R.string.cancel)) } },
    )
}
