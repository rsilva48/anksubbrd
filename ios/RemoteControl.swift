import SwiftUI

/// A TV app of this identity, as it reports itself to the bridge.
struct RemoteDevice: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let state: RemoteDeviceState?
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

    static func play(_ watchUrl: String, episode: Int, kind: StreamKind?) -> RemoteCommand {
        RemoteCommand(type: "play", watchUrl: watchUrl, episode: episode, kind: kind?.rawValue)
    }
}

private struct RemoteCommandReply: Decodable { let ok: Bool }

/// An episode to start on a TV, chosen in the remote sheet.
struct RemotePlayRequest: Identifiable {
    let id = UUID()
    let command: RemoteCommand?
    let title: String?
}

/// Remote control for the TV apps of this identity, through the bridge: plays
/// an episode on the chosen TV (when opened with one) and controls playback.
struct TVRemoteSheet: View {
    var play: RemoteCommand? = nil
    var playTitle: String? = nil
    @Environment(ProfileStore.self) private var profile
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [RemoteDevice] = []
    @State private var selectedID: String?
    @State private var pendingPlay: RemoteCommand?
    @State private var loaded = false
    @State private var errorMessage: String?

    private var selected: RemoteDevice? { devices.first { $0.id == selectedID } }
    private var language: TitleLanguage { profile.preferences.titleLanguage }

    var body: some View {
        NavigationStack {
            List {
                if let device = selected {
                    controls(device)
                } else {
                    deviceList
                }
                if let errorMessage {
                    Section { ErrorNotice(message: errorMessage) }
                }
            }
            .navigationTitle(selected?.name ?? "Ver en TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Listo") { dismiss() }
                }
                if selected != nil, devices.count > 1 {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Otra TV") { selectedID = nil }
                    }
                }
            }
            .task {
                pendingPlay = play
                // The TVs report every few seconds; the sheet follows them while open.
                while !Task.isCancelled {
                    await refresh()
                    try? await Task.sleep(for: .seconds(selectedID == nil ? 3 : 1.5))
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
                        choose(device)
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
            Text(pendingPlay == nil ? "TVs conectadas" : "Elige la TV")
        } footer: {
            if pendingPlay != nil, let playTitle {
                Text("Se reproducirá \(playTitle).")
            }
        }
    }

    @ViewBuilder
    private func controls(_ device: RemoteDevice) -> some View {
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
                    VStack(spacing: 4) {
                        ProgressView(value: min(state.position ?? 0, duration), total: duration)
                        HStack {
                            Text(formatTime(state.position ?? 0))
                            Spacer()
                            Text(formatTime(duration))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
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
        } else {
            Section {
                Text("La TV no está reproduciendo nada. En la ficha de una serie, usa «Ver en TV» para empezar un episodio ahí.")
                    .foregroundStyle(.secondary)
            }
        }
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

    private func choose(_ device: RemoteDevice) {
        selectedID = device.id
        if let command = pendingPlay {
            pendingPlay = nil
            send(command, to: device)
        }
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
            if let current = selectedID, !devices.contains(where: { $0.id == current }) {
                selectedID = nil
            }
            // A single TV with nothing to start opens its controls directly.
            if selectedID == nil, pendingPlay == nil, devices.count == 1 {
                selectedID = devices[0].id
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
