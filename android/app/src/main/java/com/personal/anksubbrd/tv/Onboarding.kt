@file:OptIn(ExperimentalTvMaterial3Api::class)

package com.personal.anksubbrd.tv

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.tv.material3.Button
import androidx.tv.material3.Card
import androidx.tv.material3.ExperimentalTvMaterial3Api
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Surface
import androidx.tv.material3.Text
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import java.net.URLEncoder
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Bridge address: scheme picker plus host (with port if needed). */
@Composable
fun SetupScreen(state: AppState, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    val current = state.bridgeUrl
    var scheme by remember { mutableStateOf(if (current?.startsWith("http://") == true) "http" else "https") }
    var host by remember { mutableStateOf(current?.substringAfter("://").orEmpty()) }
    var testing by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }

    fun test() {
        val url = BridgeClient.canonicalUrl(scheme, host) ?: run {
            message = "Escribe el dominio o la IP del bridge, por ejemplo bridge.midominio.com o 192.168.1.20:8787."
            return
        }
        testing = true
        message = null
        scope.launch {
            try {
                val health = state.anonymousClient(url).health()
                if (!health.ok) throw BridgeException("El bridge no respondió correctamente.")
                state.setBridge(url)
                onDone()
            } catch (error: BridgeException) {
                message = error.message
            } finally {
                testing = false
            }
        }
    }

    Column(Modifier.fillMaxSize().padding(horizontal = 96.dp, vertical = 64.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Text("Configura tu bridge", style = MaterialTheme.typography.displaySmall)
        Text(
            "Es la misma dirección que usas en la app del iPhone. Después, cada persona vincula su perfil escaneando un código con el teléfono.",
            style = MaterialTheme.typography.bodyLarge,
            color = Color.White.copy(alpha = 0.7f),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            listOf("https", "http").forEach { option ->
                if (scheme == option) {
                    Button(onClick = { scheme = option }) { Text("$option://") }
                } else {
                    OutlinedButton(onClick = { scheme = option }) { Text("$option://") }
                }
            }
        }
        TvTextField(
            value = host,
            onValueChange = { value ->
                // A pasted scheme moves to the picker, like on iOS.
                when {
                    value.startsWith("https://") -> { scheme = "https"; host = value.removePrefix("https://") }
                    value.startsWith("http://") -> { scheme = "http"; host = value.removePrefix("http://") }
                    else -> host = value
                }
            },
            placeholder = "bridge.midominio.com",
            keyboardType = KeyboardType.Uri,
            imeAction = ImeAction.Go,
            onSubmit = ::test,
        )
        Button(onClick = ::test, enabled = !testing) { Text(if (testing) "Probando…" else "Probar y guardar") }
        message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}

/** "Who is watching": one tile per paired profile, plus pairing a new one. */
@Composable
fun ProfilesScreen(state: AppState, onSelect: (Profile) -> Unit, onAdd: () -> Unit, onChangeBridge: () -> Unit) {
    var removing by remember { mutableStateOf<Profile?>(null) }

    Column(Modifier.fillMaxSize().padding(horizontal = 96.dp, vertical = 64.dp), verticalArrangement = Arrangement.spacedBy(32.dp)) {
        Text("¿Quién está viendo?", style = MaterialTheme.typography.displaySmall)
        LazyRow(horizontalArrangement = Arrangement.spacedBy(28.dp)) {
            items(state.profiles, key = { it.id }) { profile ->
                ProfileTile(name = profile.name, onClick = { onSelect(profile) }, onLongClick = { removing = profile })
            }
            item {
                ProfileTile(name = "Agregar perfil", symbol = "+", onClick = onAdd)
            }
        }
        Text(
            "Mantén pulsado un perfil para quitarlo. Bridge: ${state.bridgeUrl.orEmpty()}",
            style = MaterialTheme.typography.bodyMedium,
            color = Color.White.copy(alpha = 0.6f),
        )
        OutlinedButton(onClick = onChangeBridge) { Text("Cambiar bridge") }
    }

    removing?.let { profile ->
        Dialog(onDismissRequest = { removing = null }) {
            Surface(shape = RoundedCornerShape(24.dp)) {
                Column(Modifier.padding(32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Text("¿Quitar el perfil «${profile.name}» de esta TV?", style = MaterialTheme.typography.titleLarge)
                    Text("Su historial sigue en el bridge; puedes volver a vincularlo con el teléfono.", color = Color.White.copy(alpha = 0.7f))
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(onClick = { state.removeProfile(profile); removing = null }) { Text("Quitar") }
                        OutlinedButton(onClick = { removing = null }) { Text("Cancelar") }
                    }
                }
            }
        }
    }
}

@Composable
private fun ProfileTile(name: String, onClick: () -> Unit, symbol: String? = null, onLongClick: (() -> Unit)? = null) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Card(onClick = onClick, onLongClick = onLongClick, modifier = Modifier.size(150.dp), shape = androidx.tv.material3.CardDefaults.shape(CircleShape), scale = androidx.tv.material3.CardDefaults.scale(focusedScale = 1f)) {
            Box(Modifier.fillMaxSize().background(Color(0xFF4F46E5)), contentAlignment = Alignment.Center) {
                Text(symbol ?: name.take(1).uppercase(), fontSize = 56.sp, color = Color.White)
            }
        }
        Text(name, style = MaterialTheme.typography.titleMedium, maxLines = 1)
    }
}

