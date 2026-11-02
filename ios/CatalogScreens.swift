import Observation
import SwiftUI

struct CatalogFilters: Equatable {
    var season = ""
    var status = ""
    var rating = ""
    var mediaType = ""
    var year = ""
    var minimumScore = 0

    /// Filters the bridge applies; the minimum score is applied on device.
    var hasServerFilters: Bool { !season.isEmpty || !status.isEmpty || !rating.isEmpty || !mediaType.isEmpty || !year.isEmpty }
    var isActive: Bool { hasServerFilters || minimumScore > 0 }

    func queryItems(page: Int, keyword: String? = nil) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "page", value: String(page))]
        if let keyword { items.append(URLQueryItem(name: "q", value: keyword)) }
        for (name, value) in [("season", season), ("status", status), ("rating", rating), ("mediaType", mediaType), ("year", year)] where !value.isEmpty {
            items.append(URLQueryItem(name: name, value: value))
        }
        return items
    }

    func allows(_ anime: Anime) -> Bool {
        minimumScore == 0 || (anime.score ?? 0) >= Double(minimumScore)
    }
}

/// Which episodes Recents follows: the configured kind by default.
enum CatalogLanguage: String, CaseIterable, Identifiable {
    case sub
    case dub
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sub: return "Sub"
        case .dub: return "Dub"
        case .all: return "Sub y Dub"
        }
    }

    init(_ kind: StreamKind) {
        self = kind == .dub ? .dub : .sub
    }
}

/// Paged catalog results. A new `reset` invalidates replies still in flight.
@MainActor
@Observable
final class CatalogFeed {
    typealias Page = (results: [Anime], hasNext: Bool)

    private(set) var items: [Anime] = []
    private(set) var isLoading = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false
    /// The last failure was a missing network connection.
    private(set) var isOffline = false

    @ObservationIgnored private var page = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var fetch: ((Int) async throws -> Page)?

    func reset(keepingItems: Bool = false, _ fetch: ((Int) async throws -> Page)?) async {
        generation += 1
        self.fetch = fetch
        page = 0
        hasMore = false
        isLoading = false
        errorMessage = nil
        if !keepingItems {
            items = []
            // Without a fetch there is nothing to wait for, so the empty state may show.
            hasLoaded = fetch == nil
        }
        await loadNextPage()
    }

    func loadNextPage() async {
        guard let fetch, !isLoading, page == 0 || hasMore else { return }
        let current = generation
        isLoading = true
        errorMessage = nil
        isOffline = false
        defer { if current == generation { isLoading = false } }
        do {
            let reply = try await fetch(page + 1)
            guard current == generation else { return }
            if page == 0 {
                items = reply.results
            } else {
                let known = Set(items.map(\.id))
                items += reply.results.filter { !known.contains($0.id) }
            }
            page += 1
            hasMore = reply.hasNext
            hasLoaded = true
        } catch is CancellationError {
            return
        } catch {
            guard current == generation else { return }
            errorMessage = error.localizedDescription
            isOffline = (error as? BridgeRequestError)?.isOffline ?? false
            hasLoaded = true
        }
    }
}

struct CatalogGrid<EmptyState: View>: View {
    let feed: CatalogFeed
    let filters: CatalogFilters
    let language: TitleLanguage
    @ViewBuilder let emptyState: () -> EmptyState

