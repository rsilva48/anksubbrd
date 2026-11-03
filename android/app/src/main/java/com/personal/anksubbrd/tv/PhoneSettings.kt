@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.personal.anksubbrd.tv

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import java.security.SecureRandom
import java.util.Locale
import kotlinx.coroutines.launch

private val subtitleLanguages = listOf("en", "es", "pt", "fr", "de", "it")

/** Bridge, private identity, synced preferences and updates. */
@Composable
internal fun PhoneSettings(app: PhoneState) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val session = app.session
    var scheme by remember { mutableStateOf(if (app.bridge?.startsWith("http://") == true) "http" else "https") }
    var host by remember { mutableStateOf(app.bridge?.substringAfter("://").orEmpty()) }
    var testing by remember { mutableStateOf(false) }
    var bridgeMessage by remember { mutableStateOf<String?>(null) }
    var dialog by remember { mutableStateOf<IdentityDialog?>(null) }

    fun test() {
        val url = BridgeClient.canonicalUrl(scheme, host.trim()) ?: run {
            bridgeMessage = "Escribe el dominio o la IP del bridge, por ejemplo bridge.midominio.com o 192.168.1.20:8787."
            return
        }
        testing = true
        bridgeMessage = null
        scope.launch {
            try {
                val health = BridgeClient(url, "").health()
                if (!health.ok) throw BridgeException("El bridge respondió de forma inesperada.")
                app.useBridge(url)
                val connected = listOfNotNull(health.version?.let { "bridge $it" }, health.provider).joinToString(" · ").let { if (it.isEmpty()) "Conectado." else "Conectado ($it)." }
                val needsIdentity = app.token == null && runCatching { BridgeClient(url, "").history() }.exceptionOrNull().let { it is BridgeException && it.status == 401 }
                bridgeMessage = if (needsIdentity) "$connected Este bridge requiere una identidad privada: créala o impórtala abajo." else "$connected Buscar, Recientes y Continuar ya están disponibles."
                app.session?.refresh()
            } catch (error: BridgeException) {
                bridgeMessage = error.message
            } finally {
                testing = false
            }
        }
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(title = { Text("Ajustes") })
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            SectionTitle("Bridge")
            Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                app.bridge?.let { Text("Activo: $it", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodyMedium) }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    var menu by remember { mutableStateOf(false) }
                    Box {
                        OutlinedButton(onClick = { menu = true }) { Text("$scheme://") }
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            listOf("https", "http").forEach { option -> DropdownMenuItem(text = { Text("$option://") }, onClick = { scheme = option; menu = false }) }
                        }
                    }
                    OutlinedTextField(
                        value = host,
                        onValueChange = { value ->
                            // A pasted scheme moves to the picker.
                            when {
                                value.startsWith("https://") -> { scheme = "https"; host = value.removePrefix("https://") }
                                value.startsWith("http://") -> { scheme = "http"; host = value.removePrefix("http://") }
                                else -> host = value
                            }
                        },
                        placeholder = { Text("bridge.midominio.com") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
                        keyboardActions = KeyboardActions(onGo = { test() }),
                        modifier = Modifier.weight(1f),
                    )
                }
                Button(onClick = ::test, enabled = !testing && host.isNotBlank()) { Text(if (testing) "Probando conexión…" else "Probar y guardar") }
                bridgeMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                Footer("Escribe sólo el dominio o la IP, con el puerto si hace falta (por ejemplo bridge.midominio.com o 192.168.1.20:8787). La dirección se guarda cuando la prueba responde.")
            }

            SectionTitle("Identidad privada")
            Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                when {
                    app.bridge == null -> Text("Primero prueba y guarda la dirección del bridge", color = MaterialTheme.colorScheme.error)
                    app.token != null -> {
                        Text("Identidad privada configurada", color = MaterialTheme.colorScheme.primary)
                        OutlinedButton(onClick = { dialog = IdentityDialog.Backup }) { Text("Respaldar token…") }
                        OutlinedButton(onClick = { dialog = IdentityDialog.Change }) { Text("Cambiar identidad…") }
                    }
                    else -> {
                        OutlinedButton(onClick = { dialog = IdentityDialog.Create }) { Text("Crear identidad privada…") }
                        OutlinedButton(onClick = { dialog = IdentityDialog.Import }) { Text("Importar token…") }
                    }
                }
                // A TV's "Llevar al teléfono" profile, or a TV pairing code.
                var scanError by remember { mutableStateOf<String?>(null) }
                OutlinedButton(onClick = {
                    scanError = null
                    scope.launch {
                        try {
                            scanTvCode(context)?.let { PhoneLinks.pending.value = it }
                        } catch (failure: BridgeException) {
                            scanError = failure.message
                        }
                    }
                }) { Text("Escanear código de la TV…") }
                scanError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                Footer("El token define tu historial y tus preferencias. Se guarda cifrado en este teléfono sólo para esta dirección; compártelo únicamente con los dispositivos que deban compartir lista y ajustes. El código de la TV puede ser un perfil («Llevar al teléfono») o la vinculación de una TV.")
            }

            val preferences = session?.preferences
            SectionTitle("Catálogo")
            ChoiceRow("Idioma de los títulos", listOf("en" to "Inglés", "jp" to "Japonés"), preferences?.titleLanguage ?: "en", enabled = session != null) { value ->
                scope.launch { session?.updatePreferences { it.copy(titleLanguage = value) } }
            }
            SwitchRow("Ocultar series +18", preferences?.hideAdult ?: false, enabled = session != null) { value ->
                scope.launch { session?.updatePreferences { it.copy(hideAdult = value) } }
            }
            Footer("En japonés, Continuar viendo mantiene el nombre en inglés y muestra debajo el título japonés. Ocultar series +18 quita de Recientes y Buscar las clasificadas R+ o Rx.", Modifier.padding(horizontal = 16.dp))

            SectionTitle("Reproducción")
            ChoiceRow("Servidores por defecto", listOf("sub" to "Sub", "dub" to "Dub"), preferences?.defaultTrackType ?: "sub", enabled = session != null) { value ->
                scope.launch { session?.updatePreferences { it.copy(defaultTrackType = value) } }
            }
            val languages = listOf("" to "Automático (idioma del dispositivo)") +
                subtitleLanguages.map { it to Locale.forLanguageTag(it).getDisplayLanguage(Locale.forLanguageTag("es")).replaceFirstChar(Char::titlecase) } +
                listOf("off" to "Desactivados")
            ChoiceRow("Subtítulos en Sub", languages, preferences?.subtitleLanguage ?: "", enabled = session != null) { value ->
                scope.launch { session?.updatePreferences { it.copy(subtitleLanguage = value) } }
            }
            SwitchRow("Reproducir el siguiente episodio", preferences?.autoNext ?: true, enabled = session != null) { value ->
                scope.launch { session?.updatePreferences { it.copy(autoNext = value) } }
            }
            SwitchRow("Saltar intro automáticamente", preferences?.autoSkipIntro ?: false, enabled = session != null) { value ->
                scope.launch { session?.updatePreferences { it.copy(autoSkipIntro = value) } }
            }
            SwitchRow("Saltar outro automáticamente", preferences?.autoSkipOutro ?: false, enabled = session != null) { value ->
                scope.launch { session?.updatePreferences { it.copy(autoSkipOutro = value) } }
            }
            Footer("Sub declara audio japonés y activa los subtítulos; Dub declara audio en inglés. Estas preferencias pertenecen a la identidad activa y se sincronizan con el bridge en tus otros dispositivos.", Modifier.padding(horizontal = 16.dp))

            SectionTitle("Este dispositivo")
            var reminders by remember { mutableStateOf(ReleaseReminders.isEnabled(context) && ReleaseReminders.hasPermission(context)) }
            var reminderError by remember { mutableStateOf<String?>(null) }
            val permission = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) { granted ->
                ReleaseReminders.setEnabled(context, granted)
                reminders = granted
                reminderError = if (granted) null else "Android no permite avisos de esta app. Actívalos en los ajustes del sistema → Notificaciones."
                scope.launch { ReleaseReminders.refresh(context, app.session) }
            }
            SwitchRow("Avisar de nuevos episodios", reminders, enabled = session != null) { value ->
                if (value && !ReleaseReminders.hasPermission(context) && android.os.Build.VERSION.SDK_INT >= 33) {
                    permission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
                } else {
                    ReleaseReminders.setEnabled(context, value)
                    reminders = value
                    scope.launch { ReleaseReminders.refresh(context, app.session) }
                }
            }
            reminderError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(horizontal = 16.dp)) }
            var autoDelete by remember { mutableStateOf(PhoneDownloads.autoDelete(context)) }
            SwitchRow("Borrar descargas ya vistas", autoDelete, enabled = true) { value ->
                PhoneDownloads.setAutoDelete(context, value)
                autoDelete = value
                if (value) PhoneDownloads.cleanUp(context, session)
            }
            val downloads by rememberDownloads()
            var confirmRemoveAll by remember { mutableStateOf(false) }
            ListItem(
                headlineContent = { Text("Espacio usado") },
                trailingContent = { Text(android.text.format.Formatter.formatShortFileSize(context, downloads.sumOf { it.bytes })) },
            )
            OutlinedButton(
                onClick = { confirmRemoveAll = true },
                enabled = downloads.isNotEmpty(),
                modifier = Modifier.padding(horizontal = 16.dp),
            ) { Text("Borrar todas las descargas", color = if (downloads.isNotEmpty()) MaterialTheme.colorScheme.error else androidx.compose.ui.graphics.Color.Unspecified) }
            if (confirmRemoveAll) AlertDialog(
                onDismissRequest = { confirmRemoveAll = false },
                title = { Text(if (downloads.size == 1) "¿Borrar 1 descarga?" else "¿Borrar ${downloads.size} descargas?") },
                text = { Text("Los episodios dejarán de estar disponibles sin conexión.") },
                confirmButton = {
                    TextButton(onClick = { PhoneDownloads.removeAll(context); confirmRemoveAll = false }) {
                        Text("Borrar todas", color = MaterialTheme.colorScheme.error)
                    }
                },
                dismissButton = { TextButton(onClick = { confirmRemoveAll = false }) { Text("Cancelar") } },
            )
            Footer("Una descarga se borra sólo cuando terminas de ver ese episodio (al llegar al outro o a sus últimos minutos), aquí o en otro dispositivo con la misma identidad. Abrir otro episodio no la borra. Los avisos usan el horario estimado del catálogo para las series de Continuar viendo (en el tipo Sub o Dub que sigues) y se reprograman cada vez que abres la app.", Modifier.padding(horizontal = 16.dp))

            SectionTitle("Acerca de")
            PhoneUpdates()
        }
    }

    when (dialog) {
        IdentityDialog.Backup -> TokenBackupDialog(app.token.orEmpty()) { dialog = null }
        IdentityDialog.Change -> ChangeIdentityDialog(onDismiss = { dialog = null }) { dialog = it }
        IdentityDialog.Import -> ImportTokenDialog(replaces = app.token != null, onDismiss = { dialog = null }) { token ->
            app.useToken(token)
            dialog = null
            scope.launch { app.session?.refresh() }
        }
        IdentityDialog.Create -> CreateIdentityDialog(app.bridge.orEmpty(), onDismiss = { dialog = null }) { token ->
            app.useToken(token)
            dialog = IdentityDialog.Backup
            scope.launch { app.session?.refresh() }
        }
        null -> Unit
    }
}

