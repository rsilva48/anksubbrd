import SwiftUI

/// Turns an episode of a loaded series into a playable session. Shared by the
/// episode list and the player, which uses it to move between episodes in place.
@MainActor
final class PlaybackResolver {
    private(set) var series: Series
    let anime: Anime
    private let profile: ProfileStore

    init(series: Series, anime: Anime, profile: ProfileStore) {
        self.series = series
        self.anime = anime
        self.profile = profile
    }

    func episode(adjacentTo number: Int, offset: Int) -> Episode? {
        guard let index = series.episodes.firstIndex(where: { $0.number == number }),
              series.episodes.indices.contains(index + offset) else { return nil }
        return series.episodes[index + offset]
    }

    func servers(for episode: Episode) async throws -> [Server] {
        try await retryingExpiredSession {
            let reply: ServerResponse = try await BridgeClient.get(
                base: profile.bridgeURL,
                path: "/api/series/\(series.seriesKey)/servers",
                query: [URLQueryItem(name: "episode", value: String(episode.number))]
            )
            return reply.servers
        }
    }

    /// Without an explicit server it prefers the given name and kind, then any
    /// server of that kind, then whatever the episode offers.
    func session(for episode: Episode, server: Server? = nil, preferredName: String? = nil, kind: StreamKind? = nil) async throws -> PlaybackSession {
        try await retryingExpiredSession {
            let chosen: Server
            if let server {
                chosen = server
            } else {
                let wanted = kind ?? profile.preferences.defaultTrack
                let reply: ServerResponse = try await BridgeClient.get(
                    base: profile.bridgeURL,
                    path: "/api/series/\(series.seriesKey)/servers",
                    query: [URLQueryItem(name: "episode", value: String(episode.number))]
                )
                guard let match = reply.servers.first(where: { $0.name == preferredName && $0.kind == wanted })
                    ?? reply.servers.first(where: { $0.kind == wanted })
                    ?? reply.servers.first else {
                    throw BridgeRequestError(message: "El episodio \(episode.number) no publicó servidores.")
                }
                chosen = match
            }
            let playback: Playback = try await BridgeClient.post(
                base: profile.bridgeURL,
                path: "/api/play",
                body: PlayRequest(seriesKey: series.seriesKey, episode: episode.number, serverIndex: chosen.index)
            )
            let resolvedKind = playback.serverKind.flatMap(StreamKind.init(rawValue:)) ?? chosen.kind
            let entry = WatchHistoryEntry(
                seriesTitle: series.title,
                watchUrl: anime.watchUrl,
                imageUrl: anime.imageUrl,
                episode: episode.number,
                episodeTitle: episode.title,
                serverName: playback.serverName,
                positionSeconds: profile.position(for: anime.watchUrl, episode: episode.number),
                updatedAt: Date(),
                titleJp: series.titleJp ?? anime.titleJp,
                serverKind: resolvedKind.rawValue
            )
            return PlaybackSession(playback: playback, historyEntry: entry, kind: resolvedKind)
        }
    }

    /// Series sessions expire on the bridge after 20 minutes (HTTP 410).
    /// Reload the series once and retry instead of asking to search again.
    private func retryingExpiredSession<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as BridgeRequestError where error.isExpiredSession {
            series = try await BridgeClient.post(base: profile.bridgeURL, path: "/api/series", body: WatchRequest(watchUrl: anime.watchUrl))
            return try await operation()
        }
    }
}

struct EpisodesScreen: View {
    @Environment(ProfileStore.self) private var profile
    @State private var current: Anime
    @State private var selectedSeasonURL: String
    @State private var latestEpisode: Int?
    @State private var series: Series?
    @State private var resolver: PlaybackResolver?
    @State private var seasons: [Season] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var serverChoice: EpisodeServers?
    @State private var activePlayer: PlayerModel?
    @State private var busyMessage: String?

    init(anime: Anime) {
        _current = State(initialValue: anime)
        _selectedSeasonURL = State(initialValue: anime.watchUrl)
        _latestEpisode = State(initialValue: anime.episode)
    }

    private var language: TitleLanguage { profile.preferences.titleLanguage }

