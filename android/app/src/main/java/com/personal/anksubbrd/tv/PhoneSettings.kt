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
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
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
            bridgeMessage = Strings.get(R.string.bridge_address_invalid)
            return
        }
        testing = true
        bridgeMessage = null
        scope.launch {
            try {
                val health = BridgeClient(url, "").health()
                if (!health.ok) throw BridgeException(Strings.get(R.string.bridge_unexpected))
                app.useBridge(url)
                val connected = listOfNotNull(health.version?.let { "bridge $it" }, health.provider).joinToString(" · ").let { if (it.isEmpty()) Strings.get(R.string.connected) else Strings.get(R.string.connected_details, it) }
                val needsIdentity = app.token == null && runCatching { BridgeClient(url, "").history() }.exceptionOrNull().let { it is BridgeException && it.status == 401 }
                bridgeMessage = Strings.get(if (needsIdentity) R.string.needs_identity else R.string.bridge_ready, connected)
                app.session?.refresh()
            } catch (error: BridgeException) {
                bridgeMessage = error.message
            } finally {
                testing = false
            }
        }
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(title = { Text(stringResource(R.string.tab_settings)) })
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 24.dp)) {
            SectionTitle("Bridge")
            Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                app.bridge?.let { Text(stringResource(R.string.active_bridge, it), color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.bodyMedium) }
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
                        placeholder = { Text(stringResource(R.string.bridge_placeholder)) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
                        keyboardActions = KeyboardActions(onGo = { test() }),
                        modifier = Modifier.weight(1f),
                    )
                }
                Button(onClick = ::test, enabled = !testing && host.isNotBlank()) { Text(stringResource(if (testing) R.string.testing_connection else R.string.test_and_save)) }
                bridgeMessage?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
                Footer(stringResource(R.string.bridge_footer))
            }

            SectionTitle(stringResource(R.string.private_identity))
            Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                when {
                    app.bridge == null -> Text(stringResource(R.string.test_bridge_first), color = MaterialTheme.colorScheme.error)
                    app.token != null -> {
                        Text(stringResource(R.string.identity_configured), color = MaterialTheme.colorScheme.primary)
                        OutlinedButton(onClick = { dialog = IdentityDialog.Backup }) { Text(stringResource(R.string.backup_token_ellipsis)) }
                        OutlinedButton(onClick = { dialog = IdentityDialog.Change }) { Text(stringResource(R.string.change_identity_ellipsis)) }
                    }
                    else -> {
                        OutlinedButton(onClick = { dialog = IdentityDialog.Create }) { Text(stringResource(R.string.create_identity_ellipsis)) }
                        OutlinedButton(onClick = { dialog = IdentityDialog.Import }) { Text(stringResource(R.string.import_token_ellipsis)) }
                    }
                }
                // A TV's "Take to phone" profile, or a TV pairing code.
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
                }) { Text(stringResource(R.string.scan_tv_code)) }
                scanError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                Footer(stringResource(R.string.identity_footer))
            }

            val preferences = session?.preferences
            SectionTitle(stringResource(R.string.catalog))
            ChoiceRow(stringResource(R.string.title_language), listOf("en" to stringResource(R.string.english), "jp" to stringResource(R.string.japanese)), preferences?.titleLanguage ?: "en", enabled = session != null) { value ->
                scope.launch { session?.updatePreferences { it.copy(titleLanguage = value) } }
            }
            SwitchRow(stringResource(R.string.hide_adult), preferences?.hideAdult ?: false, enabled = session != null) { value ->
                scope.launch { session?.updatePreferences { it.copy(hideAdult = value) } }
            }
            Footer(stringResource(R.string.catalog_footer), Modifier.padding(horizontal = 16.dp))

            SectionTitle(stringResource(R.string.playback))
            ChoiceRow(stringResource(R.string.default_servers), listOf("sub" to "Sub", "dub" to "Dub"), preferences?.defaultTrackType ?: "sub", enabled = session != null) { value ->
                scope.launch { session?.updatePreferences { it.copy(defaultTrackType = value) } }
            }
            val languages = listOf("" to stringResource(R.string.subtitles_auto)) +
                subtitleLanguages.map { it to Locale.forLanguageTag(it).getDisplayLanguage(Strings.locale).replaceFirstChar(Char::titlecase) } +
                listOf("off" to stringResource(R.string.subtitles_off))
            ChoiceRow(stringResource(R.string.subtitles_in_sub), languages, preferences?.subtitleLanguage ?: "", enabled = session != null) { value ->
                scope.launch { session?.updatePreferences { it.copy(subtitleLanguage = value) } }
            }
            SwitchRow(stringResource(R.string.auto_next), preferences?.autoNext ?: true, enabled = session != null) { value ->
                scope.launch { session?.updatePreferences { it.copy(autoNext = value) } }
            }
            SwitchRow(stringResource(R.string.auto_skip_intro), preferences?.autoSkipIntro ?: false, enabled = session != null) { value ->
                scope.launch { session?.updatePreferences { it.copy(autoSkipIntro = value) } }
            }
            SwitchRow(stringResource(R.string.auto_skip_outro), preferences?.autoSkipOutro ?: false, enabled = session != null) { value ->
                scope.launch { session?.updatePreferences { it.copy(autoSkipOutro = value) } }
            }
            Footer(stringResource(R.string.playback_footer), Modifier.padding(horizontal = 16.dp))

            SectionTitle(stringResource(R.string.this_device))
            var reminders by remember { mutableStateOf(ReleaseReminders.isEnabled(context) && ReleaseReminders.hasPermission(context)) }
            var reminderError by remember { mutableStateOf<String?>(null) }
            val permission = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) { granted ->
                ReleaseReminders.setEnabled(context, granted)
                reminders = granted
                reminderError = if (granted) null else context.getString(R.string.notifications_denied)
                scope.launch { ReleaseReminders.refresh(context, app.session) }
            }
            SwitchRow(stringResource(R.string.new_episode_alerts), reminders, enabled = session != null) { value ->
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
            SwitchRow(stringResource(R.string.delete_watched_downloads), autoDelete, enabled = true) { value ->
                PhoneDownloads.setAutoDelete(context, value)
                autoDelete = value
                if (value) PhoneDownloads.cleanUp(context, session)
            }
            val downloads by rememberDownloads()
            var confirmRemoveAll by remember { mutableStateOf(false) }
            ListItem(
                headlineContent = { Text(stringResource(R.string.storage_used)) },
                trailingContent = { Text(android.text.format.Formatter.formatShortFileSize(context, downloads.sumOf { it.bytes })) },
            )
            OutlinedButton(
                onClick = { confirmRemoveAll = true },
                enabled = downloads.isNotEmpty(),
                modifier = Modifier.padding(horizontal = 16.dp),
            ) { Text(stringResource(R.string.delete_all_downloads), color = if (downloads.isNotEmpty()) MaterialTheme.colorScheme.error else androidx.compose.ui.graphics.Color.Unspecified) }
            if (confirmRemoveAll) AlertDialog(
                onDismissRequest = { confirmRemoveAll = false },
                title = { Text(pluralStringResource(R.plurals.delete_downloads_title, downloads.size, downloads.size)) },
                text = { Text(stringResource(R.string.delete_downloads_text)) },
                confirmButton = {
                    TextButton(onClick = { PhoneDownloads.removeAll(context); confirmRemoveAll = false }) {
                        Text(stringResource(R.string.delete_all), color = MaterialTheme.colorScheme.error)
                    }
                },
                dismissButton = { TextButton(onClick = { confirmRemoveAll = false }) { Text(stringResource(R.string.cancel)) } },
            )
            Footer(stringResource(R.string.device_footer), Modifier.padding(horizontal = 16.dp))

            SectionTitle(stringResource(R.string.about))
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
        title = { Text(stringResource(R.string.backup_token)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.backup_warning))
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable { understood = !understood }) {
                    Checkbox(checked = understood, onCheckedChange = { understood = it })
                    Text(stringResource(R.string.understand_risk))
                }
                if (understood) Text(token, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
            }
        },
        confirmButton = {
            TextButton(enabled = understood, onClick = {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipboard.setPrimaryClip(ClipData.newPlainText(context.getString(R.string.clip_label), token))
            }) { Text(stringResource(R.string.copy)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.close)) } },
    )
}