    private var visible: [Anime] { feed.items.filter(filters.allows) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 176), spacing: 14, alignment: .top)], alignment: .leading, spacing: 22) {
                ForEach(visible) { anime in
                    NavigationLink(value: anime) {
                        PosterCard(anime: anime, language: language)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if anime.id == visible.last?.id {
                            Task { await feed.loadNextPage() }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            VStack(spacing: 12) {
                if feed.isLoading {
                    ProgressView()
                } else if let errorMessage = feed.errorMessage, !(feed.isOffline && visible.isEmpty) {
                    ErrorNotice(message: errorMessage)
                    Button("Reintentar") { Task { await feed.loadNextPage() } }
                        .buttonStyle(.glass)
                } else if feed.hasMore {
                    // Score filtering can hide a whole page, so keep a manual way forward.
                    Button("Cargar más") { Task { await feed.loadNextPage() } }
                        .buttonStyle(.glass)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
        .overlay {
            if feed.hasLoaded, visible.isEmpty, !feed.isLoading {
                if feed.isOffline {
                    ContentUnavailableView {
                        Label("Sin conexión", systemImage: "wifi.slash")
                    } description: {
                        Text("El catálogo necesita internet. Los episodios descargados siguen disponibles en Descargas, y esta lista se carga sola al volver la conexión.")
                    } actions: {
                        Button("Reintentar") { Task { await feed.loadNextPage() } }
                            .buttonStyle(.glass)
                    }
                } else if feed.errorMessage == nil {
                    emptyState()
                }
            }
        }
    }
}

struct PosterCard: View {
    let anime: Anime
    let language: TitleLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PosterImage(imageURL: anime.imageUrl)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let badge = anime.episodeBadge {
                            PosterBadge(text: badge)
                        }
                        if let dub = anime.dubEpisodes {
                            PosterBadge(text: "DUB \(dub)")
                        }
                    }
                    .padding(6)
                }
                .overlay(alignment: .topTrailing) {
                    if anime.isAdult {
                        AdultBadge()
                            .padding(6)
                    }
                }
            Text(anime.displayTitle(language))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !anime.metadataLine.isEmpty {
                Text(anime.metadataLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct PosterBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct FeedKey: Equatable {
    let scope: String?
    let query: String
    let filters: CatalogFilters
    var language: CatalogLanguage? = nil
    /// Reloads a list that failed offline once the connection returns.
    var online = true
}

struct LatestScreen: View {
    @Environment(ProfileStore.self) private var profile
    @State private var feed = CatalogFeed()
    @State private var filters = CatalogFilters()
    @State private var showFilters = false
    @State private var loadedKey: FeedKey?
    /// Chosen in the toolbar for this session; otherwise the configured kind.
    @State private var languageOverride: CatalogLanguage?

    private var language: CatalogLanguage { languageOverride ?? CatalogLanguage(profile.preferences.defaultTrack) }
    private var key: FeedKey { FeedKey(scope: profile.scope, query: "", filters: filters, language: language, online: profile.isOnline) }

    var body: some View {
        NavigationStack {
            CatalogGrid(feed: feed, filters: filters, language: profile.preferences.titleLanguage) {
                ContentUnavailableView("Sin resultados", systemImage: "sparkles", description: Text(filters.isActive ? "Cambia o limpia los filtros." : "El catálogo no devolvió novedades."))
            }
            .navigationTitle("Recientes")
            .modifier(AdaptableTabRootTitleStyle())
            .navigationDestination(for: Anime.self) { EpisodesScreen(anime: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Episodios", selection: Binding(get: { language }, set: { languageOverride = $0 })) {
                            ForEach(CatalogLanguage.allCases) { Text($0.title).tag($0) }
                        }
                    } label: {
                        Label(language.title, systemImage: "captions.bubble")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityLabel("Episodios: \(language.title)")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    FiltersButton(isActive: filters.isActive) { showFilters = true }
                }
            }
            .sheet(isPresented: $showFilters) { CatalogFilterSheet(filters: $filters) }
            .task(id: key) {
                // Tab switches re-run the task; only reload when the inputs changed.
                guard key != loadedKey else { return }
                await reload(keepingItems: false)
                if !Task.isCancelled, feed.errorMessage == nil { loadedKey = key }
            }
            .refreshable { await reload(keepingItems: true) }
        }
    }

    private func reload(keepingItems: Bool) async {
        let base = profile.bridgeURL, filters = filters, language = language
        await feed.reset(keepingItems: keepingItems) { page in
            let query = filters.queryItems(page: page) + [URLQueryItem(name: "language", value: language.rawValue)]
            let reply: LatestResponse = try await BridgeClient.get(base: base, path: "/api/latest", query: query)
            return (reply.results, reply.hasNext)
        }
    }
}

struct SearchScreen: View {
    /// Changes every time the Search tab is selected.
    let activation: Int
    @Environment(ProfileStore.self) private var profile
    @State private var feed = CatalogFeed()
    @State private var query = ""
    @State private var searchPresented = false
    @State private var handledActivation = -1
    @State private var submittedQuery = ""
    @State private var filters = CatalogFilters()
    @State private var showFilters = false
    @State private var loadedKey: FeedKey?
    @AppStorage("anksubbrd.recent-searches") private var recentSearchesStorage = ""

    private var key: FeedKey { FeedKey(scope: profile.scope, query: submittedQuery, filters: filters, online: profile.isOnline) }

    private var recentSearches: [String] {
        recentSearchesStorage.split(separator: "\n").map(String.init)
    }

    var body: some View {
        NavigationStack {
            CatalogGrid(feed: feed, filters: filters, language: profile.preferences.titleLanguage) {
                if submittedQuery.isEmpty {
                    ContentUnavailableView("Busca una serie", systemImage: "magnifyingglass", description: Text("Escribe un título y pulsa Buscar. Los filtros también se aplican a la búsqueda."))
                } else {
                    ContentUnavailableView.search(text: submittedQuery)
                }
            }
            .navigationTitle("Buscar")
            .modifier(AdaptableTabRootTitleStyle())
            .navigationDestination(for: Anime.self) { EpisodesScreen(anime: $0) }
            .searchable(text: $query, isPresented: $searchPresented, prompt: "Título de la serie")
            .task(id: activation) {
                // Focus the field when the tab is selected, but not when the
                // screen reappears after going back from a series.
                guard activation != handledActivation else { return }
                handledActivation = activation
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                searchPresented = true
            }
            .searchSuggestions {
                if query.isEmpty {
                    ForEach(recentSearches, id: \.self) { recent in
                        Label(recent, systemImage: "clock.arrow.circlepath")
                            .searchCompletion(recent)
                    }
                }
            }
            .onSubmit(of: .search, submit)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    FiltersButton(isActive: filters.isActive) { showFilters = true }
                }
            }
            .sheet(isPresented: $showFilters) { CatalogFilterSheet(filters: $filters) }
            .task(id: key) {
                guard key != loadedKey else { return }
                await runSearch()
                if !Task.isCancelled, feed.errorMessage == nil { loadedKey = key }
            }
            .refreshable { await runSearch() }
        }
    }

    private func submit() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if value == submittedQuery {
            // Same key, so the task will not re-run: search again explicitly.
            Task { await runSearch() }
        }
        submittedQuery = value
        let updated = [value] + recentSearches.filter { $0.caseInsensitiveCompare(value) != .orderedSame }
        recentSearchesStorage = updated.prefix(8).joined(separator: "\n")
    }

    private func runSearch() async {
        let keyword = submittedQuery, base = profile.bridgeURL, filters = filters
        guard !keyword.isEmpty else {
            await feed.reset(nil)
            return
        }
        await feed.reset { page in
            if filters.hasServerFilters {
                let reply: LatestResponse = try await BridgeClient.get(base: base, path: "/api/latest", query: filters.queryItems(page: page, keyword: keyword))
                return (reply.results, reply.hasNext)
            }
            let reply: SearchResponse = try await BridgeClient.get(base: base, path: "/api/search", query: [URLQueryItem(name: "q", value: keyword)])
            return (reply.results, false)
        }
    }
}

private struct FiltersButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Filtros", systemImage: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }
}

