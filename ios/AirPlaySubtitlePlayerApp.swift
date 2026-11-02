import AVFAudio
import SwiftUI

@main
struct AirPlaySubtitlePlayerApp: App {
    @State private var profile = ProfileStore()
    @State private var updates = AppUpdateCenter()

    init() {
        AudioSession.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(profile)
                .environment(updates)
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
    case settings
    case search
}

struct RootView: View {
    @Environment(ProfileStore.self) private var profile
    @Environment(AppUpdateCenter.self) private var updates
    @State private var selection: AppTab = .latest
    /// Increments each time the Search tab is selected to focus its field.
    @State private var searchActivation = 0

    var body: some View {
        @Bindable var updates = updates
        TabView(selection: $selection) {
            Tab("Recientes", systemImage: "sparkles", value: AppTab.latest) {
                requiringBridge { LatestScreen() }
            }
            Tab("Continuar", systemImage: "play.circle", value: AppTab.history) {
                requiringBridge { HistoryScreen() }
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
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .task(id: profile.scope) {
            await profile.sync(force: true)
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