private enum class IdentityDialog { Backup, Change, Import, Create }

@Composable
private fun SectionTitle(text: String) {
    HorizontalDivider(Modifier.padding(top = 16.dp))
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(start = 16.dp, top = 12.dp, bottom = 4.dp))
}

@Composable
private fun Footer(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = modifier.padding(top = 4.dp))
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, enabled: Boolean, onChange: (Boolean) -> Unit) {
    ListItem(
        headlineContent = { Text(label) },
        trailingContent = { Switch(checked = checked, onCheckedChange = onChange, enabled = enabled) },
        modifier = Modifier.clickable(enabled = enabled) { onChange(!checked) },
    )
}

@Composable
private fun ChoiceRow(label: String, choices: List<Pair<String, String>>, selected: String, enabled: Boolean, onChange: (String) -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Box {
        ListItem(
            headlineContent = { Text(label) },
            supportingContent = { Text(choices.firstOrNull { it.first == selected }?.second ?: selected) },
            modifier = Modifier.clickable(enabled = enabled) { menu = true },
        )
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            choices.forEach { (value, text) -> DropdownMenuItem(text = { Text(text) }, onClick = { menu = false; onChange(value) }) }
        }
    }
}

@Composable
private fun TokenBackupDialog(token: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var understood by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Respaldar token") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Quien tenga este token puede acceder al historial y las preferencias asociados. No lo envíes por mensajes, correo ni capturas sin protección.")
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable { understood = !understood }) {
                    Checkbox(checked = understood, onCheckedChange = { understood = it })
                    Text("Entiendo el riesgo")
                }
                if (understood) Text(token, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
            }
        },
        confirmButton = {
            TextButton(enabled = understood, onClick = {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText("Token de AniBridge", token))
            }) { Text("Copiar") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cerrar") } },
    )
}

