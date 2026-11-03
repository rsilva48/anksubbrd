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
    /** "Llevar al teléfono": anksubbrd://identity?bridge=&token=&label= */
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
                return Identity(bridge, token, uri.getQueryParameter("label")?.trim()?.ifEmpty { null } ?: "Perfil")
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
        throw BridgeException("No se pudo abrir el escáner: ${it.message}")
    }
    val text = barcode.rawValue ?: return null
    return ScannedLink.parse(text) ?: throw BridgeException("Ese código no es de AniBridge Player.")
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
        title = { Text("Usar el perfil «${link.label}»") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (inUse) {
                    Text("Este teléfono ya usa ese perfil.")
                } else {
                    Text("Este teléfono usará el mismo Continuar viendo y las mismas preferencias que ese perfil.")
                    if (!sameBridge) Text(
                        if (app.bridge != null) "El código es del bridge ${link.bridge} y este teléfono usa ${app.bridge}. Al continuar, la app se conectará a ${link.bridge}."
                        else "Al continuar, la app se conectará al bridge ${link.bridge}.",
                    )
                    if (replaces) Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable { confirmed = !confirmed }) {
                        Checkbox(checked = confirmed, onCheckedChange = { confirmed = it })
                        Text("Ya guardé el token de la identidad actual (reemplaza la identidad de este teléfono)")
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
                            if (!BridgeClient(link.bridge, "").health().ok) throw BridgeException("El bridge respondió de forma inesperada.")
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
            }) { Text(if (busy) "Conectando…" else "Usar este perfil") }
        },
        dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text(if (inUse) "Cerrar" else "Cancelar") } },
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
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text("Vincular una TV") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                when {
                    done -> Text("Listo: la TV ya tiene el perfil «${label.ifBlank { "Perfil" }}».")
                    !matches -> Text("La TV usa el bridge ${link.bridge}, que no es el configurado aquí. Configura y prueba ese mismo bridge en Ajustes y vuelve a escanear el código.")
                    else -> {
                        Text("La TV usará la identidad activa de este teléfono: el mismo historial de Continuar viendo y las mismas preferencias. En la TV aparecerá como un perfil.")
                        OutlinedTextField(value = label, onValueChange = { label = it.take(40) }, label = { Text("Nombre del perfil en la TV") }, placeholder = { Text("Por ejemplo, tu nombre") }, singleLine = true)
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
                        app.session?.client?.approvePairing(link.code, label.ifBlank { "Perfil" }) ?: throw BridgeException("Configura primero la dirección del bridge.")
                        done = true
                    } catch (failure: BridgeException) {
                        error = failure.message
                    } finally {
                        busy = false
                    }
                }
            }) { Text(if (busy) "Vinculando…" else "Vincular TV") }
        },
        dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text(if (done) "Listo" else "Cancelar") } },
    )
}
