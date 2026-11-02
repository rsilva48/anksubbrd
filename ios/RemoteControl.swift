import SwiftUI

/// A TV app of this identity, as it reports itself to the bridge.
struct RemoteDevice: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let state: RemoteDeviceState?
    /// Milliseconds since the TV reported `state`, measured by the bridge.
    let stateAge: Double?
    /// Whether the TV can open the app by itself for "play" (nil on older bridges).
    let canOpen: Bool?
}

struct RemoteDeviceState: Decodable, Hashable {
    let status: String
    let watchUrl: String?
    let seriesTitle: String?
    let titleJp: String?
    let imageUrl: String?
    let episode: Int?
    let episodeTitle: String?
    let kind: String?
    let position: Double?
    let duration: Double?
    /// "Saltar intro"/"Saltar outro" while the TV offers that skip.
    let skip: String?

    var isActive: Bool { status != "idle" && seriesTitle != nil }

    /// Whether the TV is already on this episode (playing, paused or loading).
    func isShowing(_ command: RemoteCommand) -> Bool {
        guard status != "idle", let watchUrl, let target = command.watchUrl else { return false }
        return episode == command.episode && URL(string: watchUrl)?.path == URL(string: target)?.path
    }
}

struct RemoteDevicesResponse: Decodable { let devices: [RemoteDevice] }

/// A command for a TV: play an episode, or control what it is playing.
struct RemoteCommand: Encodable, Hashable {
    let type: String
    var watchUrl: String? = nil
    var episode: Int? = nil
    var kind: String? = nil
    /// Relative jump for `seek` (negative goes back).
    var seconds: Double? = nil
    /// Absolute position for `seek`, from scrubbing.
    var position: Double? = nil

    static func play(_ watchUrl: String, episode: Int, kind: StreamKind?) -> RemoteCommand {
        RemoteCommand(type: "play", watchUrl: watchUrl, episode: episode, kind: kind?.rawValue)
    }
}

private struct RemoteCommandReply: Decodable { let ok: Bool }

/// An episode for the remote sheet: started on the TV right away
/// (`autoplay`, from an episode's menu) or offered with a button.
struct RemotePlayRequest: Identifiable {
    let id = UUID()
    let command: RemoteCommand?
    let title: String?
    var autoplay = true
}

/// Remote control for the TV apps of this identity, through the bridge.
/// The chosen TV is remembered and used every time until "Desconectar";
/// opening the sheet only shows its state, it never sends anything by itself
/// except an episode chosen with "Ver en TV" in its menu.
struct TVRemoteSheet: View {
    var play: RemoteCommand? = nil
    var playTitle: String? = nil
    var autoplay = true
    @Environment(ProfileStore.self) private var profile
    @Environment(\.dismiss) private var dismiss
    @AppStorage("anksubbrd.remote.tv") private var connectedID = ""
    @AppStorage("anksubbrd.remote.tv-name") private var connectedName = ""
    @State private var devices: [RemoteDevice] = []
    /// When `devices` arrived, to advance the position between reports.
    @State private var receivedAt = Date()
    @State private var pendingPlay: RemoteCommand?
    @State private var loaded = false
    @State private var errorMessage: String?
    /// Position under the finger while scrubbing.
    @State private var scrubPosition: Double?
    /// Where the last scrub sent the TV, shown until the TV reports it.
    @State private var seekTarget: (position: Double, until: Date)?

    private var connected: RemoteDevice? { devices.first { $0.id == connectedID } }
    private var language: TitleLanguage { profile.preferences.titleLanguage }