@Composable
private fun ChangeIdentityDialog(onDismiss: () -> Unit, onChoose: (IdentityDialog) -> Unit) {
    var saved by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Cambiar identidad") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Cambiar el token te convierte en otro usuario. El historial y las preferencias actuales seguirán en el servidor, pero este teléfono no podrá abrirlos de nuevo sin el token actual. No existe recuperación de cuenta.")
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable { saved = !saved }) {
                    Checkbox(checked = saved, onCheckedChange = { saved = it })
                    Text("Ya guardé el token actual de forma segura")
                }
                TextButton(onClick = { onChoose(IdentityDialog.Backup) }) { Text("Respaldar token actual…") }
            }
        },
        confirmButton = {
            Column {
                TextButton(enabled = saved, onClick = { onChoose(IdentityDialog.Create) }) { Text("Crear una identidad nueva") }
                TextButton(enabled = saved, onClick = { onChoose(IdentityDialog.Import) }) { Text("Usar un token existente") }
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancelar") } },
    )
}

@Composable
private fun ImportTokenDialog(replaces: Boolean, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var token by remember { mutableStateOf("") }
    var confirmed by remember { mutableStateOf(!replaces) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Importar token") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("Importa el token de otro dispositivo sólo si quieres acceder exactamente al mismo historial y a las mismas preferencias.")
                OutlinedTextField(
                    value = token,
                    onValueChange = { token = it.trim() },
                    label = { Text("Token de 64 caracteres") },
                    visualTransformation = PasswordVisualTransformation(),
                    singleLine = true,
                )
                if (replaces) Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable { confirmed = !confirmed }) {
                    Checkbox(checked = confirmed, onCheckedChange = { confirmed = it })
                    Text("Entiendo que esto reemplaza la identidad actual")
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(enabled = confirmed && token.isNotEmpty(), onClick = {
                if (!Regex("^[A-Fa-f0-9]{64}$").matches(token)) error = "El token debe contener 64 caracteres hexadecimales." else onSave(token.lowercase())
            }) { Text("Guardar") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancelar") } },
    )
}

/** The first identity of a phone: the bridge's administrator token registers a new random token (the admin token is not kept). */
@Composable
private fun CreateIdentityDialog(bridge: String, onDismiss: () -> Unit, onCreated: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var adminToken by remember { mutableStateOf("") }
    var label by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text("Nueva identidad") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("El token administrador se usa una sola vez para registrar esta identidad; no se guarda en el teléfono. Después respalda el token nuevo: no se puede recuperar si lo pierdes.")
                OutlinedTextField(value = adminToken, onValueChange = { adminToken = it.trim() }, label = { Text("Token administrador del bridge") }, visualTransformation = PasswordVisualTransformation(), singleLine = true)
                OutlinedTextField(value = label, onValueChange = { label = it.take(80) }, label = { Text("Etiqueta opcional") }, singleLine = true)
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(enabled = !busy && adminToken.isNotEmpty(), onClick = {
                busy = true
                error = null
                scope.launch {
                    try {
                        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
                        val token = bytes.joinToString("") { "%02x".format(it) }
                        BridgeClient(bridge, "").registerUser(adminToken, token, label.ifBlank { "Android" })
                        onCreated(token)
                    } catch (failure: BridgeException) {
                        error = failure.message
                    } finally {
                        busy = false
                    }
                }
            }) { Text(if (busy) "Registrando…" else "Registrar y usar") }
        },
        dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text("Cancelar") } },
    )
}

