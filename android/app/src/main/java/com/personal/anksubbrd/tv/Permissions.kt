@file:OptIn(androidx.tv.material3.ExperimentalTvMaterial3Api::class)

package com.personal.anksubbrd.tv

import android.content.Context
import android.content.Intent
import android.content.pm.LauncherApps
import android.net.Uri
import android.os.Process
import android.os.UserManager
import android.provider.Settings
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.tv.material3.Button
import androidx.tv.material3.MaterialTheme
import androidx.tv.material3.OutlinedButton
import androidx.tv.material3.Surface
import androidx.tv.material3.Text

/**
 * Special app access ("install unknown apps", "display over other apps") is
 * granted per Android user. TV Settings opens the whole list instead of this
 * app's page, and when the app is also installed in a work profile it can
 * list only that copy (the one with a briefcase): turning that on does
 * nothing for this one (seen on a TCL with Android 11; `adb install`
 * installs for every profile). Returns the serial numbers of those copies.
 */
private fun otherProfileCopies(context: Context): List<Long> {
    val users = context.getSystemService(UserManager::class.java) ?: return emptyList()
    val launcher = context.getSystemService(LauncherApps::class.java) ?: return emptyList()
    return users.userProfiles.filter { it != Process.myUserHandle() }
        .filter { profile -> runCatching { launcher.getApplicationInfo(context.packageName, 0, profile) }.isSuccess }
        .map { users.getSerialNumberForUser(it) }
}

/** How to grant a special access in TV Settings, with the work-profile case spelled out. */
fun specialAccessHint(context: Context, setting: String): String {
    val copy = otherProfileCopies(context).firstOrNull()
        ?: return "En Ajustes › «$setting», activa AniBridge Player y vuelve a la app."
    return "En Ajustes › «$setting», activa AniBridge Player y vuelve a la app. La app también está instalada en otro " +
        "perfil de esta TV: si la que aparece en la lista tiene un icono de maletín, es esa otra copia y activarla no sirve. " +
        "Quítala (adb shell pm uninstall --user $copy ${context.packageName}) y vuelve a intentarlo."
}

/** Opens a special-access screen for this app; false when the TV does not have it. */
fun openSpecialAccess(context: Context, action: String): Boolean =
    runCatching { context.startActivity(Intent(action, Uri.parse("package:${context.packageName}"))) }.isSuccess

private const val OVERLAY_SETTING = "Mostrar sobre otras apps"

/**
 * Asks for "display over other apps", which lets [RemoteService] open the
 * app when a phone sends an episode while it is closed. Hidden once granted.
 */
@Composable
fun RemoteAccessControl() {
    val context = LocalContext.current
    var granted by remember { mutableStateOf(Settings.canDrawOverlays(context)) }
    var show by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    LifecycleResumeEffect(Unit) {
        granted = Settings.canDrawOverlays(context)
        if (granted) show = false
        onPauseOrDispose { }
    }
    if (granted) return
    OutlinedButton(onClick = { message = null; show = true }) { Text("Abrir desde el teléfono") }
    Spacer(Modifier.width(12.dp))
    if (show) Dialog(onDismissRequest = { show = false }) {
        Surface(shape = RoundedCornerShape(24.dp)) {
            Column(Modifier.padding(32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("Abrir desde el teléfono", style = MaterialTheme.typography.titleLarge)
                Text(
                    "Con la app abierta, el teléfono ya puede controlarla. Para que también pueda abrirla cuando está cerrada, " +
                        "Android TV pide el permiso «$OVERLAY_SETTING».",
                )
                Text(message ?: specialAccessHint(context, OVERLAY_SETTING))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Button(onClick = {
                        if (!openSpecialAccess(context, Settings.ACTION_MANAGE_OVERLAY_PERMISSION)) {
                            message = "Esta TV no tiene la pantalla «$OVERLAY_SETTING». Se puede conceder con " +
                                "adb shell appops set ${context.packageName} SYSTEM_ALERT_WINDOW allow"
                        }
                    }) { Text("Abrir Ajustes") }
                    OutlinedButton(onClick = { show = false }) { Text("Ahora no") }
                }
            }
        }
    }
}