struct CatalogFilterSheet: View {
    @Binding var filters: CatalogFilters
    @State private var draft = CatalogFilters()
    @Environment(\.dismiss) private var dismiss

    private let years = Array((1980...(Calendar.current.component(.year, from: Date()) + 1)).reversed())

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Temporada", selection: $draft.season) {
                        Text("Todas").tag("")
                        Text("Invierno").tag("winter")
                        Text("Primavera").tag("spring")
                        Text("Verano").tag("summer")
                        Text("Otoño").tag("fall")
                    }
                    Picker("Estado", selection: $draft.status) {
                        Text("Todos").tag("")
                        Text("En emisión").tag("currently-airing")
                        Text("Finalizado").tag("finished-airing")
                        Text("Próximamente").tag("not-yet-aired")
                    }
                    Picker("Clasificación", selection: $draft.rating) {
                        Text("Todas").tag("")
                        ForEach(["G", "PG", "PG-13", "R", "R+", "Rx"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Tipo", selection: $draft.mediaType) {
                        Text("Todos").tag("")
                        ForEach(["TV", "Movie", "ONA", "OVA", "Special"], id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Año", selection: $draft.year) {
                        Text("Todos").tag("")
                        ForEach(years, id: \.self) { Text(String($0)).tag(String($0)) }
                    }
                    Picker("Puntuación mínima", selection: $draft.minimumScore) {
                        Text("Cualquiera").tag(0)
                        ForEach([5, 6, 7, 8, 9], id: \.self) { Text("\($0).0+").tag($0) }
                    }
                } footer: {
                    Text("La puntuación mínima se aplica a los resultados ya cargados.")
                }
                Section {
                    Button("Limpiar filtros", role: .destructive) { draft = CatalogFilters() }
                        .disabled(!draft.isActive)
                }
            }
            .navigationTitle("Filtros")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Aplicar") {
                        filters = draft
                        dismiss()
                    }
                }
            }
            .onAppear { draft = filters }
        }
        .presentationDetents([.medium, .large])
    }
}
