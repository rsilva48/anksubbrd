import SwiftUI
import Translation

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

    /// Without an explicit server it plays a local download of that kind when
    /// there is one; otherwise it prefers the given name and kind, then any
    /// server of that kind, then whatever the episode offers.
    func session(for episode: Episode, server: Server? = nil, preferredName: String? = nil, kind: StreamKind? = nil, allowDownload: Bool = true) async throws -> PlaybackSession {
        if server == nil, allowDownload,
           let local = DownloadStore.shared.localSession(
               watchUrl: anime.watchUrl,
               episode: episode.number,
               kind: kind ?? profile.preferences.defaultTrack,
               position: profile.position(for: anime.watchUrl, episode: episode.number)
           ) {
            return local
        }
        return try await retryingExpiredSession {
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
                serverKind: resolvedKind.rawValue,
                totalEpisodes: series.totalEpisodes
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
    @Environment(DownloadStore.self) private var downloads
    @State private var current: Anime
    @State private var selectedSeasonURL: String
    @State private var latestEpisode: Int?
    @State private var series: Series?
    @State private var resolver: PlaybackResolver?
    @State private var seasons: [Season] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var serverChoice: EpisodeServers?
    @State private var downloadRequest: DownloadRequest?
    /// Episodes of the last batch that used another server or were skipped.
    @State private var downloadNotice: String?
    /// The bridge could not be reached: saved series data and downloads only.
    @State private var isOffline = false
    @State private var pendingServer: (episode: Episode, server: Server)?
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
            if let synopsis = series?.synopsis, !synopsis.isEmpty {
                Section("Sinopsis") {
                    SynopsisText(text: synopsis)
                }
            }
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
            if let downloadNotice {
                Section {
                    Label(downloadNotice, systemImage: "info.circle")
                        .font(.footnote)
                    Button("Entendido") { self.downloadNotice = nil }
                        .font(.footnote)
                }
            }
            if isOffline {
                Section {
                    Label("Sin conexión con el bridge. Se muestran los datos guardados y sólo se pueden reproducir los episodios descargados.", systemImage: "wifi.slash")
                        .font(.footnote)
                    Button("Reintentar") { Task { await loadSeries() } }
                        .font(.footnote)
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
        // The title is shown next to the poster only.
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
        // The player is presented only once the server sheet has finished
        // dismissing; presenting during that animation is silently dropped.
        .sheet(item: $serverChoice, onDismiss: startPendingServer) { choice in
            ServerPicker(choice: choice, defaultKind: profile.preferences.defaultTrack) { server in
                pendingServer = (episode: choice.episode, server: server)
                serverChoice = nil
            }
        }
        .sheet(item: $downloadRequest) { request in
            ServerPicker(choice: request.choice, defaultKind: request.kind, title: request.title, actionSymbol: "arrow.down.circle") { server in
                downloadRequest = nil
                download(request.episodes, server: server)
            }
        }
        .fullScreenCover(item: $activePlayer, onDismiss: { downloads.cleanUpWatched(profile: profile) }) { model in
            PlayerScreen(model: model)
        }
        .toolbar {
            if let series, !isOffline {
                ToolbarItem(placement: .topBarTrailing) {
                    downloadMenu(series)
                }
            }
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
                PosterImage(imageURL: current.imageUrl ?? series?.imageUrl)
                    .frame(width: 96)
                VStack(alignment: .leading, spacing: 8) {
                    SeriesTitle(title: series?.title ?? current.title, titleJp: series?.titleJp ?? current.titleJp, language: language, font: .title3.weight(.bold), lineLimit: 3)
                    if current.isAdult || series?.isAdult == true {
                        AdultBadge()
                    }
                    if !metadataLine.isEmpty {
                        Text(metadataLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let series {
                        Text(episodeCountLine(series))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let next = series.nextEpisodeDate {
                            Label("Próximo episodio: \(airingLabel(next))", systemImage: "calendar.badge.clock")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
            primaryAction
                .listRowBackground(Color.clear)
        }
    }

    private var metadataLine: String {
        let fromSeries = series?.metadataLine ?? ""
        return fromSeries.isEmpty ? current.metadataLine : fromSeries
    }

    private func episodeCountLine(_ series: Series) -> String {
        if let total = series.totalEpisodes, total > series.episodes.count {
            return "\(series.episodes.count) de \(total) episodios"
        }
        return "\(series.episodes.count) episodios"
    }

    /// The season that follows this one in the watch order, skipping extras
    /// such as specials when a regular season comes later.
    private var followingSeason: Season? {
        let path = catalogPath(of: current.watchUrl)
        guard let index = seasons.firstIndex(where: { catalogPath(of: $0.watchUrl) == path }) else { return nil }
        let following = seasons[(index + 1)...]
        return following.first { !$0.isExtra } ?? following.first
    }

    @ViewBuilder
    private var primaryAction: some View {
        if let series {
            if let entry = profile.entry(for: current.watchUrl),
               let episode = series.episodes.first(where: { $0.number == entry.episode }) {
                let kind = entry.kind ?? profile.preferences.defaultTrack
                if !entry.isCompleted {
                    actionButton("Continuar episodio \(entry.episode) · \(formatTime(entry.positionSeconds))") {
                        start { try await $0.session(for: episode, preferredName: entry.serverName, kind: entry.kind) }
                    }
                } else if let next = series.episode(after: entry.episode, kind: kind) {
                    // Finished episodes never reopen on their last second:
                    // the next one with the same Sub/Dub kind starts instead.
                    actionButton("Ver episodio \(next.number) · siguiente") {
                        start { try await $0.session(for: next, preferredName: entry.serverName, kind: kind) }
                    }
                } else {
                    let finished = isFinalEpisode(entry.episode, totalEpisodes: series.totalEpisodes, status: series.status, latestEpisode: series.episodes.last?.number)
                    if finished, let nextSeason = followingSeason {
                        actionButton("Ver \(label(for: nextSeason))", systemImage: "forward.fill") {
                            selectedSeasonURL = nextSeason.watchUrl
                        }
                    }
                    Label(
                        finished ? "Serie completada · viste los \(entry.episode) episodios" : "Estás al día: viste el episodio \(entry.episode). Aparecerá aquí cuando salga el siguiente en \(kind.displayName).",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    Button {
                        start { try await $0.session(for: episode, preferredName: entry.serverName, kind: entry.kind) }
                    } label: {
                        Label("Volver a ver el episodio \(entry.episode)", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            } else if let episode = series.episodes.first(where: { $0.number == latestEpisode }) ?? series.episodes.first {
                Button {
                    open(episode)
                } label: {
                    Label(episode.number == latestEpisode ? "Ver episodio \(episode.number) (nuevo)" : "Empezar con el episodio \(episode.number)", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String = "play.fill", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }

    private func episodesSection(_ series: Series) -> some View {
        let entry = profile.entry(for: current.watchUrl)
        let kind = entry?.kind ?? profile.preferences.defaultTrack
        return Section("Episodios") {
            ForEach(series.episodes) { episode in
                // Two independent controls in the row: non-default button
                // styles keep a tap on one from triggering the other.
                let playable = !isOffline || downloads.record(watchUrl: current.watchUrl, episode: episode.number)?.state == .completed
                HStack(spacing: 10) {
                    Button {
                        open(episode)
                    } label: {
                        EpisodeRow(
                            episode: episode,
                            progress: entry?.episode == episode.number && entry?.isCompleted == false ? entry?.positionSeconds : nil,
                            watched: entry.map { episode.number < $0.episode || (episode.number == $0.episode && $0.isCompleted) } ?? false,
                            isLatest: episode.number == latestEpisode,
                            missingKind: episode.isAvailable(for: kind) ? nil : kind
                        )
                    }
                    .buttonStyle(.plain)
                    // Offline, only downloaded episodes can play.
                    .disabled(!playable)
                    .opacity(playable ? 1 : 0.45)
                    downloadControl(for: episode, kind: kind)
                }
                .contextMenu {
                    ForEach(StreamKind.allCases.filter { episode.isAvailable(for: $0) }) { option in
                        if downloads.record(watchUrl: current.watchUrl, episode: episode.number, kind: option)?.state != .completed {
                            Button("Descargar en \(option.displayName)", systemImage: "arrow.down.circle") {
                                requestDownload([episode], kind: option)
                            }
                        }
                    }
                    Button("Elegir servidor en línea", systemImage: "antenna.radiowaves.left.and.right") {
                        chooseServer(for: episode)
                    }
                    if let record = downloads.record(watchUrl: current.watchUrl, episode: episode.number) {
                        Button(record.state == .downloading ? "Cancelar descarga" : "Borrar descarga", systemImage: "trash", role: .destructive) {
                            downloads.remove(record)
                        }
                    }
                }
                .swipeActions(edge: .leading) {
                    if episode.isAvailable(for: kind), downloads.record(watchUrl: current.watchUrl, episode: episode.number, kind: kind) == nil {
                        Button {
                            requestDownload([episode], kind: kind)
                        } label: {
                            Label("Descargar", systemImage: "arrow.down.circle")
                        }
                        .tint(.indigo)
                    }
                }
            }
        }
    }

    private func label(for season: Season) -> String {
        if let label = season.localizedLabel { return label }
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
            isOffline = false
            series = loaded
            seasons = loaded.seasons
            resolver = PlaybackResolver(series: loaded, anime: current, profile: profile)
            SeriesCache.store(loaded, for: watchUrl)
        } catch is CancellationError {
            return
        } catch {
            guard watchUrl == current.watchUrl else { return }
            // Offline: the last saved copy of the series, or its downloads.
            if let saved = SeriesCache.load(watchUrl) ?? downloads.offlineSeries(watchUrl: watchUrl) {
                isOffline = true
                series = saved
                seasons = saved.seasons
                resolver = PlaybackResolver(series: saved, anime: current, profile: profile)
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Download button of an episode row, or its download state with the
    /// actions that apply to it.
    @ViewBuilder
    private func downloadControl(for episode: Episode, kind: StreamKind) -> some View {
        if let record = downloads.record(watchUrl: current.watchUrl, episode: episode.number) {
            Menu {
                if record.state == .completed {
                    Button("Ver sin conexión", systemImage: "play.fill") { open(episode) }
                }
                if record.state == .failed {
                    Button("Reintentar descarga", systemImage: "arrow.clockwise") {
                        downloads.remove(record)
                        requestDownload([episode], kind: record.kind)
                    }
                }
                Button(record.state == .downloading ? "Cancelar descarga" : "Borrar descarga", systemImage: "trash", role: .destructive) {
                    downloads.remove(record)
                }
            } label: {
                DownloadBadge(record: record)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
        } else if episode.isAvailable(for: kind) {
            Button {
                requestDownload([episode], kind: kind)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title3)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Descargar episodio \(episode.number) en \(kind.displayName)")
        }
    }

    /// Downloaded episodes play from disk; the rest ask for a server.
    private func open(_ episode: Episode) {
        let preferred = profile.entry(for: current.watchUrl)?.kind ?? profile.preferences.defaultTrack
        let local = [preferred, preferred == .sub ? .dub : .sub].first {
            downloads.record(watchUrl: current.watchUrl, episode: episode.number, kind: $0)?.state == .completed
        }
        if let local {
            start { try await $0.session(for: episode, kind: local) }
        } else {
            chooseServer(for: episode)
        }
    }

    /// Downloads the next episodes the viewer has not watched yet.
    private func downloadMenu(_ series: Series) -> some View {
        let entry = profile.entry(for: current.watchUrl)
        let kind = entry?.kind ?? profile.preferences.defaultTrack
        let first = entry.map { $0.isCompleted ? $0.episode + 1 : $0.episode } ?? series.episodes.first?.number ?? 1
        let pending = series.episodes.filter {
            $0.number >= first && $0.isAvailable(for: kind)
                && downloads.record(watchUrl: current.watchUrl, episode: $0.number, kind: kind) == nil
        }
        return Menu {
            Section("Descargar en \(kind.displayName) para ver sin conexión") {
                if let next = pending.first {
                    Button(entry == nil ? "Episodio \(next.number)" : "Episodio \(next.number) · siguiente") {
                        requestDownload([next], kind: kind)
                    }
                }
                if pending.count > 3 {
                    Button("Siguientes 3 episodios") {
                        requestDownload(Array(pending.prefix(3)), kind: kind)
                    }
                }
                if pending.count > 1, let last = pending.last {
                    Button(entry == nil ? "Serie completa · \(pending.count) episodios" : "Los que faltan · episodios \(pending[0].number) a \(last.number)") {
                        requestDownload(pending, kind: kind)
                    }
                }
            }
            Section {
                Text("Cada episodio también tiene su botón de descarga en la lista.")
            }
        } label: {
            Label("Descargar", systemImage: "arrow.down.circle")
        }
        .disabled(pending.isEmpty)
    }

    /// Asks for the server with the servers of the first episode, as
    /// playback does; see `download(_:server:)` for the rest of a batch.
    private func requestDownload(_ episodes: [Episode], kind: StreamKind) {
        guard let resolver, busyMessage == nil, let first = episodes.first else { return }
        Task {
            busyMessage = "Cargando servidores del episodio \(first.number)…"
            defer { busyMessage = nil }
            do {
                let servers = try await resolver.servers(for: first)
                downloadRequest = DownloadRequest(episodes: episodes, kind: kind, choice: EpisodeServers(episode: first, servers: servers))
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Resolves each episode online (one at a time) and hands it to the
    /// background download session. Servers differ between episodes and can
    /// fail: each episode tries a server with the chosen name, then the other
    /// servers of the same kind; an episode without any is skipped.
    private func download(_ episodes: [Episode], server: Server) {
        guard let resolver, busyMessage == nil, let first = episodes.first else { return }
        downloadNotice = nil
        Task {
            defer { busyMessage = nil }
            var notes: [String] = []
            for episode in episodes {
                busyMessage = "Preparando la descarga del episodio \(episode.number)…"
                do {
                    // The picked server first (it belongs to the first
                    // episode), then any server of the same kind.
                    var resolved: PlaybackSession?
                    if episode == first {
                        resolved = try? await resolver.session(for: episode, server: server, allowDownload: false)
                    }
                    if resolved == nil {
                        resolved = try await resolver.downloadSession(for: episode, kind: server.kind, preferredName: server.name, excluding: episode == first ? [server.name] : [])
                    }
                    guard let session = resolved else {
                        notes.append("Episodio \(episode.number): sin servidores \(server.kind.displayName) disponibles, no se descarga.")
                        continue
                    }
                    if session.playback.serverName != server.name {
                        notes.append("Episodio \(episode.number): \(server.name) no estaba disponible, se usa \(session.playback.serverName).")
                    }
                    await downloads.start(session, triedServers: session.playback.serverName == server.name ? [] : [server.name])
                } catch is CancellationError {
                    return
                } catch {
                    notes.append("Episodio \(episode.number): \(error.localizedDescription)")
                }
            }
            downloadNotice = notes.isEmpty ? nil : notes.joined(separator: "\n")
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

    private func startPendingServer() {
        guard let pending = pendingServer else { return }
        pendingServer = nil
        start { try await $0.session(for: pending.episode, server: pending.server) }
    }

    private func start(_ resolve: @escaping (PlaybackResolver) async throws -> PlaybackSession) {
        guard let resolver, busyMessage == nil, activePlayer == nil else { return }
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
    let watched: Bool
    let isLatest: Bool
    /// Sub/Dub kind the viewer uses that this episode does not have yet.
    let missingKind: StreamKind?

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
                if let missingKind {
                    Text("Aún sin \(missingKind.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: watched ? "checkmark.circle.fill" : "play.circle")
                .foregroundStyle(watched ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityLabel(watched ? "Visto" : "Reproducir")
        }
        .contentShape(Rectangle())
    }
}

/// Synopsis clamped to a few lines with a toggle for long texts. Catalog
/// synopses are in English; Apple's on-device Translation renders them in the
/// device language (iOS asks to download the languages the first time).
private struct SynopsisText: View {
    let text: String
    @AppStorage(DeviceSettings.translateSynopsisKey) private var translateAutomatically = false
    @State private var expanded = false
    @State private var translated: String?
    @State private var showsTranslation = false
    @State private var translating = false
    @State private var configuration: TranslationSession.Configuration?

    /// Nothing to translate when the device already reads English.
    private var canTranslate: Bool { Locale.current.language.languageCode?.identifier != "en" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(showsTranslation ? translated ?? text : text)
                .font(.subheadline)
                .lineLimit(expanded ? nil : 4)
                .textSelection(.enabled)
            HStack(spacing: 16) {
                if text.count > 220 {
                    Button(expanded ? "Menos" : "Más") {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    }
                }
                Spacer(minLength: 0)
                if canTranslate {
                    if translating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button(showsTranslation ? "Ver original" : "Traducir", systemImage: "translate", action: toggleTranslation)
                    }
                }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .translationTask(configuration) { session in
            do {
                let response = try await session.translate(text)
                translated = response.targetText
                showsTranslation = true
            } catch {
                showsTranslation = false
            }
            translating = false
        }
        .onAppear {
            if translateAutomatically, canTranslate, translated == nil { requestTranslation() }
        }
    }

    private func toggleTranslation() {
        if showsTranslation {
            showsTranslation = false
        } else if translated != nil {
            showsTranslation = true
        } else {
            requestTranslation()
        }
    }

    /// English to the device language (`target: nil`).
    private func requestTranslation() {
        translating = true
        if configuration == nil {
            configuration = TranslationSession.Configuration(source: Locale.Language(identifier: "en"), target: nil)
        } else {
            configuration?.invalidate()
        }
    }
}

/// Episodes waiting for the user to pick a download server.
private struct DownloadRequest: Identifiable {
    let episodes: [Episode]
    let kind: StreamKind
    let choice: EpisodeServers
    var id: Int { choice.id }

    var title: String {
        episodes.count == 1 ? "Descargar episodio \(choice.episode.number)" : "Descargar \(episodes.count) episodios"
    }
}

struct ServerPicker: View {
    let choice: EpisodeServers
    let defaultKind: StreamKind
    var title: String? = nil
    var actionSymbol = "play.circle"
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
                                Label(server.name, systemImage: actionSymbol)
                            }
                        }
                    }
                }
            }
            .navigationTitle(title ?? "Episodio \(choice.episode.number)")
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
