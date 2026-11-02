package com.personal.anksubbrd.tv

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Remote control from the phone apps of the same identity, through the
 * bridge. The player publishes its state here and receives the commands
 * that are not "play" (pause, seek, next…); "play" goes to the activity.
 */
object Remote {
    val playerCommands = MutableSharedFlow<RemoteCommand>(extraBufferCapacity = 16)
    val state = MutableStateFlow(DeviceState())
    /** "play" commands for the activity; kept until a profile is open. */
    val playRequests = Channel<RemoteCommand>(Channel.CONFLATED)
    /** Whether the app is on screen (it can then always open an episode). */
    val foreground = MutableStateFlow(false)
    /** Bumped after each command so the phone sees its effect right away. */
    internal val handled = MutableStateFlow(0L)
}

/**
 * Keeps this TV visible to the phones (a report on every change and every
 * few seconds) and long-polls for commands.
 */
suspend fun runRemoteControl(client: BridgeClient, deviceId: String, deviceName: String, canOpen: () -> Boolean, onPlay: (RemoteCommand) -> Unit) = coroutineScope {
    launch {
        while (isActive) {
            val current = Remote.state.value
            val foreground = Remote.foreground.value
            val handled = Remote.handled.value
            runCatching { client.reportDevice(deviceId, deviceName, current, foreground || canOpen()) }
            // Status, episode or skip changes are sent right away; the
            // position alone every 5 s while playing, otherwise every 15 s.
            withTimeoutOrNull(if (current.status == "playing") 5_000L else 15_000L) {
                merge(
                    Remote.state.filter {
                        it.status != current.status || it.watchUrl != current.watchUrl || it.episode != current.episode || it.skip != current.skip
                    },
                    Remote.foreground.filter { it != foreground },
                    Remote.handled.filter { it != handled },
                ).first()
            }
            delay(500)
        }
    }
    launch {
        while (isActive) {
            val commands = try {
                client.waitForCommands(deviceId)
            } catch (error: BridgeException) {
                // Offline or a bridge without remote control: try again later.
                delay(if (error.status == 404) 60_000L else 5_000L)
                continue
            }
            for (command in commands) {
                if (command.type == "play") onPlay(command) else Remote.playerCommands.emit(command)
            }
            if (commands.isNotEmpty()) Remote.handled.value = System.currentTimeMillis()
        }
    }
}

/**
 * Keeps this TV reachable from the phones while the app is closed, like a
 * cast target: it starts at boot, after updates and whenever the app opens,
 * runs the remote control for the active profile, and opens the app for
 * "play". Opening an activity from the background needs the "display over
 * other apps" permission; without it the TV is listed only while the app is
 * on screen.
 */
class RemoteService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var job: Job? = null
    private var running: Pair<String, String>? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val type = if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification(), type)
        val state = AppState(applicationContext)
        val profile = state.activeProfile ?: state.profiles.singleOrNull()
        val bridge = state.bridgeUrl
        if (profile == null || bridge == null) {
            // Nobody to be reachable as (no bridge yet, or choosing a profile).
            running = null
            job?.cancel()
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        // Started again on every app launch and profile change; restarts
        // the loop only when the identity changed.
        if (running != bridge to profile.token || job?.isActive != true) {
            running = bridge to profile.token
            job?.cancel()
            val name = Settings.Global.getString(contentResolver, "device_name") ?: Build.MODEL
            job = scope.launch {
                runRemoteControl(state.client(profile), state.deviceId, name, canOpen = { Settings.canDrawOverlays(this@RemoteService) }) { command ->
                    val open = Intent(this@RemoteService, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        .putExtra(EXTRA_PLAY, BridgeClient.json.encodeToString(RemoteCommand.serializer(), command))
                    runCatching { startActivity(open) }
                }
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Control desde el teléfono", NotificationManager.IMPORTANCE_MIN))
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else @Suppress("DEPRECATION") Notification.Builder(this)
        return builder.setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(getString(R.string.app_name))
            .setContentText("Disponible para el control desde el teléfono")
            .setOngoing(true)
            .build()
    }

    companion object {
        const val EXTRA_PLAY = "com.personal.anksubbrd.tv.PLAY"
        private const val CHANNEL = "remote"
        private const val NOTIFICATION_ID = 1

        fun start(context: Context) {
            // The phone build of this app is a remote itself, not a target.
            if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)) return
            runCatching { ContextCompat.startForegroundService(context, Intent(context, RemoteService::class.java)) }
        }
    }
}

/** Starts [RemoteService] when the TV boots and after the app is updated. */
class RemoteStartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) RemoteService.start(context)
    }
}
