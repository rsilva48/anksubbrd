import AVFAudio
import SwiftUI

@main
struct AirPlaySubtitlePlayerApp: App {
    @State private var profile = ProfileStore()
    @State private var updates = AppUpdateCenter()
    /// Created at launch so background downloads reconnect right away.
    @State private var downloads = DownloadStore.shared
    /// Created at launch so it is the notification delegate before a tapped
    /// reminder is delivered.
    @State private var notifier = ReleaseNotifier.shared

    init() {
        AudioSession.configure()
        // Starts watching the network path before the first request fails.
        _ = NetworkStatus.shared
        Task.detached(priority: .background) {
            PosterCache.prune()
            SeriesCache.prune()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(profile)
                .environment(updates)
                .environment(downloads)
                .environment(notifier)
                .tint(.indigo)
        }
    }
}

enum AudioSession {
    /// Long-form video routing makes AirPlay send the video stream (with its
    /// subtitle tracks) to the TV instead of mirroring the screen.
    static func configure() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
    }

    /// Activated only while the player is open so other audio is not interrupted at launch.
    static func setActive(_ active: Bool) {
        let options: AVAudioSession.SetActiveOptions = active ? [] : [.notifyOthersOnDeactivation]
        try? AVAudioSession.sharedInstance().setActive(active, options: options)
    }
}

enum AppTab: Hashable {
    case latest
    case history
    case downloads
    case settings
    case search
}

struct RootView: View {
    @Environment(ProfileStore.self) private var profile
    @Environment(AppUpdateCenter.self) private var updates
    @Environment(DownloadStore.self) private var downloads
    @Environment(ReleaseNotifier.self) private var notifier
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ReleaseNotifier.promptedKey) private var promptedNotifications = false
    @State private var showNotificationPrompt = false
    /// A TV pairing QR scanned with the camera (anksubbrd://pair…).
    @State private var pairingRequest: TVPairingRequest?
    @State private var selection: AppTab = .latest
    /// Increments each time the Search tab is selected to focus its field.
    @State private var searchActivation = 0
    /// The TV of the remote control: the volume buttons change its volume.
    @AppStorage(TVRemoteSheet.connectedKey) private var connectedTV = ""

    private var volumeRelayTarget: TVVolumeRelay.Target? {
        guard !connectedTV.isEmpty, profile.isBridgeConfigured, scenePhase == .active, !TVVolumeRelay.shared.localPlayback else { return nil }
        return TVVolumeRelay.Target(base: profile.bridgeURL, device: connectedTV)
    }

    var body: some View {
        @Bindable var updates = updates
        @Bindable var notifier = notifier
        TabView(selection: $selection) {
            Tab("Recientes", systemImage: "sparkles", value: AppTab.latest) {
                requiringBridge { LatestScreen() }
            }
            Tab("Continuar", systemImage: "play.circle", value: AppTab.history) {
                requiringBridge { HistoryScreen() }
            }
            // Not gated: downloads play without a bridge or network.
            Tab("Descargas", systemImage: "arrow.down.circle", value: AppTab.downloads) {
                DownloadsScreen()
            }
            Tab("Configuración", systemImage: "gearshape", value: AppTab.settings) {
                SettingsScreen()
            }
            Tab(value: AppTab.search, role: .search) {
                requiringBridge { SearchScreen(activation: searchActivation) }
            }
        }
        .onChange(of: selection) { _, tab in
            if tab == .search { searchActivation += 1 }
        }
        .background {
            TVVolumeRelayHost()
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
        .task(id: volumeRelayTarget) {
            if let target = volumeRelayTarget {
                TVVolumeRelay.shared.start(target)
            } else {
                TVVolumeRelay.shared.stop()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .task(id: profile.scope) {
            downloads.use(profile)
            await profile.sync(force: true)
            downloads.cleanUpWatched(profile: profile)
            await notifier.refresh(profile: profile)
        }
        .onChange(of: scenePhase) { _, phase in
            // Reschedules with the latest schedule and history on every return.
            if phase == .active {
                Task {
                    await profile.sync(force: true)
                    await notifier.refresh(profile: profile)
                }
            }
        }
        // Offers release reminders once, after a bridge is configured and
        // without competing with the update sheet.
        .task(id: profile.isBridgeConfigured && updates.pendingUpdate == nil) {
            guard profile.isBridgeConfigured, updates.pendingUpdate == nil, !promptedNotifications else { return }
            if notifier.isEnabled {
                promptedNotifications = true
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            showNotificationPrompt = true
        }
        .alert("¿Avisarte de nuevos episodios?", isPresented: $showNotificationPrompt) {
            Button("Activar avisos") {
                Task { await notifier.enableFromPrompt(profile: profile) }
            }
            Button("Ahora no", role: .cancel) {
                promptedNotifications = true
            }
        } message: {
            Text("La app puede avisarte cuando salga un episodio nuevo de las series que sigues en Continuar viendo. Puedes cambiarlo cuando quieras en Configuración.")
        }
        .onOpenURL { url in
            pairingRequest = TVPairingRequest(url: url)
        }
        .sheet(item: $pairingRequest) { request in
            TVPairingSheet(request: request)
        }
        .sheet(item: $notifier.openedSeries) { anime in
            NavigationStack {
                EpisodesScreen(anime: anime)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cerrar") { notifier.openedSeries = nil }
                        }
                    }
            }
        }
        .task {
            await updates.checkOnLaunch()
        }
        .sheet(item: $updates.pendingUpdate) { update in
            UpdateSheet(update: update)
        }
    }

    /// Catalog tabs stay locked until a bridge answered the connection test,
    /// so a fresh install never searches against an unset address.
    @ViewBuilder
    private func requiringBridge<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if profile.isBridgeConfigured {
            content()
        } else {
            BridgeSetupRequiredView { selection = .settings }
        }
    }
}

private struct BridgeSetupRequiredView: View {
    let openSettings: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Configura tu bridge", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text("Escribe la dirección de tu bridge en Configuración y pruébala. Buscar, Recientes y Continuar se activan en cuanto responde.")
            } actions: {
                Button("Ir a Configuración", systemImage: "gearshape", action: openSettings)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        }
    }
}