@Composable
private fun ChangeIdentityDialog(onDismiss: () -> Unit, onChoose: (IdentityDialog) -> Unit) {
    var saved by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.change_identity)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.change_identity_text))
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable { saved = !saved }) {
                    Checkbox(checked = saved, onCheckedChange = { saved = it })
                    Text(stringResource(R.string.saved_current_token))
                }
                TextButton(onClick = { onChoose(IdentityDialog.Backup) }) { Text(stringResource(R.string.backup_current_token)) }
            }
        },
        confirmButton = {
            Column {
                TextButton(enabled = saved, onClick = { onChoose(IdentityDialog.Create) }) { Text(stringResource(R.string.create_new_identity)) }
                TextButton(enabled = saved, onClick = { onChoose(IdentityDialog.Import) }) { Text(stringResource(R.string.use_existing_token)) }
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun ImportTokenDialog(replaces: Boolean, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var token by remember { mutableStateOf("") }
    var confirmed by remember { mutableStateOf(!replaces) }
    var error by remember { mutableStateOf<String?>(null) }
    val invalidToken = stringResource(R.string.token_invalid)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.import_token)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.import_text))
                OutlinedTextField(
                    value = token,
                    onValueChange = { token = it.trim() },
                    label = { Text(stringResource(R.string.token_64)) },
                    visualTransformation = PasswordVisualTransformation(),
                    singleLine = true,
                )
                if (replaces) Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable { confirmed = !confirmed }) {
                    Checkbox(checked = confirmed, onCheckedChange = { confirmed = it })
                    Text(stringResource(R.string.understand_replace))
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            TextButton(enabled = confirmed && token.isNotEmpty(), onClick = {
                if (!Regex("^[A-Fa-f0-9]{64}$").matches(token)) error = invalidToken else onSave(token.lowercase())
            }) { Text(stringResource(R.string.save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
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
        title = { Text(stringResource(R.string.new_identity)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.new_identity_text))
                OutlinedTextField(value = adminToken, onValueChange = { adminToken = it.trim() }, label = { Text(stringResource(R.string.admin_token_label)) }, visualTransformation = PasswordVisualTransformation(), singleLine = true)
                OutlinedTextField(value = label, onValueChange = { label = it.take(80) }, label = { Text(stringResource(R.string.optional_label)) }, singleLine = true)
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
            }) { Text(stringResource(if (busy) R.string.registering else R.string.register_and_use)) }
        },
        dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
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
    ListItem(headlineContent = { Text(stringResource(R.string.installed_version)) }, supportingContent = { Text(installed) })
    Column(Modifier.padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val candidate = update
        if (candidate == null) {
            OutlinedButton(enabled = !busy, onClick = {
                busy = true
                scope.launch {
                    try {
                        update = findUpdate(installed)
                        status = update?.let { context.getString(R.string.new_version, it.tag) } ?: context.getString(R.string.latest_version)
                    } catch (error: Exception) {
                        status = context.getString(R.string.check_failed, error.message.orEmpty())
                    } finally {
                        busy = false
                    }
                }
            }) { Text(stringResource(if (busy) R.string.checking_updates else R.string.check_updates)) }
        } else {
            Button(enabled = !busy, onClick = {
                if (!context.packageManager.canRequestPackageInstalls()) {
                    status = context.getString(R.string.allow_install)
                    runCatching { context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))) }
                    return@Button
                }
                busy = true
                scope.launch {
                    try {
                        installUpdate(context, downloadUpdate(context, candidate))
                    } catch (error: Exception) {
                        status = context.getString(R.string.install_failed, error.message.orEmpty())
                    } finally {
                        busy = false
                    }
                }
            }) { Text(if (busy) stringResource(R.string.downloading) else stringResource(R.string.install_tag, candidate.tag)) }
        }
        status?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
    }
}
