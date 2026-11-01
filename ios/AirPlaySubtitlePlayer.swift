import AVKit
import AVFAudio
import CoreMedia
import CryptoKit
import Foundation
import Security
import SwiftUI
import UIKit

@main
struct AirPlaySubtitlePlayerApp: App {
    @StateObject private var history = WatchHistoryStore()

    init() {
        configureAirPlayVideoSession()
    }

    var body: some Scene {
        WindowGroup {
            MainTabScreen()
                .environmentObject(history)
        }
    }
}

private func configureAirPlayVideoSession() {
    do {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
        try AVAudioSession.sharedInstance().setActive(true)
    } catch {
        // AVPlayer still presents its native route picker if activation is
        // temporarily unavailable (for example during a phone call).
    }
}

private enum HistoryIdentity {
    static func storageID(for token: String, bridgeBaseURL: String) -> String {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = BridgeEndpoint.canonicalURL(bridgeBaseURL) ?? "unconfigured"
        let material = "\(endpoint)\u{0}\(value.isEmpty ? "local" : value)"
        return SHA256.hash(data: Data(material.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func legacyStorageID(for token: String) -> String {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "local" }
        return SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

private enum BridgeEndpoint {
    static func canonicalURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.path = ""
        components.query = nil
        components.fragment = nil
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        return components.url?.absoluteString
    }

    static func isVerified(_ verifiedURL: String, currentURL: String) -> Bool {
        guard let current = canonicalURL(currentURL) else { return false }
        return verifiedURL == current
    }

    static func tokenAccount(for bridgeBaseURL: String) -> String? {
        guard let endpoint = canonicalURL(bridgeBaseURL) else { return nil }
        let digest = SHA256.hash(data: Data(endpoint.utf8)).map { String(format: "%02x", $0) }.joined()
        return "bridge-token.\(digest)"
    }
}

private enum SecureTokenStore {
    private static let service = "com.personal.airplaysubtitleplayer"
    private static let legacyAccount = "bridge-access-token"
    private static let legacyDefaultsKey = "anksubbrd.bridge-access-token"

    static func currentToken(for bridgeBaseURL: String) -> String {
        guard let account = BridgeEndpoint.tokenAccount(for: bridgeBaseURL) else { return "" }
        return token(forAccount: account, synchronizable: kSecAttrSynchronizableAny) ?? ""
    }

    static func restoreFromICloud(for bridgeBaseURL: String) throws -> String {
        guard let account = BridgeEndpoint.tokenAccount(for: bridgeBaseURL) else {
            throw BridgeRequestError(message: "Primero escribe una URL válida del bridge.")
        }
        guard let token = token(forAccount: account, synchronizable: true) else {
            throw BridgeRequestError(message: "No hay una identidad para esta URL en el Llavero de iCloud todavía.")
        }
        return token
    }

    static func migrateLegacyToken(to bridgeBaseURL: String) throws -> Bool {
        guard currentToken(for: bridgeBaseURL).isEmpty else { return false }
        let legacyToken = token(forAccount: legacyAccount, synchronizable: kSecAttrSynchronizableAny)
            ?? UserDefaults.standard.string(forKey: legacyDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let legacyToken, !legacyToken.isEmpty else { return false }
        try save(legacyToken, for: bridgeBaseURL)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        deleteLegacyToken()
        return true
    }

    static func save(_ token: String, for bridgeBaseURL: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: try account(for: bridgeBaseURL),
            kSecAttrSynchronizable as String: true,
        ]
        let data = Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !data.isEmpty else { throw BridgeRequestError(message: "El token no puede estar vacío.") }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw BridgeRequestError(message: "No se pudo guardar el token en el Llavero.") }
        var add = query
        attributes.forEach { add[$0.key] = $0.value }
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw BridgeRequestError(message: "No se pudo guardar el token en el Llavero.")
        }
    }

    private static func account(for bridgeBaseURL: String) throws -> String {
        guard let account = BridgeEndpoint.tokenAccount(for: bridgeBaseURL) else {
            throw BridgeRequestError(message: "Primero escribe una URL válida del bridge.")
        }
        return account
    }

    private static func token(forAccount account: String, synchronizable: Any) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            return nil
        }
        return token
    }

    private static func deleteLegacyToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: legacyAccount,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private enum TokenGenerator {
    static func make() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BridgeRequestError(message: "No se pudo generar un token seguro.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private struct NativeSidebarAdaptableTabStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), UIDevice.current.userInterfaceIdiom == .pad {
            content.tabViewStyle(.sidebarAdaptable)
        } else {
            content
        }
    }
}

/// On iPad, the native adaptable tab bar shares the navigation-bar area while
/// morphing to and from the sidebar. Keeping root titles inline avoids a large
/// title being partially covered during that system transition. iPhone keeps
/// its normal large-title appearance.
private struct AdaptableTabRootTitleStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}

struct MainTabScreen: View {
    @AppStorage("anksubbrd.bridge-base-url") private var bridgeBaseURL = "http://192.168.1.20:8787"
    @AppStorage("anksubbrd.bridge-token-version") private var bridgeTokenVersion = 0
    @EnvironmentObject private var history: WatchHistoryStore
    @State private var requestedLocalNetworkAccess = false

    var body: some View {
        TabView {
            SearchScreen(bridgeBaseURL: bridgeBaseURL)
                .tabItem { Label("Buscar", systemImage: "magnifyingglass") }

            HistoryScreen(bridgeBaseURL: bridgeBaseURL)
                .tabItem { Label("Continuar viendo", systemImage: "play.circle") }

            SettingsScreen()
                .tabItem { Label("Configuración", systemImage: "gearshape") }
        }
        .modifier(NativeSidebarAdaptableTabStyle())
        .tint(.indigo)
        .task(id: "\(bridgeBaseURL)|\(bridgeTokenVersion)") {
            history.activate(token: SecureTokenStore.currentToken(for: bridgeBaseURL), bridgeBaseURL: bridgeBaseURL)
            await requestLocalNetworkAccess()
            await history.sync(with: bridgeBaseURL, force: true)
        }
    }

    private func requestLocalNetworkAccess() async {
        guard !requestedLocalNetworkAccess else { return }
        requestedLocalNetworkAccess = true
        // A foreground request to the configured private address makes iOS show
        // its Local Network consent alert before the user starts a catalog action.
        // The result is deliberately ignored: this is only a permission warm-up.
        let _: HealthResponse? = try? await BridgeClient.get(base: bridgeBaseURL, path: "/health", timeoutInterval: 5)
    }
}

struct SearchScreen: View {
    let bridgeBaseURL: String
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var query = ""
    @State private var results: [Anime] = []
    @State private var ratingFilter = "Todos"
    @State private var minimumScore = 0
    @State private var mediaTypeFilter = "Todos"
    @State private var yearFilter = "Todos"
    @State private var loading = false
    @State private var errorMessage: String?

