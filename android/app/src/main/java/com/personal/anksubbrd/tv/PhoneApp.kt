@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.personal.anksubbrd.tv

import android.app.Activity
import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.view.KeyEvent
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.launch

/** The phone uses its own bridge identity; the token is encrypted with Android Keystore. */
internal class PhoneIdentity(context: Context) {
    private val prefs = context.getSharedPreferences("phone_identity", Context.MODE_PRIVATE)
    private val alias = "anibridge.phone.identity.v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }

    /** The tested bridge address, even without a token yet. */
    fun bridge(): String? = prefs.getString("bridge", null)

    fun token(): String? = runCatching {
        val bytes = Base64.decode(prefs.getString("token", null) ?: return null, Base64.NO_WRAP)
        require(bytes.size > 12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.doFinal(bytes.copyOfRange(12, bytes.size)).toString(Charsets.UTF_8)
    }.getOrNull()

    fun saveBridge(url: String) {
        // Identities belong to one bridge.
        if (url != bridge()) prefs.edit().remove("token").apply()
        prefs.edit().putString("bridge", url).apply()
    }

    fun saveToken(token: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val encoded = Base64.encodeToString(cipher.iv + cipher.doFinal(token.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP)
        prefs.edit().putString("token", encoded).apply()
    }
}

/** The connected TV of the remote control (one, until "Desconectar"). */
internal data class ConnectedTv(val id: String, val name: String)

/** An episode to start on the TV from the remote sheet, sent once. */
internal data class TvPlayRequest(val command: RemoteCommand, val title: String, val autoplay: Boolean, val playHere: (() -> Unit)? = null)

/** What the phone screens share: identity, the playing episode, the TV. */
internal class PhoneState(context: Context) {
    val identity = PhoneIdentity(context)
    private val appContext = context.applicationContext
    private val remotePrefs = context.getSharedPreferences("phone_remote", Context.MODE_PRIVATE)

    var bridge by mutableStateOf(identity.bridge())
        private set
    var token by mutableStateOf(identity.token())
        private set
    var session by mutableStateOf(makeSession())
        private set

    /** The episode open in the player (full screen). */
    var playing by mutableStateOf<PlaybackRequest?>(null)
    /** The TV remote sheet, optionally with an episode to start there. */
    var remoteOpen by mutableStateOf(false)
    var tvPlay by mutableStateOf<TvPlayRequest?>(null)

    var connectedTv by mutableStateOf(
        remotePrefs.getString("tv", null)?.let { ConnectedTv(it, remotePrefs.getString("tvName", null) ?: "TV") },
    )
        private set

    private fun makeSession(): Session? {
        val url = bridge ?: return null
        val token = token.orEmpty()
        // History and preferences are kept per bridge and identity.
        val bytes = MessageDigest.getInstance("SHA-256").digest("$url\n$token".toByteArray())
        val scope = bytes.joinToString("") { "%02x".format(it) }.take(24)
        return Session(Profile(scope, "Teléfono", token), BridgeClient(url, token), appContext)
    }

    fun useBridge(url: String) {
        identity.saveBridge(url)
        bridge = url
        token = identity.token()
        session = makeSession()
    }

    fun useToken(value: String) {
        identity.saveToken(value)
        token = value
        session = makeSession()
    }

    fun connect(tv: ConnectedTv?) {
        connectedTv = tv
        remotePrefs.edit().apply {
            if (tv == null) remove("tv").remove("tvName") else putString("tv", tv.id).putString("tvName", tv.name)
        }.apply()
    }

    /** Sends an episode to the connected TV and shows the remote; false without a TV. */
    fun playOnTv(command: RemoteCommand, title: String, playHere: (() -> Unit)?): Boolean {
        if (connectedTv == null) return false
        tvPlay = TvPlayRequest(command, title, autoplay = true, playHere = playHere)
        remoteOpen = true
        return true
    }
}

internal val LocalPhone = staticCompositionLocalOf<PhoneState> { error("No PhoneState") }

internal enum class PhoneTab(val label: String, val icon: ImageVector) {
    Recents("Recientes", Icons.Filled.Star),
    Continue("Continuar", Icons.Filled.PlayArrow),
    Downloads("Descargas", PhoneIcons.Download),
    Settings("Ajustes", Icons.Filled.Settings),
    Search("Buscar", Icons.Filled.Search),
}

@Composable
fun PhoneApp() {
    val context = LocalContext.current
    val dark = isSystemInDarkTheme()
    // Material You: the wallpaper's colors on Android 12+.
    val colors = if (Build.VERSION.SDK_INT >= 31) {
        if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    } else if (dark) darkColorScheme(primary = Color(0xFFC4BEFF)) else lightColorScheme(primary = Color(0xFF5146C7))
    MaterialTheme(colorScheme = colors) {
        Surface(Modifier.fillMaxSize()) { PhoneRoot() }
    }
}

@Composable
private fun PhoneRoot() {
    val context = LocalContext.current
    val app = remember { PhoneState(context.applicationContext) }
    val session = app.session
    var tab by remember { mutableStateOf(if (app.bridge == null) PhoneTab.Settings else PhoneTab.Recents) }
    // One stack of series per tab, like the tabs on iOS.
    val stacks = remember { PhoneTab.entries.associateWith { mutableStateListOf<Anime>() } }
    val scope = rememberCoroutineScope()
    LaunchedEffect(session) {
        session?.refresh()
        ReleaseReminders.refresh(context, session)
        // Downloads finished on another device with this identity.
        PhoneDownloads.cleanUp(context, session)
    }
    // Reminders are rescheduled with the latest history whenever the app returns.
    androidx.lifecycle.compose.LifecycleResumeEffect(session) {
        scope.launch { ReleaseReminders.refresh(context, session) }
        onPauseOrDispose { }
    }
    // A tapped reminder opens its series in Continue.
    val reminded by ReleaseReminders.opened.collectAsState()
    LaunchedEffect(reminded) {
        val anime = reminded ?: return@LaunchedEffect
        ReleaseReminders.opened.value = null
        tab = PhoneTab.Continue
        stacks.getValue(PhoneTab.Continue).apply { clear(); add(anime) }
    }

    // With a TV connected and nothing playing here, the volume buttons
    // change the TV's volume.
    val activity = context as? MainActivity
    DisposableEffect(activity, app.connectedTv, app.playing, session) {
        val tv = app.connectedTv
        val handler: (KeyEvent) -> Boolean = handler@{ event ->
            val steps = when (event.keyCode) {
                KeyEvent.KEYCODE_VOLUME_UP -> 1
                KeyEvent.KEYCODE_VOLUME_DOWN -> -1
                else -> return@handler false
            }
            if (tv == null || app.playing != null || session == null) return@handler false
            if (event.action == KeyEvent.ACTION_DOWN) {
                scope.launch { runCatching { session.client.sendCommand(tv.id, RemoteCommand(type = "volume", steps = steps)) } }
            }
            true
        }
        activity?.phoneKeyHandler = handler
        onDispose { if (activity?.phoneKeyHandler === handler) activity.phoneKeyHandler = null }
    }

    CompositionLocalProvider(LocalPhone provides app) {
        val request = app.playing
        if (request != null && session != null) {
            PhonePlayer(session, request, onExit = { app.playing = null })
            return@CompositionLocalProvider
        }
        Scaffold(
            bottomBar = {
                NavigationBar {
                    PhoneTab.entries.forEach { item ->
                        NavigationBarItem(
                            selected = tab == item,
                            onClick = {
                                // Tapping the current tab goes back to its root.
                                if (tab == item) stacks.getValue(item).clear()
                                tab = item
                            },
                            icon = { Icon(item.icon, contentDescription = null) },
                            label = { Text(item.label, maxLines = 1) },
                        )
                    }
                }
            },
        ) { padding ->
            Box(Modifier.fillMaxSize().padding(padding)) {
                val stack = stacks.getValue(tab)
                BackHandler(enabled = stack.isNotEmpty()) { stack.removeAt(stack.lastIndex) }
                val open: (Anime) -> Unit = { stack.add(it) }
                when {
                    tab == PhoneTab.Settings -> PhoneSettings(app)
                    // Works without a bridge or a connection.
                    tab == PhoneTab.Downloads -> PhoneDownloadsScreen(session) { app.playing = it }
                    session == null -> PhoneMessage(
                        "Configura tu bridge",
                        "Escribe la dirección de tu bridge en Ajustes y pruébala. Buscar, Recientes y Continuar se activan en cuanto responde.",
                        action = "Ir a Ajustes" to { tab = PhoneTab.Settings },
                    )
                    stack.isNotEmpty() -> PhoneSeries(session, stack.last(), onBack = { stack.removeAt(stack.lastIndex) })
                    tab == PhoneTab.Recents -> PhoneCatalog(session, searching = false, onOpen = open)
                    tab == PhoneTab.Search -> PhoneCatalog(session, searching = true, onOpen = open)
                    else -> PhoneContinue(session, onOpen = open)
                }
            }
        }
        if (app.remoteOpen && session != null) PhoneRemoteSheet(app, session)
        // Offers the reminders once, as on iOS, once a bridge works.
        if (session != null && app.bridge != null && !ReleaseReminders.wasPrompted(context)) ReleasePrompt()
        // A TV's QR (camera or the scanner in Ajustes).
        val link by PhoneLinks.pending.collectAsState()
        when (val current = link) {
            is ScannedLink.Identity -> IdentityImportDialog(app, current) { PhoneLinks.pending.value = null }
            is ScannedLink.Pairing -> PairTvDialog(app, current) { PhoneLinks.pending.value = null }
            null -> Unit
        }
    }
}

@Composable
internal fun PhoneMessage(title: String, text: String, action: Pair<String, () -> Unit>? = null) {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(title, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
        Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        action?.let { (label, run) -> Button(onClick = run) { Text(label) } }
    }
}

/** The activity of a composable, for orientation and system bars. */
internal fun Context.findActivity(): Activity? {
    var current = this
    while (current is android.content.ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}

/** "¿Avisarte de nuevos episodios?", shown once. */
@Composable
private fun ReleasePrompt() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var visible by remember { mutableStateOf(true) }
    val permission = androidx.activity.compose.rememberLauncherForActivityResult(androidx.activity.result.contract.ActivityResultContracts.RequestPermission()) { granted ->
        ReleaseReminders.setEnabled(context, granted)
        visible = false
    }
    if (!visible) return
    androidx.compose.material3.AlertDialog(
        onDismissRequest = { ReleaseReminders.markPrompted(context); visible = false },
        title = { Text("¿Avisarte de nuevos episodios?") },
        text = { Text("La app puede avisarte cuando salga un episodio nuevo de las series que sigues en Continuar viendo. Puedes cambiarlo cuando quieras en Ajustes.") },
        confirmButton = {
            androidx.compose.material3.TextButton(onClick = {
                if (Build.VERSION.SDK_INT >= 33 && !ReleaseReminders.hasPermission(context)) {
                    permission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
                } else {
                    ReleaseReminders.setEnabled(context, true)
                    visible = false
                }
            }) { Text("Activar avisos") }
        },
        dismissButton = {
            androidx.compose.material3.TextButton(onClick = { ReleaseReminders.markPrompted(context); visible = false }) { Text("Ahora no") }
        },
    )
}
