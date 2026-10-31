import AVKit
import CoreMedia
import Foundation
import SwiftUI

@main
struct AirPlaySubtitlePlayerApp: App {
    @StateObject private var history = WatchHistoryStore()
    var body: some Scene { WindowGroup { CatalogScreen().environmentObject(history) } }
}

struct CatalogScreen: View {
    @EnvironmentObject private var history: WatchHistoryStore
    @AppStorage("bridgeBaseURL") private var bridgeBaseURL = "http://192.168.1.20:8787"
    @State private var query = ""
    @State private var results: [Anime] = []
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Bridge local") {
                    TextField("http://IP-DEL-BRIDGE:8787", text: $bridgeBaseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
                Section("Buscar") {
                    HStack {
                        TextField("Título de anime", text: $query)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .onSubmit { search() }
                        Button("Buscar") { search() }.disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || loading)
                    }
                }
                if loading { ProgressView("Consultando catálogo…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                if !history.entries.isEmpty {
                    Section("Continuar viendo") {
                        ForEach(history.entries) { entry in
                            NavigationLink(value: entry) {
                                VStack(alignment: .leading) {
                                    Text(entry.seriesTitle)
                                    Text("Episodio \(entry.episode) · \(formatTime(entry.positionSeconds))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section("Resultados") {
                    ForEach(results) { anime in
                        NavigationLink(value: anime) {
                            VStack(alignment: .leading) {
                                Text(anime.title)
                                if !anime.meta.isEmpty { Text(anime.meta).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("AirPlay Subtitles")
            .navigationDestination(for: Anime.self) { anime in EpisodesScreen(bridgeBaseURL: bridgeBaseURL, anime: anime) }
            .navigationDestination(for: WatchHistoryEntry.self) { entry in
                EpisodesScreen(bridgeBaseURL: bridgeBaseURL, anime: Anime(title: entry.seriesTitle, watchUrl: entry.watchUrl, imageUrl: nil, meta: ""), resumeEpisode: entry.episode)
            }
        }
    }

    private func search() {
        loading = true; errorMessage = nil
        Task { @MainActor in
            do {
                let reply: SearchResponse = try await BridgeClient.get(base: bridgeBaseURL, path: "/api/search", query: [URLQueryItem(name: "q", value: query)])
                results = reply.results
            } catch { errorMessage = error.localizedDescription }
            loading = false
        }
    }
}

struct EpisodesScreen: View {
    let bridgeBaseURL: String
    let anime: Anime
    let resumeEpisode: Int?
    @EnvironmentObject private var history: WatchHistoryStore
    @State private var series: Series?
    @State private var pendingServers: EpisodeServers?
    @State private var playback: PlaybackSession?
    @State private var loading = true
    @State private var errorMessage: String?

    init(bridgeBaseURL: String, anime: Anime, resumeEpisode: Int? = nil) {
        self.bridgeBaseURL = bridgeBaseURL
        self.anime = anime
        self.resumeEpisode = resumeEpisode
    }

    var body: some View {
        List {
            if loading { ProgressView("Cargando episodios…") }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            if let series {
                if let resumeEpisode, let episode = series.episodes.first(where: { $0.number == resumeEpisode }) {
                    Section("Continuar") {
                        Button("Continuar episodio \(episode.number)") { loadServers(for: episode, seriesKey: series.seriesKey) }
                    }
                }
                ForEach(series.episodes) { episode in
                    Button {
                        loadServers(for: episode, seriesKey: series.seriesKey)
                    } label: {
                        VStack(alignment: .leading) {
                            Text("Episodio \(episode.number)")
                            Text(episode.title).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(anime.title)
        .task { await loadSeries() }
        .sheet(item: $pendingServers) { selection in
            ServerPicker(selection: selection) { server in play(episode: selection.episode, server: server) }
        }
        .fullScreenCover(item: $playback) { item in VideoScreen(playback: item.playback, historyEntry: item.historyEntry).environmentObject(history) }
    }

    private func loadSeries() async {
        defer { loading = false }
        do { series = try await BridgeClient.post(base: bridgeBaseURL, path: "/api/series", body: WatchRequest(watchUrl: anime.watchUrl)) }
        catch { errorMessage = error.localizedDescription }
    }
    private func loadServers(for episode: Episode, seriesKey: String) {
        errorMessage = nil
        Task { @MainActor in
            do {
                let reply: ServerResponse = try await BridgeClient.get(base: bridgeBaseURL, path: "/api/series/\(seriesKey)/servers", query: [URLQueryItem(name: "episode", value: String(episode.number))])
                pendingServers = EpisodeServers(episode: episode.number, seriesKey: seriesKey, servers: reply.servers)
            } catch { errorMessage = error.localizedDescription }
        }
    }
    private func play(episode: Int, server: Server) {
        guard let series else { return }
        pendingServers = nil; errorMessage = nil
        Task { @MainActor in
            do {
                let resolved: Playback = try await BridgeClient.post(base: bridgeBaseURL, path: "/api/play", body: PlayRequest(seriesKey: series.seriesKey, episode: episode, serverIndex: server.index))
                let episodeTitle = series.episodes.first(where: { $0.number == episode })?.title ?? "Episode \(episode)"
                playback = PlaybackSession(playback: resolved, historyEntry: WatchHistoryEntry(seriesTitle: series.title, watchUrl: anime.watchUrl, episode: episode, episodeTitle: episodeTitle, serverName: server.name, positionSeconds: history.position(for: anime.watchUrl, episode: episode), updatedAt: Date()))
            }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

struct ServerPicker: View {
    let selection: EpisodeServers
    let onServer: (Server) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(selection.servers) { server in
                    Button { dismiss(); onServer(server) } label: {
                        HStack { Text(server.name); Spacer(); Text(server.type.uppercased()).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Servidor — Episodio \(selection.episode)")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
    }
}

struct VideoScreen: View {
    let playback: Playback
    let historyEntry: WatchHistoryEntry
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var history: WatchHistoryStore
    @State private var player: AVPlayer
    @State private var timeObserver: Any?

    init(playback: Playback, historyEntry: WatchHistoryEntry) {
        self.playback = playback
        self.historyEntry = historyEntry
        _player = State(initialValue: AVPlayer(url: URL(string: playback.playbackUrl)!))
    }
    var body: some View {
        NavigationStack {
            NativePlayer(player: player).ignoresSafeArea()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { savePosition(); player.pause(); dismiss() } } }
                .onAppear { beginPlayback() }
                .onDisappear { savePosition(); removeObserver() }
        }
    }

    private func beginPlayback() {
        history.open(historyEntry)
        let resumeAt = history.position(for: historyEntry.watchUrl, episode: historyEntry.episode)
        player.allowsExternalPlayback = true
        if resumeAt > 3 { player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600)) }
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { time in
                guard time.seconds.isFinite, time.seconds >= 0 else { return }
                Task { @MainActor in history.update(historyEntry, positionSeconds: time.seconds) }
            }
        }
        player.play()
    }
    private func savePosition() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite, seconds >= 0 { history.update(historyEntry, positionSeconds: seconds) }
    }
    private func removeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
    }
}

struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController(); controller.player = player
        controller.allowsPictureInPicturePlayback = true; controller.updatesNowPlayingInfoCenter = true
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
}

private enum BridgeClient {
    static func get<T: Decodable>(base: String, path: String, query: [URLQueryItem] = []) async throws -> T {
        var components = try components(base: base, path: path); components.queryItems = query
        return try await request(URLRequest(url: components.url!))
    }
    static func post<T: Decodable, Body: Encodable>(base: String, path: String, body: Body) async throws -> T {
        let url = try components(base: base, path: path).url!
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await self.request(request)
    }
    private static func components(base: String, path: String) throws -> URLComponents {
        guard var components = URLComponents(string: base), components.scheme == "http" || components.scheme == "https", components.host != nil else { throw URLError(.badURL) }
        components.path = path; return components
    }
    private static func request<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

struct SearchResponse: Decodable { let results: [Anime] }
struct Anime: Codable, Hashable, Identifiable { let title: String; let watchUrl: String; let imageUrl: String?; let meta: String; var id: String { watchUrl } }
struct WatchRequest: Encodable { let watchUrl: String }
struct Series: Decodable { let seriesKey: String; let title: String; let episodes: [Episode] }
struct Episode: Decodable, Identifiable { let number: Int; let title: String; var id: Int { number } }
struct ServerResponse: Decodable { let episode: Int; let servers: [Server] }
struct Server: Decodable, Identifiable { let index: Int; let name: String; let type: String; var id: Int { index } }
struct EpisodeServers: Identifiable { let episode: Int; let seriesKey: String; let servers: [Server]; var id: Int { episode } }
struct PlayRequest: Encodable { let seriesKey: String; let episode: Int; let serverIndex: Int }
struct Playback: Decodable, Identifiable { let playbackUrl: String; let subtitleTracks: Int; var id: String { playbackUrl } }
struct PlaybackSession: Identifiable { let playback: Playback; let historyEntry: WatchHistoryEntry; var id: String { playback.id } }

struct WatchHistoryEntry: Codable, Hashable, Identifiable {
    let seriesTitle: String
    let watchUrl: String
    let episode: Int
    let episodeTitle: String
    let serverName: String
    var positionSeconds: Double
    var updatedAt: Date
    var id: String { "\(watchUrl)#\(episode)" }
}

@MainActor
private final class WatchHistoryStore: ObservableObject {
    @Published private(set) var entries: [WatchHistoryEntry]
    private let key = "anksubbrd.watch-history.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = (try? JSONDecoder().decode([WatchHistoryEntry].self, from: defaults.data(forKey: key) ?? Data())) ?? []
        entries.sort { $0.updatedAt > $1.updatedAt }
    }

    func position(for watchUrl: String, episode: Int) -> Double {
        entries.first(where: { $0.watchUrl == watchUrl && $0.episode == episode })?.positionSeconds ?? 0
    }

    func open(_ entry: WatchHistoryEntry) {
        var copy = entry
        copy.positionSeconds = position(for: entry.watchUrl, episode: entry.episode)
        upsert(copy)
    }

    func update(_ entry: WatchHistoryEntry, positionSeconds: Double) {
        var copy = entry
        copy.positionSeconds = positionSeconds
        upsert(copy)
    }

    private func upsert(_ entry: WatchHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        var copy = entry; copy.updatedAt = Date()
        entries.insert(copy, at: 0)
        entries = Array(entries.prefix(50))
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}

private func formatTime(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", value / 60, value % 60)
}