/**
 * Pairing: shows a QR with this bridge and a one-time code. The phone app
 * (camera → anksubbrd://pair…) approves it with its identity, and this
 * screen receives that identity's token.
 */
@Composable
fun PairingScreen(state: AppState, onPaired: () -> Unit, onChangeBridge: () -> Unit) {
    var qr by remember { mutableStateOf<Bitmap?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    val bridge = state.bridgeUrl.orEmpty()

    LaunchedEffect(bridge) {
        val client = state.anonymousClient()
        // A new code whenever the previous one expires.
        while (true) {
            try {
                val pairing = client.startPairing()
                qr = qrBitmap("anksubbrd://pair?bridge=${URLEncoder.encode(bridge, "UTF-8")}&code=${URLEncoder.encode(pairing.code, "UTF-8")}")
                message = null
                while (true) {
                    delay(2000)
                    val status = runCatching { client.pairingStatus(pairing.pairingId) }.getOrNull() ?: continue
                    if (status.status == "approved") {
                        state.addProfile(status.label ?: "Perfil", status.token.orEmpty())
                        onPaired()
                        return@LaunchedEffect
                    }
                    if (status.status == "expired") break
                }
            } catch (error: BridgeException) {
                qr = null
                message = error.message
                delay(5000)
            }
        }
    }

    Row(Modifier.fillMaxSize().padding(horizontal = 96.dp, vertical = 64.dp), horizontalArrangement = Arrangement.spacedBy(64.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(320.dp).background(Color.White, RoundedCornerShape(16.dp)).padding(16.dp), contentAlignment = Alignment.Center) {
            qr?.let { Image(it.asImageBitmap(), contentDescription = "Código QR para vincular", modifier = Modifier.fillMaxSize()) }
                ?: Text("Generando código…", color = Color.Black)
        }
        Column(verticalArrangement = Arrangement.spacedBy(16.dp), modifier = Modifier.width(560.dp)) {
            Text("Vincula un perfil", style = MaterialTheme.typography.displaySmall)
            Text("1. Abre la cámara del iPhone y apunta al código.", style = MaterialTheme.typography.titleMedium)
            Text("2. Toca el aviso para abrir la app y elige el nombre del perfil.", style = MaterialTheme.typography.titleMedium)
            Text("3. Pulsa «Vincular TV». Esta pantalla continúa sola.", style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(8.dp))
            Text(
                "El perfil usará la identidad del teléfono: el mismo Continuar viendo y las mismas preferencias. El código cambia cada 10 minutos.",
                color = Color.White.copy(alpha = 0.65f),
            )
            Text("Bridge: $bridge", color = Color.White.copy(alpha = 0.5f))
            message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            OutlinedButton(onClick = onChangeBridge) { Text("Cambiar bridge") }
        }
    }
}

private fun qrBitmap(text: String, size: Int = 512): Bitmap {
    val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, size, size, mapOf(EncodeHintType.MARGIN to 1))
    val pixels = IntArray(size * size) { index -> if (matrix[index % size, index / size]) 0xFF000000.toInt() else 0xFFFFFFFF.toInt() }
    return Bitmap.createBitmap(pixels, size, size, Bitmap.Config.ARGB_8888)
}

/** A text field that works with the TV keyboard (and voice input). */
@Composable
fun TvTextField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    modifier: Modifier = Modifier,
    keyboardType: KeyboardType = KeyboardType.Text,
    imeAction: ImeAction = ImeAction.Done,
    onSubmit: () -> Unit = {},
) {
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        singleLine = true,
        textStyle = TextStyle(color = Color.White, fontSize = 22.sp),
        cursorBrush = SolidColor(Color.White),
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = imeAction, autoCorrectEnabled = false),
        keyboardActions = KeyboardActions(onAny = { onSubmit() }),
        modifier = modifier.fillMaxWidth(),
        decorationBox = { inner ->
            Box(Modifier.background(Color.White.copy(alpha = 0.1f), RoundedCornerShape(12.dp)).padding(horizontal = 20.dp, vertical = 16.dp)) {
                if (value.isEmpty()) Text(placeholder, color = Color.White.copy(alpha = 0.4f), fontSize = 22.sp)
                inner()
            }
        },
    )
}