    var body: some View {
        NavigationStack {
            List {
                if connectedID.isEmpty {
                    deviceList
                } else if let device = connected {
                    controls(device)
                } else if loaded {
                    Section {
                        ContentUnavailableView(
                            "\(connectedName.isEmpty ? "La TV" : connectedName) no está disponible",
                            systemImage: "tv.slash",
                            description: Text("Enciende la TV y abre AniBridge Player con un perfil vinculado a esta identidad.")
                        )
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
                if let errorMessage {
                    Section { ErrorNotice(message: errorMessage) }
                }
            }
            .navigationTitle(connectedID.isEmpty ? "Ver en TV" : (connected?.name ?? connectedName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
                if !connectedID.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Desconectar", role: .destructive) {
                            connectedID = ""
                            connectedName = ""
                        }
                    }
                }
            }
            .task {
                pendingPlay = play
                // The TVs report every few seconds; the sheet follows them while open.
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(for: .seconds(connectedID.isEmpty ? 3 : 1.5))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var deviceList: some View {
        Section {
            if devices.isEmpty {
                if loaded {
                    ContentUnavailableView("No hay TVs conectadas", systemImage: "tv.slash", description: Text("Abre AniBridge Player en la TV con un perfil vinculado a esta identidad."))
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(devices) { device in
                    Button {
                        connect(device)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .foregroundStyle(.primary)
                                Text(summary(device.state))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        } icon: {
                            Image(systemName: "tv")
                        }
                    }
                }
            }
        } header: {
            Text("Conectar a una TV")
        } footer: {
            Text("La app recordará la TV elegida hasta que pulses Desconectar.")
        }
    }

    @ViewBuilder
    private func controls(_ device: RemoteDevice) -> some View {
        if let command = pendingPlay, !autoplay, device.state?.isShowing(command) != true {
            Section {
                Button("Reproducir en la TV", systemImage: "play.tv") {
                    pendingPlay = nil
                    send(command, to: device)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let playTitle { Text(playTitle) }
                    if device.canOpen == false, device.state?.isActive != true {
                        Text("La TV solo empieza episodios con AniBridge Player en pantalla. Para que se abra sola, pulsa «Abrir desde el teléfono» en la app de la TV.")
                    }
                }
            }
        }
        if let state = device.state, state.isActive {
            Section {
                HStack(spacing: 12) {
                    PosterImage(imageURL: state.imageUrl, cornerRadius: 6)
                        .frame(width: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        SeriesTitle(title: state.seriesTitle ?? "", titleJp: state.titleJp, language: language)
                        if let episode = state.episode {
                            Text(state.episodeTitle.map { "Episodio \(episode) · \($0)" } ?? "Episodio \(episode)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if state.status == "loading" {
                            Text("Cargando en la TV…")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                    }
                }
                if let duration = state.duration, duration > 0 {
                    progress(device, state: state, duration: duration)
                }
            }
            Section {
                // Several buttons in one row: borderless keeps each tap separate.
                HStack(spacing: 0) {
                    remoteButton("backward.end.fill", "Episodio anterior") { send(RemoteCommand(type: "previous"), to: device) }
                    remoteButton("gobackward.10", "Retroceder 10 segundos") { send(RemoteCommand(type: "seek", seconds: -10), to: device) }
                    remoteButton(state.status == "playing" ? "pause.circle.fill" : "play.circle.fill", state.status == "playing" ? "Pausar" : "Reproducir", large: true) {
                        send(RemoteCommand(type: "toggle"), to: device)
                    }
                    remoteButton("goforward.10", "Adelantar 10 segundos") { send(RemoteCommand(type: "seek", seconds: 10), to: device) }
                    remoteButton("forward.end.fill", "Siguiente episodio") { send(RemoteCommand(type: "next"), to: device) }
                }
                .buttonStyle(.borderless)
                if let skip = state.skip {
                    Button(skip, systemImage: "forward.fill") { send(RemoteCommand(type: "skip"), to: device) }
                }
                Button("Detener en la TV", systemImage: "stop.fill", role: .destructive) {
                    send(RemoteCommand(type: "stop"), to: device)
                }
            }
        } else if pendingPlay == nil || autoplay {
            Section {
                Text("La TV no está reproduciendo nada. En la ficha de una serie, usa «Ver en TV» para empezar un episodio ahí.")
                    .foregroundStyle(.secondary)
            } footer: {
                if device.canOpen == false {
                    Text("La TV solo empieza episodios con AniBridge Player en pantalla. Para que se abra sola, pulsa «Abrir desde el teléfono» en la app de la TV.")
                }
            }
        }
    }

    /// A scrubbable progress bar. Between reports (every 5 s while playing)
    /// the position advances locally, so the bar moves smoothly.
    private func progress(_ device: RemoteDevice, state: RemoteDeviceState, duration: Double) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let shown = scrubPosition ?? shownPosition(device, state: state, duration: duration, now: context.date)
            VStack(spacing: 4) {
                Slider(
                    value: Binding(get: { shown }, set: { scrubPosition = $0 }),
                    in: 0...duration,
                    onEditingChanged: { editing in
                        guard !editing, let target = scrubPosition else { return }
                        seekTarget = (target, Date().addingTimeInterval(6))
                        scrubPosition = nil
                        send(RemoteCommand(type: "seek", position: target), to: device)
                    }
                )
                .accessibilityLabel("Posición")
                .accessibilityValue(formatTime(shown))
                HStack {
                    Text(formatTime(shown))
                    Spacer()
                    Text(formatTime(duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func shownPosition(_ device: RemoteDevice, state: RemoteDeviceState, duration: Double, now: Date) -> Double {
        var position = state.position ?? 0
        if state.status == "playing" {
            position += (device.stateAge ?? 0) / 1000 + now.timeIntervalSince(receivedAt)
        }
        // After a scrub, the target until the TV reports a position near it.
        if let target = seekTarget, now < target.until, abs(position - target.position) > 3 {
            position = target.position
        }
        return min(max(position, 0), duration)
    }

    private func remoteButton(_ symbol: String, _ label: String, large: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(large ? .system(size: 44) : .title2)
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    private func summary(_ state: RemoteDeviceState?) -> String {
        guard let state, state.isActive, let title = state.seriesTitle else { return "En espera" }
        let episode = state.episode.map { " · episodio \($0)" } ?? ""
        let status = state.status == "playing" ? "Reproduciendo" : state.status == "loading" ? "Cargando" : "En pausa"
        return "\(status): \(title)\(episode)"
    }

    private func connect(_ device: RemoteDevice) {
        connectedID = device.id
        connectedName = device.name
        startPendingPlay(on: device)
    }

    /// Sends the episode from "Ver en TV" once, unless the TV already shows it.
    private func startPendingPlay(on device: RemoteDevice) {
        guard autoplay, let command = pendingPlay else { return }
        pendingPlay = nil
        if device.state?.isShowing(command) == true { return }
        send(command, to: device)
    }

    private func send(_ command: RemoteCommand, to device: RemoteDevice) {
        errorMessage = nil
        Task {
            do {
                let _: RemoteCommandReply = try await BridgeClient.post(base: profile.bridgeURL, path: "/api/devices/\(device.id)/commands", body: command)
                await refresh()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refresh() async {
        do {
            let reply: RemoteDevicesResponse = try await BridgeClient.get(base: profile.bridgeURL, path: "/api/devices", timeoutInterval: 10)
            devices = reply.devices
            receivedAt = Date()
            if let device = connected {
                connectedName = device.name
                startPendingPlay(on: device)
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch let error as BridgeRequestError where error.statusCode == 404 {
            errorMessage = "Este bridge todavía no admite el control remoto. Actualízalo a la última versión."
        } catch {
            errorMessage = error.localizedDescription
        }
        loaded = true
    }
}