/** Version and updates from the GitHub releases (the same verified installer as the TV). */
@Composable
private fun PhoneUpdates() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val installed = remember { context.packageManager.getPackageInfo(context.packageName, 0).versionName.orEmpty() }
    var status by remember { mutableStateOf<String?>(null) }
    var update by remember { mutableStateOf<TVUpdate?>(null) }
    var busy by remember { mutableStateOf(false) }
    ListItem(headlineContent = { Text("Versión instalada") }, supportingContent = { Text(installed) })
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val candidate = update
        if (candidate == null) {
            OutlinedButton(enabled = !busy, onClick = {
                busy = true
                scope.launch {
                    try {
                        update = findUpdate(installed)
                        status = if (update == null) "Tienes la versión más reciente." else "Hay una versión nueva: ${update?.tag}."
                    } catch (error: Exception) {
                        status = "No se pudo buscar: ${error.message}"
                    } finally {
                        busy = false
                    }
                }
            }) { Text(if (busy) "Buscando actualizaciones…" else "Buscar actualizaciones") }
        } else {
            Button(enabled = !busy, onClick = {
                if (!context.packageManager.canRequestPackageInstalls()) {
                    status = "Permite instalar aplicaciones desde AniBridge Player y vuelve a pulsar Instalar."
                    runCatching { context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))) }
                    return@Button
                }
                busy = true
                scope.launch {
                    try {
                        installUpdate(context, downloadUpdate(context, candidate))
                    } catch (error: Exception) {
                        status = "No se pudo instalar: ${error.message}"
                    } finally {
                        busy = false
                    }
                }
            }) { Text(if (busy) "Descargando…" else "Instalar ${candidate.tag}") }
        }
        status?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    }
}