    private var ratingOptions: [String] { ["Todos"] + Array(Set(results.compactMap(\.rating))).sorted() }
    private var mediaTypeOptions: [String] { ["Todos"] + Array(Set(results.compactMap(\.mediaType))).sorted() }
    private var yearOptions: [String] { ["Todos"] + Array(Set(results.compactMap(\.year))).sorted(by: >).map(String.init) }
    private var filteredResults: [Anime] {
        results.filter { anime in
            (ratingFilter == "Todos" || anime.rating == ratingFilter)
                && (minimumScore == 0 || (anime.score ?? 0) >= Double(minimumScore))
                && (mediaTypeFilter == "Todos" || anime.mediaType == mediaTypeFilter)
                && (yearFilter == "Todos" || String(anime.year ?? 0) == yearFilter)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if horizontalSizeClass == .regular {
                    tabletContent
                } else {
                    phoneContent
                }
            }
            .navigationTitle("AirPlay Subtitles")
            .modifier(AdaptableTabRootTitleStyle())
        }
    }

    private var phoneContent: some View {
        List {
            Section {
                HStack {
                    TextField("Título de anime", text: $query)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .onSubmit { search() }
                    Button("Buscar") { search() }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                }
            } header: {
                Text("Buscar")
            } footer: {
                Text("El bridge local se configura en la pestaña Configuración.")
            }

            if loading {
                Section { ProgressView("Consultando catálogo…") }
            }

            if let errorMessage {
                Section { ErrorNotice(message: errorMessage) }
            }

            if !results.isEmpty {
                Section("Filtros") {
                    filterControls
                }
                Section("Resultados (\(filteredResults.count))") {
                    ForEach(filteredResults) { anime in
                        NavigationLink {
                            EpisodesScreen(bridgeBaseURL: bridgeBaseURL, anime: anime)
                        } label: {
                            AnimeRow(anime: anime)
                        }
                    }
                    if filteredResults.isEmpty {
                        ContentPlaceholder(icon: "line.3.horizontal.decrease.circle", title: "Sin coincidencias", detail: "Cambia o limpia los filtros para ver otros resultados.")
                    }
                }
            } else if !loading && errorMessage == nil {
                Section {
                    ContentPlaceholder(icon: "sparkle.magnifyingglass", title: "Busca una serie", detail: "Escribe un título para consultar el catálogo desde tu bridge.")
                }
            }
        }
    }

    private var tabletContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: "magnifyingglass")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField("Busca una serie", text: $query)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        .onSubmit { search() }
                    Button { search() } label: {
                        Label("Buscar", systemImage: "arrow.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                }
                .padding(18)
                .liquidGlassCard()

                if loading {
                    HStack { ProgressView(); Text("Consultando catálogo…") }
                        .padding(18)
                        .liquidGlassCard()
                }

                if let errorMessage {
                    ErrorNotice(message: errorMessage)
                        .padding(18)
                        .liquidGlassCard()
                }

                if !results.isEmpty {
                    Text("Filtros")
                        .font(.title2.bold())
                    filterControls
                        .padding(18)
                        .liquidGlassCard()
                    Text("Resultados (\(filteredResults.count))")
                        .font(.title2.bold())
                    LiquidGlassGroup {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 18)], spacing: 18) {
                            ForEach(filteredResults) { anime in
                                NavigationLink {
                                    EpisodesScreen(bridgeBaseURL: bridgeBaseURL, anime: anime)
                                } label: {
                                    AnimeCard(anime: anime)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if filteredResults.isEmpty {
                        ContentPlaceholder(icon: "line.3.horizontal.decrease.circle", title: "Sin coincidencias", detail: "Cambia o limpia los filtros para ver otros resultados.")
                            .liquidGlassCard()
                    }
                } else if !loading && errorMessage == nil {
                    ContentPlaceholder(icon: "sparkle.magnifyingglass", title: "Busca una serie", detail: "Escribe un título para consultar el catálogo desde tu bridge.")
                        .liquidGlassCard()
                }
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(24)
        }
    }

    private var filterControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("PG Rating", selection: $ratingFilter) {
                ForEach(ratingOptions, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Puntuación mínima", selection: $minimumScore) {
                Text("Cualquiera").tag(0)
                ForEach([5, 6, 7, 8, 9], id: \.self) { score in
                    Text("\(score).0+").tag(score)
                }
            }
            .pickerStyle(.menu)
            Picker("Tipo", selection: $mediaTypeFilter) {
                ForEach(mediaTypeOptions, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            Picker("Año", selection: $yearFilter) {
                ForEach(yearOptions, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            if ratingFilter != "Todos" || minimumScore != 0 || mediaTypeFilter != "Todos" || yearFilter != "Todos" {
                Button("Limpiar filtros") {
                    ratingFilter = "Todos"; minimumScore = 0; mediaTypeFilter = "Todos"; yearFilter = "Todos"
                }
            }
        }
    }

    private func search() {
        let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchQuery.isEmpty else { return }
        Task { @MainActor in
            loading = true
            errorMessage = nil
            defer { loading = false }
            do {
                let reply: SearchResponse = try await BridgeClient.get(
                    base: bridgeBaseURL,
                    path: "/api/search",
                    query: [URLQueryItem(name: "q", value: searchQuery)]
                )
                results = reply.results
                ratingFilter = "Todos"; minimumScore = 0; mediaTypeFilter = "Todos"; yearFilter = "Todos"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct HistoryScreen: View {
    let bridgeBaseURL: String
    @EnvironmentObject private var history: WatchHistoryStore
    @State private var selectedEntryIDs = Set<WatchHistoryEntry.ID>()
    @State private var editMode: EditMode = .inactive
    @State private var showBulkDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            historyList
                .navigationTitle("Continuar viendo")
                .modifier(AdaptableTabRootTitleStyle())
                .toolbar {
                    // Keep these items registered. TabView's adaptable
                    // navigation bar does not reliably insert a ToolbarItem
                    // that first appears after EditButton changes state.
                    ToolbarItem(placement: .topBarTrailing) {
                        selectAllButton
                            .frame(width: editMode.isEditing ? nil : 0)
                            .clipped()
                            .opacity(editMode.isEditing ? 1 : 0)
                            .allowsHitTesting(editMode.isEditing)
                            .accessibilityHidden(!editMode.isEditing)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        bulkDeleteButton
                            .opacity(editMode.isEditing ? 1 : 0)
                            .allowsHitTesting(editMode.isEditing)
                            .accessibilityHidden(!editMode.isEditing)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                }
                .confirmationDialog(
                    "¿Borrar \(selectedEntryIDs.count) series?",
                    isPresented: $showBulkDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Borrar \(selectedEntryIDs.count) series", role: .destructive) {
                        deleteSelected()
                    }
                }
        }
        .environment(\.editMode, $editMode)
        .task(id: bridgeBaseURL) {
            await history.sync(with: bridgeBaseURL, force: true)
        }
        .onChange(of: history.entries) { updatedEntries in
            selectedEntryIDs.formIntersection(Set(updatedEntries.map(\.id)))
        }
        .onChange(of: editMode) { mode in
            if !mode.isEditing {
                selectedEntryIDs.removeAll()
            }
        }
    }

    private var historyList: some View {
        List(selection: $selectedEntryIDs) {
            if history.entries.isEmpty {
                Section {
                    ContentPlaceholder(icon: "play.circle", title: "Nada para continuar", detail: "Las series que reproduzcas aparecerán aquí con el segundo en que las dejaste.")
                }
            } else {
                Section("Reproducciones recientes") {
                    ForEach(history.entries) { entry in
                        NavigationLink {
                            episodeScreen(for: entry)
                        } label: {
                            HistoryRow(entry: entry)
                        }
                        .tag(entry.id)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                delete([entry])
                            } label: {
                                Label("Borrar", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await history.sync(with: bridgeBaseURL, force: true)
        }
    }

    private var allEntriesSelected: Bool {
        !history.entries.isEmpty && selectedEntryIDs.count == history.entries.count
    }

    private var selectAllButton: some View {
        Button {
            if allEntriesSelected {
                selectedEntryIDs.removeAll()
            } else {
                selectedEntryIDs = Set(history.entries.map(\.id))
            }
        } label: {
            Label(allEntriesSelected ? "Ninguno" : "Todos", systemImage: allEntriesSelected ? "xmark.circle" : "checkmark.circle")
        }
        .accessibilityLabel(allEntriesSelected ? "Deseleccionar todo" : "Seleccionar todo")
        .disabled(history.entries.isEmpty)
    }

    private var bulkDeleteButton: some View {
        Button(role: .destructive) {
            showBulkDeleteConfirmation = true
        } label: {
            Label("Borrar (\(selectedEntryIDs.count))", systemImage: "trash")
        }
        .disabled(selectedEntryIDs.isEmpty)
    }

    private func deleteSelected() {
        delete(history.entries.filter { selectedEntryIDs.contains($0.id) })
    }

    private func delete(_ entries: [WatchHistoryEntry]) {
        guard !entries.isEmpty else { return }
        history.remove(entries)
        selectedEntryIDs.subtract(Set(entries.map(\.id)))
        Task {
            await history.sync(with: bridgeBaseURL, force: true)
        }
    }

    private func episodeScreen(for entry: WatchHistoryEntry) -> EpisodesScreen {
        EpisodesScreen(
            bridgeBaseURL: bridgeBaseURL,
            anime: Anime(title: entry.seriesTitle, watchUrl: entry.watchUrl, imageUrl: entry.imageUrl, meta: "", rating: nil, score: nil, mediaType: nil, year: nil),
            resumeEpisode: entry.episode
        )
    }
}

private enum SettingsField: Hashable {
    case bridgeURL
}

struct SettingsScreen: View {
    @AppStorage("anksubbrd.bridge-base-url") private var bridgeBaseURL = "http://192.168.1.20:8787"
    @AppStorage("anksubbrd.verified-bridge-url") private var verifiedBridgeURL = ""
    @AppStorage("anksubbrd.bridge-token-version") private var bridgeTokenVersion = 0
    @AppStorage("anksubbrd.default-track-type") private var defaultTrackType = StreamKind.sub.rawValue
    @State private var testingBridge = false
    @State private var testResult: String?
    @State private var tokenConfigured = false
    @State private var showProvisioning = false
    @State private var showImport = false
    @State private var showBackup = false
    @State private var showChangeWarning = false
    @State private var tokenError: String?
    @FocusState private var focusedField: SettingsField?

    private var bridgeIsVerified: Bool {
        BridgeEndpoint.isVerified(verifiedBridgeURL, currentURL: bridgeBaseURL)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://IP-DEL-BRIDGE:8787", text: $bridgeBaseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .bridgeURL)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                    Button {
                        focusedField = nil
                        testBridge()
                    } label: {
                        if testingBridge {
                            HStack { ProgressView(); Text("Probando conexión…") }
                        } else {
                            Label("Probar conexión", systemImage: "network")
                        }
                    }
                    .disabled(testingBridge)

                    if let testResult {
                        Text(testResult)
                            .font(.footnote)
                            .foregroundStyle(testResult.hasPrefix("Conectado") ? .green : .red)
                    }
                } header: {
                    Text("Bridge local")
                } footer: {
                    Text("La dirección se guarda en este iPhone o iPad. Puede ser tu IP LAN o una dirección HTTPS pública detrás de Caddy.")
                }

                privateIdentitySection

                Section {
                    Picker("Mostrar servidores por defecto", selection: $defaultTrackType) {
                        ForEach(StreamKind.allCases) { kind in
                            Text(kind.displayName).tag(kind.rawValue)
                        }
                    }
                } header: {
                    Text("Audio y subtítulos")
                } footer: {
                    Text("Al abrir los servidores de un episodio podrás cambiar entre las pestañas Sub y Dub. Sub es la opción predeterminada.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Configuración")
            .modifier(AdaptableTabRootTitleStyle())
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Listo") { focusedField = nil }
                }
            }
        }
        .onAppear { refreshTokenState() }
        .onChange(of: bridgeBaseURL) { _ in
            testResult = nil
            tokenError = nil
            refreshTokenState()
        }
        .sheet(isPresented: $showChangeWarning) {
            IdentityChangeGuardSheet(
                onBackup: { presentAfterChangeWarning(.backup) },
                onChoose: { action in presentAfterChangeWarning(action) }
            )
        }
        .sheet(isPresented: $showProvisioning) {
            TokenProvisioningSheet(bridgeBaseURL: bridgeBaseURL) { token in
                try install(token: token)
            }
        }
        .sheet(isPresented: $showImport) {
            TokenImportSheet { token in
                try install(token: token)
            }
        }
        .sheet(isPresented: $showBackup) {
            TokenBackupSheet(token: SecureTokenStore.currentToken(for: bridgeBaseURL))
        }
    }

    @ViewBuilder
    private var privateIdentitySection: some View {
        Section {
            if !bridgeIsVerified {
                Label("Primero guarda y prueba esta URL del bridge", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Crear identidad privada…") { showProvisioning = true }
                    .disabled(true)
                Button("Restaurar desde Llavero de iCloud…") { restoreFromICloud() }
                    .disabled(true)
                Button("Importar token manualmente…") { showImport = true }
                    .disabled(true)
            } else if tokenConfigured {
                Label("Identidad privada configurada", systemImage: "lock.fill")
                    .foregroundStyle(.green)
                Button("Respaldar token…") { showBackup = true }
                Button("Cambiar identidad…", role: .destructive) { showChangeWarning = true }
            } else {
                Button("Crear identidad privada…") { showProvisioning = true }
                Button("Restaurar desde Llavero de iCloud…") { restoreFromICloud() }
                Button("Importar token manualmente…") { showImport = true }
            }
            if let tokenError { ErrorNotice(message: tokenError) }
        } header: {
            Text("Identidad privada")
        } footer: {
            Text("La URL debe probarse antes de crear, restaurar o importar. El token se sincroniza mediante Llavero de iCloud y sólo se consulta para esta URL. Comparte el mismo token sólo con los dispositivos que deban compartir lista.")
        }
    }

    private func install(token: String) throws {
        guard bridgeIsVerified else {
            throw BridgeRequestError(message: "Primero prueba la conexión del bridge para esta URL.")
        }
        try SecureTokenStore.save(token, for: bridgeBaseURL)
        tokenConfigured = true
        tokenError = nil
        bridgeTokenVersion += 1
    }

    private func refreshTokenState() {
        tokenConfigured = SecureTokenStore.currentToken(for: bridgeBaseURL).isEmpty == false
    }

    private func restoreFromICloud() {
        guard bridgeIsVerified else {
            tokenError = "Primero prueba la conexión del bridge para esta URL."
            return
        }
        do {
            try install(token: SecureTokenStore.restoreFromICloud(for: bridgeBaseURL))
            testResult = "Identidad restaurada desde el Llavero de iCloud."
        } catch {
            tokenError = error.localizedDescription
        }
    }

    private func presentAfterChangeWarning(_ action: IdentityChangeAction) {
        showChangeWarning = false
        DispatchQueue.main.async {
            switch action {
            case .backup:
                showBackup = true
            case .create:
                showProvisioning = true
            case .importExisting:
                showImport = true
            }
        }
    }

    private func testBridge() {
        Task { @MainActor in
            testingBridge = true
            testResult = nil
            defer { testingBridge = false }
            do {
                let health: HealthResponse = try await BridgeClient.get(base: bridgeBaseURL, path: "/health")
                guard health.ok, let canonicalURL = BridgeEndpoint.canonicalURL(bridgeBaseURL) else {
                    testResult = "El bridge respondió de forma inesperada."
                    return
                }
                bridgeBaseURL = canonicalURL
                verifiedBridgeURL = canonicalURL
                let migratedLegacyToken = try SecureTokenStore.migrateLegacyToken(to: canonicalURL)
                refreshTokenState()
                bridgeTokenVersion += 1
                testResult = migratedLegacyToken
                    ? "Conectado al bridge. Tu identidad anterior se movió al Llavero de iCloud para esta URL."
                    : "Conectado al bridge. Ya puedes crear, restaurar o importar una identidad."
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}

private enum IdentityChangeAction {
    case backup
    case create
    case importExisting
}

private struct IdentityChangeGuardSheet: View {
    let onBackup: () -> Void
    let onChoose: (IdentityChangeAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledgedCurrentToken = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Cambiar el token te convierte en otro usuario. El historial actual seguirá en el servidor, pero este iPhone o iPad no podrá abrirlo de nuevo sin el token actual.")
                    Toggle("Ya guardé el token actual de forma segura", isOn: $acknowledgedCurrentToken)
                    Button("Respaldar token actual…") {
                        onBackup()
                    }
                } header: {
                    Text("Antes de cambiar")
                } footer: {
                    Text("No continúes si no tienes el token guardado: no existe recuperación de cuenta ni un listado de otros usuarios.")
                }

                Section {
                    Button("Crear una identidad nueva", role: .destructive) {
                        onChoose(.create)
                    }
                    Button("Usar un token existente", role: .destructive) {
                        onChoose(.importExisting)
                    }
                } footer: {
                    Text("Estas acciones permanecen bloqueadas hasta que confirmes que resguardaste el token actual.")
                }
                .disabled(!acknowledgedCurrentToken)
            }
            .navigationTitle("Cambiar identidad")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}

struct TokenProvisioningSheet: View {
    let bridgeBaseURL: String
    let onSaved: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var administratorToken = ""
    @State private var label = ""
    @State private var generatedToken = ""
    @State private var confirmedBackup = false
    @State private var registering = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if generatedToken.isEmpty {
                    Section {
                        SecureField("Token administrador del bridge", text: $administratorToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Etiqueta opcional, por ejemplo iPad privado", text: $label)
                    } header: {
                        Text("Aprovisionamiento")
                    } footer: {
                        Text("El token administrador se usa una sola vez para registrar esta identidad; no se guarda en el dispositivo.")
                    }
                    Section {
                        Button("Generar token seguro") {
                            do { generatedToken = try TokenGenerator.make() } catch { errorMessage = error.localizedDescription }
                        }
                        .disabled(administratorToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } footer: {
                        Text("Este paso crea un secreto de 256 bits. No podrás recuperar el token si lo pierdes.")
                    }
                } else {
                    Section {
                        Text(generatedToken)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        ShareLink(item: generatedToken) {
                            Label("Copiar o compartir de forma segura", systemImage: "square.and.arrow.up")
                        }
                        Toggle("Ya guardé este token en un lugar seguro", isOn: $confirmedBackup)
                    } header: {
                        Text("Respalda este token antes de continuar")
                    } footer: {
                        Text("Será la única credencial para acceder a este historial. Puedes usarlo después en otro dispositivo para compartir la misma lista.")
                    }
                    Section {
                        Button {
                            registerAndSave()
                        } label: {
                            if registering {
                                HStack { ProgressView(); Text("Registrando…") }
                            } else {
                                Label("Registrar y usar este token", systemImage: "lock.badge.checkmark")
                            }
                        }
                        .disabled(!confirmedBackup || registering)
                    }
                }

                if let errorMessage {
                    Section { ErrorNotice(message: errorMessage) }
                }
            }
            .navigationTitle("Nueva identidad")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() }.disabled(registering) } }
        }
    }

    private func registerAndSave() {
        Task { @MainActor in
            registering = true
            errorMessage = nil
            defer { registering = false }
            do {
                let _: AdminUserResponse = try await BridgeClient.provisionUser(
                    base: bridgeBaseURL,
                    administratorToken: administratorToken,
                    body: AdminUserRequest(token: generatedToken, label: label)
                )
                try onSaved(generatedToken)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct TokenImportSheet: View {
    let onSaved: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var confirmedBackup = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Token de 64 caracteres", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Entiendo que esto reemplaza la identidad actual", isOn: $confirmedBackup)
                    Button("Guardar y cambiar identidad", role: .destructive) {
                        let candidate = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard candidate.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil else {
                            errorMessage = "El token debe contener 64 caracteres hexadecimales."; return
                        }
                        do {
                            try onSaved(candidate)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(!confirmedBackup || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Token existente")
                } footer: {
                    Text("Importa el token de otro dispositivo sólo si quieres acceder exactamente al mismo historial.")
                }
                if let errorMessage { Section { ErrorNotice(message: errorMessage) } }
            }
            .navigationTitle("Importar token")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
        }
    }
}

struct TokenBackupSheet: View {
    let token: String
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledgedRisk = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Advertencia") {
                    Text("Quien tenga este token puede acceder al historial asociado. No lo envíes por mensajes, correo ni capturas sin protección.")
                    Toggle("Entiendo el riesgo", isOn: $acknowledgedRisk)
                }
                if acknowledgedRisk {
                    Section("Token") {
                        Text(token)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        ShareLink(item: token) {
                            Label("Copiar o compartir de forma segura", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .navigationTitle("Respaldar token")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
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
    @State private var queuedAutoPlay: QueuedAutoPlay?
    @State private var loading = true
    @State private var loadingServers = false
    @State private var preparingPlayback = false
    @State private var activityDescription = ""
    @State private var errorMessage: String?

    init(bridgeBaseURL: String, anime: Anime, resumeEpisode: Int? = nil) {
        self.bridgeBaseURL = bridgeBaseURL
        self.anime = anime
        self.resumeEpisode = resumeEpisode
    }

    var body: some View {
        List {
            if loading {
                Section { ProgressView("Cargando episodios…") }
            }

            if loadingServers {
                Section { ProgressView(activityDescription.isEmpty ? "Cargando servidores…" : activityDescription) }
            }

            if let errorMessage {
                Section { ErrorNotice(message: errorMessage) }
            }

            if let series {
                if series.seasons.count > 1 {
                    Section("Temporadas") {
                        ForEach(series.seasons) { season in
                            if season.watchUrl == anime.watchUrl {
                                Label(season.displayName, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            } else {
                                NavigationLink {
                                    EpisodesScreen(
                                        bridgeBaseURL: bridgeBaseURL,
                                        anime: Anime(title: season.title, watchUrl: season.watchUrl, imageUrl: season.imageUrl, meta: season.meta, rating: season.rating, score: season.score, mediaType: season.mediaType, year: season.year)
                                    )
                                } label: {
                                    Text(season.displayName)
                                }
                            }
                        }
                    }
                }

                if let resumeEpisode, let episode = series.episodes.first(where: { $0.number == resumeEpisode }) {
                    Section("Continuar") {
                        Button {
                            loadServers(for: episode, seriesKey: series.seriesKey)
                        } label: {
                            Label("Continuar episodio \(episode.number) en \(formatTime(history.position(for: anime.watchUrl, episode: episode.number)))", systemImage: "play.fill")
                        }
                        .disabled(loadingServers || preparingPlayback)
                    }
                }

                Section("Episodios") {
                    ForEach(series.episodes) { episode in
                        Button {
                            loadServers(for: episode, seriesKey: series.seriesKey)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Episodio \(episode.number)")
                                    .foregroundStyle(.primary)
                                if !episode.title.isEmpty {
                                    Text(episode.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(loadingServers || preparingPlayback)
                    }
                }
            }
        }
        .navigationTitle(anime.title)
        .task(id: anime.watchUrl) { await loadSeries() }
        .sheet(item: $pendingServers) { selection in
            ServerPicker(selection: selection, isPreparing: preparingPlayback) { server in
                play(episode: selection.episode, server: server)
            }
        }
        .fullScreenCover(item: $playback, onDismiss: { startQueuedAutoPlay() }) { item in
            VideoScreen(playback: item.playback, historyEntry: item.historyEntry, bridgeBaseURL: bridgeBaseURL) {
                queueAutoPlay(after: item)
            }
                .environmentObject(history)
        }
        .overlay {
            if preparingPlayback {
                LoadingOverlay(message: activityDescription)
            }
        }
    }

    private func loadSeries() async {
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            series = try await BridgeClient.post(base: bridgeBaseURL, path: "/api/series", body: WatchRequest(watchUrl: anime.watchUrl))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadServers(for episode: Episode, seriesKey: String) {
        Task { @MainActor in
            loadingServers = true
            activityDescription = "Cargando servidores del episodio \(episode.number)…"
            errorMessage = nil
            defer { loadingServers = false }
            do {
                let reply: ServerResponse = try await BridgeClient.get(
                    base: bridgeBaseURL,
                    path: "/api/series/\(seriesKey)/servers",
                    query: [URLQueryItem(name: "episode", value: String(episode.number))]
                )
                pendingServers = EpisodeServers(episode: episode.number, seriesKey: seriesKey, servers: reply.servers)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func play(episode: Int, server: Server) {
        guard let series else { return }
        preparingPlayback = true
        activityDescription = "Preparando \(server.name)…"
        errorMessage = nil
        pendingServers = nil
        Task { @MainActor in
            defer { preparingPlayback = false }
            do {
                let resolved: Playback = try await BridgeClient.post(
                    base: bridgeBaseURL,
                    path: "/api/play",
                    body: PlayRequest(seriesKey: series.seriesKey, episode: episode, serverIndex: server.index)
                )
                let episodeTitle = series.episodes.first(where: { $0.number == episode })?.title ?? "Episodio \(episode)"
                playback = PlaybackSession(
                    playback: resolved,
                    historyEntry: WatchHistoryEntry(
                        seriesTitle: series.title,
                        watchUrl: anime.watchUrl,
                        imageUrl: anime.imageUrl,
                        episode: episode,
                        episodeTitle: episodeTitle,
                        serverName: resolved.serverName,
                        positionSeconds: history.position(for: anime.watchUrl, episode: episode),
                        updatedAt: Date()
                    )
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func queueAutoPlay(after finished: PlaybackSession) {
        guard let series,
              let currentIndex = series.episodes.firstIndex(where: { $0.number == finished.historyEntry.episode }),
              series.episodes.indices.contains(currentIndex + 1) else { return }
        queuedAutoPlay = QueuedAutoPlay(
            episode: series.episodes[currentIndex + 1],
            seriesKey: series.seriesKey,
            serverName: finished.playback.serverName,
            serverKind: finished.playback.serverKind
        )
        playback = nil
    }

    private func startQueuedAutoPlay() {
        guard let request = queuedAutoPlay, let series else { return }
        queuedAutoPlay = nil
        Task { @MainActor in
            preparingPlayback = true
            activityDescription = "Preparando episodio \(request.episode.number)…"
            errorMessage = nil
            defer { preparingPlayback = false }
            do {
                let preferredKind = request.serverKind ?? StreamKind.sub.rawValue
                let reply: ServerResponse = try await BridgeClient.get(
                    base: bridgeBaseURL,
                    path: "/api/series/\(request.seriesKey)/servers",
                    query: [URLQueryItem(name: "episode", value: String(request.episode.number))]
                )
                let server = reply.servers.first { $0.name == request.serverName && $0.type == preferredKind }
                    ?? reply.servers.first { $0.type == preferredKind }
                    ?? reply.servers.first
                guard let server else { throw BridgeRequestError(message: "El siguiente episodio no publicó servidores.") }
                let resolved: Playback = try await BridgeClient.post(
                    base: bridgeBaseURL,
                    path: "/api/play",
                    body: PlayRequest(seriesKey: series.seriesKey, episode: request.episode.number, serverIndex: server.index)
                )
                playback = PlaybackSession(
                    playback: resolved,
                    historyEntry: WatchHistoryEntry(
                        seriesTitle: series.title,
                        watchUrl: anime.watchUrl,
                        imageUrl: anime.imageUrl,
                        episode: request.episode.number,
                        episodeTitle: request.episode.title,
                        serverName: resolved.serverName,
                        positionSeconds: history.position(for: anime.watchUrl, episode: request.episode.number),
                        updatedAt: Date()
                    )
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct ServerPicker: View {
    let selection: EpisodeServers
    let isPreparing: Bool
    let onServer: (Server) -> Void
    @AppStorage("anksubbrd.default-track-type") private var defaultTrackType = StreamKind.sub.rawValue
    @State private var selectedTrack = StreamKind.sub.rawValue
    @Environment(\.dismiss) private var dismiss

    private var filteredServers: [Server] {
        selection.servers.filter { $0.kind.rawValue == selectedTrack }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Tipo", selection: $selectedTrack) {
                        ForEach(StreamKind.allCases) { kind in
                            Text(kind.displayName).tag(kind.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if filteredServers.isEmpty {
                    Section {
                        ContentPlaceholder(icon: "tray", title: "Sin servidores \(selectedTrack == StreamKind.dub.rawValue ? "Dub" : "Sub")", detail: "Este episodio no publicó una fuente para esta pestaña.")
                    }
                } else {
                    Section("Servidores \(selectedTrack == StreamKind.dub.rawValue ? "Dub" : "Sub")") {
                        ForEach(filteredServers) { server in
                            Button {
                                onServer(server)
                            } label: {
                                HStack {
                                    Text(server.name)
                                    Spacer()
                                    Image(systemName: "play.circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(isPreparing)
                        }
                    }
                }
            }
            .navigationTitle("Episodio \(selection.episode)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                        .disabled(isPreparing)
                }
            }
            .onAppear {
                selectedTrack = StreamKind(rawValue: defaultTrackType)?.rawValue ?? StreamKind.sub.rawValue
            }
        }
        .interactiveDismissDisabled(isPreparing)
    }
}

struct VideoScreen: View {
    let playback: Playback
    let historyEntry: WatchHistoryEntry
    let bridgeBaseURL: String
    let onFinished: () -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var history: WatchHistoryStore
    @State private var player: AVPlayer
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var didFinish = false

    init(playback: Playback, historyEntry: WatchHistoryEntry, bridgeBaseURL: String, onFinished: @escaping () -> Void) {
        self.playback = playback
        self.historyEntry = historyEntry
        self.bridgeBaseURL = bridgeBaseURL
        self.onFinished = onFinished
        _player = State(initialValue: AVPlayer(url: URL(string: playback.playbackUrl)!))
    }

    var body: some View {
        NavigationStack {
            NativePlayer(player: player)
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cerrar") {
                            savePosition()
                            player.pause()
                            dismiss()
                        }
                    }
                }
                .onAppear { beginPlayback() }
                .onDisappear {
                    savePosition()
                    removeObservers()
                }
        }
    }

    private func beginPlayback() {
        history.open(historyEntry)
        let resumeAt = history.position(for: historyEntry.watchUrl, episode: historyEntry.episode)
        configureAirPlayVideoSession()
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        if resumeAt > 3 {
            player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
        }
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { time in
                guard time.seconds.isFinite, time.seconds >= 0 else { return }
                Task { @MainActor in
                    history.update(historyEntry, positionSeconds: time.seconds)
                    await history.sync(with: bridgeBaseURL)
                }
            }
        }
        if endObserver == nil {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in
                guard !didFinish else { return }
                didFinish = true
                savePosition()
                onFinished()
            }
        }
        Task { @MainActor in await history.sync(with: bridgeBaseURL) }
        player.play()
    }

    private func savePosition() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite, seconds >= 0 {
            history.update(historyEntry, positionSeconds: seconds)
            Task { @MainActor in await history.sync(with: bridgeBaseURL, force: true) }
        }
    }

    private func removeObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }
}

struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.updatesNowPlayingInfoCenter = true
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
    }
}

struct AnimeRow: View {
    let anime: Anime

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterImage(imageURL: anime.imageUrl)
            VStack(alignment: .leading, spacing: 4) {
                Text(anime.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                AnimeMetadataTags(anime: anime)
            }
        }
        .padding(.vertical, 2)
    }
}

struct HistoryRow: View {
    let entry: WatchHistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterImage(imageURL: entry.imageUrl)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.seriesTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("Episodio \(entry.episode) · \(formatTime(entry.positionSeconds))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(entry.serverName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct AnimeCard: View {
    let anime: Anime

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterImage(imageURL: anime.imageUrl, width: 88, height: 124)
            VStack(alignment: .leading, spacing: 7) {
                Text(anime.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                AnimeMetadataTags(anime: anime)
                Spacer(minLength: 0)
                Label("Ver episodios", systemImage: "play.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
        .padding(14)
        .liquidGlassCard()
    }
}

struct AnimeMetadataTags: View {
    let anime: Anime

    private var tags: [String] {
        [anime.rating, anime.score.map { String(format: "%.2f", $0) }, anime.mediaType, anime.year.map(String.init)].compactMap { $0 }
    }

    var body: some View {
        if !tags.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { tagRow }
                VStack(alignment: .leading, spacing: 5) { tagRow }
            }
        }
    }

    @ViewBuilder
    private var tagRow: some View {
        ForEach(tags, id: \.self) { tag in
            Text(tag)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }
}

struct HistoryCard: View {
    let entry: WatchHistoryEntry

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            PosterImage(imageURL: entry.imageUrl, width: 88, height: 124)
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.seriesTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                Text("Episodio \(entry.episode)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Label(formatTime(entry.positionSeconds), systemImage: "clock")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Label("Continuar", systemImage: "play.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
        .padding(14)
        .liquidGlassCard()
    }
}

struct PosterImage: View {
    let imageURL: String?
    let width: CGFloat
    let height: CGFloat

    init(imageURL: String?, width: CGFloat = 56, height: CGFloat = 80) {
        self.imageURL = imageURL
        self.width = width
        self.height = height
    }

    var body: some View {
        Group {
            if let imageURL, let url = URL(string: imageURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        posterPlaceholder
                    default:
                        ZStack { posterPlaceholder; ProgressView() }
                    }
                }
            } else {
                posterPlaceholder
            }
        }
        .frame(width: width, height: height)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var posterPlaceholder: some View {
        Image(systemName: "film")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ContentPlaceholder: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

struct ErrorNotice: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.footnote)
    }
}

struct LoadingOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.24).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(message.isEmpty ? "Preparando reproducción…" : message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(32)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.isEmpty ? "Preparando reproducción" : message)
    }
}

struct LiquidGlassGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 18) {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func liquidGlassCard(cornerRadius: CGFloat = 22) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

enum StreamKind: String, CaseIterable, Identifiable {
    case sub
    case dub

    var id: String { rawValue }
    var displayName: String { rawValue == Self.dub.rawValue ? "Dub" : "Sub" }
}

extension Server {
    var kind: StreamKind { StreamKind(rawValue: type.lowercased()) ?? .sub }
}

private enum BridgeClient {
    static func get<T: Decodable>(base: String, path: String, query: [URLQueryItem] = [], timeoutInterval: TimeInterval = 30) async throws -> T {
        var components = try components(base: base, path: path)
        components.queryItems = query
        guard let url = components.url else { throw BridgeRequestError(message: "La dirección del bridge no es válida.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutInterval
        authorize(&request, bridgeBaseURL: base)
        return try await self.request(request)
    }

    static func post<T: Decodable, Body: Encodable>(base: String, path: String, body: Body) async throws -> T {
        let components = try components(base: base, path: path)
        guard let url = components.url else { throw BridgeRequestError(message: "La dirección del bridge no es válida.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = path == "/api/play" ? 90 : 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        authorize(&request, bridgeBaseURL: base)
        return try await self.request(request)
    }

    static func put<T: Decodable, Body: Encodable>(base: String, path: String, body: Body) async throws -> T {
        let components = try components(base: base, path: path)
        guard let url = components.url else { throw BridgeRequestError(message: "La dirección del bridge no es válida.") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        authorize(&request, bridgeBaseURL: base)
        return try await self.request(request)
    }

    static func provisionUser<T: Decodable, Body: Encodable>(base: String, administratorToken: String, body: Body) async throws -> T {
        let components = try components(base: base, path: "/api/admin/users")
        guard let url = components.url else { throw BridgeRequestError(message: "La dirección del bridge no es válida.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(administratorToken.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Bridge-Admin-Token")
        request.httpBody = try JSONEncoder().encode(body)
        return try await self.request(request)
    }

    private static func components(base: String, path: String) throws -> URLComponents {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedBase),
              components.scheme == "http" || components.scheme == "https",
              components.host != nil else {
            throw BridgeRequestError(message: "Escribe una dirección válida, por ejemplo http://192.168.1.20:8787.")
        }
        components.path = path
        return components
    }

    private static func authorize(_ request: inout URLRequest, bridgeBaseURL: String) {
        let token = SecureTokenStore.currentToken(for: bridgeBaseURL)
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Bridge-Token")
        }
    }

    private static func request<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BridgeRequestError(message: "El bridge no respondió correctamente.")
        }
        guard (200...299).contains(http.statusCode) else {
            let providerMessage = try? JSONDecoder().decode(BridgeErrorResponse.self, from: data).error
            throw BridgeRequestError(message: providerMessage ?? "El bridge respondió HTTP \(http.statusCode).")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BridgeRequestError(message: "El bridge devolvió una respuesta que la app no pudo leer.")
        }
    }
}

struct BridgeRequestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct BridgeErrorResponse: Decodable { let error: String? }
struct HealthResponse: Decodable { let ok: Bool }
struct SearchResponse: Decodable { let results: [Anime] }
struct Anime: Codable, Hashable, Identifiable {
    let title: String
    let watchUrl: String
    let imageUrl: String?
    let meta: String
    let rating: String?
    let score: Double?
    let mediaType: String?
    let year: Int?
    var id: String { watchUrl }
}
struct WatchRequest: Encodable { let watchUrl: String }
struct Series: Decodable { let seriesKey: String; let title: String; let episodes: [Episode]; let seasons: [Season] }
struct Season: Decodable, Identifiable {
    let title: String
    let watchUrl: String
    let imageUrl: String?
    let meta: String
    let rating: String?
    let score: Double?
    let mediaType: String?
    let year: Int?
    let seasonNumber: Int
    var id: String { watchUrl }
    var displayName: String { "Temporada \(seasonNumber)" }
}
struct Episode: Decodable, Identifiable { let number: Int; let title: String; var id: Int { number } }
struct ServerResponse: Decodable { let episode: Int; let servers: [Server] }
struct Server: Decodable, Identifiable { let index: Int; let name: String; let type: String; var id: Int { index } }
struct EpisodeServers: Identifiable { let episode: Int; let seriesKey: String; let servers: [Server]; var id: Int { episode } }
struct PlayRequest: Encodable { let seriesKey: String; let episode: Int; let serverIndex: Int }
struct Playback: Decodable, Identifiable { let playbackUrl: String; let subtitleTracks: Int; let serverName: String; let serverKind: String?; var id: String { playbackUrl } }
struct PlaybackSession: Identifiable { let playback: Playback; let historyEntry: WatchHistoryEntry; var id: String { playback.id } }
struct QueuedAutoPlay { let episode: Episode; let seriesKey: String; let serverName: String; let serverKind: String? }
struct HistoryResponse: Decodable {
    let entries: [WatchHistoryEntry]
    let deletions: [HistoryDeletion]?
}
struct HistoryPayload: Encodable {
    let entries: [WatchHistoryEntry]
    let deletions: [HistoryDeletion]
}
struct AdminUserRequest: Encodable { let token: String; let label: String }
struct AdminUserResponse: Decodable { let userId: String; let createdAt: String }

struct WatchHistoryEntry: Codable, Hashable, Identifiable {
    let seriesTitle: String
    let watchUrl: String
    let imageUrl: String?
    let episode: Int
    let episodeTitle: String
    let serverName: String
    var positionSeconds: Double
    var updatedAt: Date
    var id: String { "\(watchUrl)#\(episode)" }
}

struct HistoryDeletion: Codable, Hashable, Identifiable {
    let watchUrl: String
    let updatedAt: Date
    var id: String { watchUrl }
}

private struct HistorySnapshot {
    let entries: [WatchHistoryEntry]
    let deletions: [HistoryDeletion]
}

@MainActor
private final class WatchHistoryStore: ObservableObject {
    @Published private(set) var entries: [WatchHistoryEntry]
    private let legacyKey = "anksubbrd.watch-history.v1"
    private let profileMigrationKey = "anksubbrd.watch-history.v2.default"
    private let defaults: UserDefaults
    private var activeIdentity: String
    private var deletions: [HistoryDeletion]
    private var lastSync = Date.distantPast
    private var syncing = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        activeIdentity = "local"
        entries = []
        deletions = []
        entries = loadEntries(for: activeIdentity)
        deletions = loadDeletions(for: activeIdentity)
        replace(with: resolvedHistory(entries: entries, deletions: deletions))
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

    func activate(token: String, bridgeBaseURL: String) {
        let identity = HistoryIdentity.storageID(for: token, bridgeBaseURL: bridgeBaseURL)
        guard activeIdentity != identity else { return }
        let localEntriesBeforeActivation = activeIdentity == "local" ? entries : []
        persist()
        activeIdentity = identity
        let scopedEntries = loadEntries(for: activeIdentity)
        let scopedDeletions = loadDeletions(for: activeIdentity)
        if scopedEntries.isEmpty && scopedDeletions.isEmpty {
            let legacyEntries = loadEntries(for: HistoryIdentity.legacyStorageID(for: token))
            entries = legacyEntries.isEmpty ? localEntriesBeforeActivation : legacyEntries
            deletions = []
            if !entries.isEmpty { persist() }
        } else {
            entries = scopedEntries
            deletions = scopedDeletions
        }
        replace(with: resolvedHistory(entries: entries, deletions: deletions))
        lastSync = .distantPast
    }

    func sync(with bridgeBaseURL: String, force: Bool = false) async {
        guard !syncing, force || Date().timeIntervalSince(lastSync) >= 12 else { return }
        syncing = true
        defer { syncing = false; lastSync = Date() }
        do {
            let remote: HistoryResponse = try await BridgeClient.get(base: bridgeBaseURL, path: "/api/history")
            replace(with: merged(localEntries: entries, localDeletions: deletions, remoteEntries: remote.entries, remoteDeletions: remote.deletions ?? []))
            let saved: HistoryResponse = try await BridgeClient.put(base: bridgeBaseURL, path: "/api/history", body: HistoryPayload(entries: entries, deletions: deletions))
            replace(with: merged(localEntries: entries, localDeletions: deletions, remoteEntries: saved.entries, remoteDeletions: saved.deletions ?? []))
        } catch {
            // The local history remains usable while the private bridge is
            // offline or the user has not enabled server-side sync yet.
        }
    }

    private func upsert(_ entry: WatchHistoryEntry) {
        var copy = entry
        copy.updatedAt = Date()
        replace(with: resolvedHistory(
            entries: entries.filter { $0.watchUrl != copy.watchUrl } + [copy],
            deletions: deletions.filter { $0.watchUrl != copy.watchUrl }
        ))
    }

    func remove(_ entriesToRemove: [WatchHistoryEntry]) {
        let watchURLs = Set(entriesToRemove.map(\.watchUrl))
        guard !watchURLs.isEmpty else { return }
        let now = Date()
        replace(with: resolvedHistory(
            entries: entries.filter { !watchURLs.contains($0.watchUrl) },
            deletions: deletions.filter { !watchURLs.contains($0.watchUrl) } + watchURLs.map { HistoryDeletion(watchUrl: $0, updatedAt: now) }
        ))
    }

    private func merged(localEntries: [WatchHistoryEntry], localDeletions: [HistoryDeletion], remoteEntries: [WatchHistoryEntry], remoteDeletions: [HistoryDeletion]) -> HistorySnapshot {
        resolvedHistory(entries: localEntries + remoteEntries, deletions: localDeletions + remoteDeletions)
    }

    private func resolvedHistory(entries: [WatchHistoryEntry], deletions: [HistoryDeletion]) -> HistorySnapshot {
        var latestEntries: [String: WatchHistoryEntry] = [:]
        var latestDeletions: [String: HistoryDeletion] = [:]
        for entry in entries {
            if let existing = latestEntries[entry.watchUrl], existing.updatedAt > entry.updatedAt { continue }
            latestEntries[entry.watchUrl] = entry
        }
        for deletion in deletions {
            if let existing = latestDeletions[deletion.watchUrl], existing.updatedAt > deletion.updatedAt { continue }
            latestDeletions[deletion.watchUrl] = deletion
        }
        for (watchURL, deletion) in latestDeletions {
            if let entry = latestEntries[watchURL], entry.updatedAt > deletion.updatedAt {
                latestDeletions.removeValue(forKey: watchURL)
            } else {
                latestEntries.removeValue(forKey: watchURL)
            }
        }
        return HistorySnapshot(
            entries: Array(latestEntries.values).sorted { $0.updatedAt > $1.updatedAt }.prefix(50).map { $0 },
            deletions: Array(latestDeletions.values).sorted { $0.updatedAt > $1.updatedAt }.prefix(500).map { $0 }
        )
    }

    private func replace(with snapshot: HistorySnapshot) {
        entries = snapshot.entries
        deletions = snapshot.deletions
        persist()
    }

    private func storageKey(for identity: String) -> String {
        "anksubbrd.watch-history.v3.\(identity)"
    }

    private func deletionStorageKey(for identity: String) -> String {
        "anksubbrd.watch-history.v4.deletions.\(identity)"
    }

    private func loadEntries(for identity: String) -> [WatchHistoryEntry] {
        let data = defaults.data(forKey: storageKey(for: identity))
            ?? (identity == "local" ? defaults.data(forKey: profileMigrationKey) ?? defaults.data(forKey: legacyKey) : nil)
            ?? Data()
        return ((try? JSONDecoder().decode([WatchHistoryEntry].self, from: data)) ?? [])
    }

    private func loadDeletions(for identity: String) -> [HistoryDeletion] {
        let data = defaults.data(forKey: deletionStorageKey(for: identity)) ?? Data()
        return (try? JSONDecoder().decode([HistoryDeletion].self, from: data)) ?? []
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: storageKey(for: activeIdentity))
        }
        if let data = try? JSONEncoder().encode(deletions) {
            defaults.set(data, forKey: deletionStorageKey(for: activeIdentity))
        }
    }
}

private func formatTime(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", value / 60, value % 60)
}