    var body: some View {
        List {
            header
            if seasons.count > 1 {
                Section {
                    Picker("Temporada", selection: $selectedSeasonURL) {
                        ForEach(seasons) { season in
                            Text(label(for: season)).tag(season.watchUrl)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            if let errorMessage {
                Section {
                    ErrorNotice(message: errorMessage)
                    Button("Reintentar") { Task { await loadSeries() } }
                }
            }
            if let series {
                episodesSection(series)
            } else if loading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Cargando episodios…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(current.displayTitle(language))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: current.watchUrl) { await loadSeries() }
        .refreshable { await loadSeries() }
        .onChange(of: selectedSeasonURL) { _, url in
            // Seasons switch in place, so going back always returns to where
            // the user came from instead of unwinding a stack of seasons.
            guard url != current.watchUrl, let season = seasons.first(where: { $0.watchUrl == url }) else { return }
            latestEpisode = nil
            series = nil
            resolver = nil
            current = season.anime
        }
        .sheet(item: $serverChoice) { choice in
            ServerPicker(choice: choice, defaultKind: profile.preferences.defaultTrack) { server in
                serverChoice = nil
                start { try await $0.session(for: choice.episode, server: server) }
            }
        }
        .fullScreenCover(item: $activePlayer) { model in
            PlayerScreen(model: model)
        }
        .overlay {
            if let busyMessage {
                LoadingOverlay(message: busyMessage)
            }
        }
    }

    private var header: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                PosterImage(imageURL: current.imageUrl)
                    .frame(width: 96)
                VStack(alignment: .leading, spacing: 8) {
                    SeriesTitle(title: series?.title ?? current.title, titleJp: series?.titleJp ?? current.titleJp, language: language, font: .title3.weight(.bold), lineLimit: 3)
                    if !current.metadataLine.isEmpty {
                        Text(current.metadataLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let series {
                        Text("\(series.episodes.count) episodios")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(Color.clear)
            primaryAction
                .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let series {
            if let entry = profile.entry(for: current.watchUrl),
               let episode = series.episodes.first(where: { $0.number == entry.episode }) {
                Button {
                    start { try await $0.session(for: episode, preferredName: entry.serverName, kind: entry.kind) }
                } label: {
                    Label("Continuar episodio \(entry.episode) · \(formatTime(entry.positionSeconds))", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            } else if let episode = series.episodes.first(where: { $0.number == latestEpisode }) ?? series.episodes.first {
                Button {
                    chooseServer(for: episode)
                } label: {
                    Label(episode.number == latestEpisode ? "Ver episodio \(episode.number) (nuevo)" : "Empezar con el episodio \(episode.number)", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
    }

    private func episodesSection(_ series: Series) -> some View {
        let inProgress = profile.entry(for: current.watchUrl)
        return Section("Episodios") {
            ForEach(series.episodes) { episode in
                Button {
                    chooseServer(for: episode)
                } label: {
                    EpisodeRow(
                        episode: episode,
                        progress: inProgress?.episode == episode.number ? inProgress?.positionSeconds : nil,
                        isLatest: episode.number == latestEpisode
                    )
                }
            }
        }
    }

    private func label(for season: Season) -> String {
        let sameNumber = seasons.filter { $0.seasonNumber == season.seasonNumber }.count > 1
        return sameNumber ? season.anime.displayTitle(language) : "Temporada \(season.seasonNumber)"
    }

    private func loadSeries() async {
        let watchUrl = current.watchUrl
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let loaded: Series = try await BridgeClient.post(base: profile.bridgeURL, path: "/api/series", body: WatchRequest(watchUrl: watchUrl))
            guard watchUrl == current.watchUrl else { return }
            series = loaded
            seasons = loaded.seasons
            resolver = PlaybackResolver(series: loaded, anime: current, profile: profile)
        } catch is CancellationError {
            return
        } catch {
            guard watchUrl == current.watchUrl else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func chooseServer(for episode: Episode) {
        guard let resolver, busyMessage == nil else { return }
        Task {
            busyMessage = "Cargando servidores del episodio \(episode.number)…"
            defer { busyMessage = nil }
            do {
                let servers = try await resolver.servers(for: episode)
                serverChoice = EpisodeServers(episode: episode, servers: servers)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func start(_ resolve: @escaping (PlaybackResolver) async throws -> PlaybackSession) {
        guard let resolver, busyMessage == nil else { return }
        Task {
            busyMessage = "Preparando reproducción…"
            defer { busyMessage = nil }
            do {
                let session = try await resolve(resolver)
                activePlayer = PlayerModel(session: session, resolver: resolver, profile: profile)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct EpisodeRow: View {
    let episode: Episode
    let progress: Double?
    let isLatest: Bool

    var body: some View {
        HStack(spacing: 14) {
            Text(String(episode.number))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.subtitle ?? "Episodio \(episode.number)")
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let progress {
                    Label("Visto hasta \(formatTime(progress))", systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.tint)
                } else if isLatest {
                    Text("Nuevo")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle")
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

struct ServerPicker: View {
    let choice: EpisodeServers
    let defaultKind: StreamKind
    let onSelect: (Server) -> Void
    @State private var kind: StreamKind = .sub
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Tipo", selection: $kind) {
                        ForEach(StreamKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(kind.detail)
                }
                let servers = choice.servers.filter { $0.kind == kind }
                if servers.isEmpty {
                    ContentUnavailableView("Sin servidores \(kind.displayName)", systemImage: "tray", description: Text("Este episodio no publicó fuentes de este tipo."))
                } else {
                    Section("Servidores") {
                        ForEach(servers) { server in
                            Button {
                                onSelect(server)
                            } label: {
                                Label(server.name, systemImage: "play.circle")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Episodio \(choice.episode.number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", role: .cancel) { dismiss() }
                }
            }
            .onAppear {
                kind = choice.servers.contains { $0.kind == defaultKind } ? defaultKind : (choice.servers.first?.kind ?? defaultKind)
            }
        }
        .presentationDetents([.medium, .large])
    }
}
