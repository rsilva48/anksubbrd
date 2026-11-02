package com.personal.anksubbrd.tv

import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Remote control from the phone apps of the same identity, through the
 * bridge. The player publishes its state here and receives the commands
 * that are not "play" (pause, seek, next…).
 */
object Remote {
    val playerCommands = MutableSharedFlow<RemoteCommand>(extraBufferCapacity = 16)
    val state = MutableStateFlow(DeviceState())
}

/**
 * Keeps this TV visible to the phones (a report on every status change and
 * every few seconds) and long-polls for commands while the profile is open.
 */
suspend fun runRemoteControl(session: Session, deviceId: String, deviceName: String, onPlay: suspend (RemoteCommand) -> Unit) = coroutineScope {
    launch {
        while (isActive) {
            val current = Remote.state.value
            runCatching { session.client.reportDevice(deviceId, deviceName, current) }
            // Status, episode or skip changes are sent right away; the
            // position alone every 5 s while playing, otherwise every 15 s.
            withTimeoutOrNull(if (current.status == "playing") 5_000L else 15_000L) {
                Remote.state.first {
                    it.status != current.status || it.watchUrl != current.watchUrl || it.episode != current.episode || it.skip != current.skip
                }
            }
            delay(500)
        }
    }
    launch {
        while (isActive) {
            val commands = try {
                session.client.waitForCommands(deviceId)
            } catch (error: BridgeException) {
                // Offline or a bridge without remote control: try again later.
                delay(if (error.status == 404) 60_000L else 5_000L)
                continue
            }
            for (command in commands) {
                if (command.type == "play") onPlay(command) else Remote.playerCommands.emit(command)
            }
        }
    }
}
