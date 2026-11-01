import AVKit
import AVFAudio
import CoreMedia
import CryptoKit
import Foundation
import Security
import SwiftUI

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
    static func storageID(for token: String) -> String {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "local" }
        return SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

private enum SecureTokenStore {
    private static let service = "com.personal.airplaysubtitleplayer"
    private static let account = "bridge-access-token"
    private static let legacyDefaultsKey = "anksubbrd.bridge-access-token"

    static func currentToken() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let token = String(data: data, encoding: .utf8), !token.isEmpty {
            return token
        }
        let legacyToken = UserDefaults.standard.string(forKey: legacyDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !legacyToken.isEmpty {
            do {
                try save(legacyToken)
                UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
                return legacyToken
            } catch {
                return ""
            }
        }
        return ""
    }

    static func save(_ token: String) throws {
        let data = Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !data.isEmpty else { throw BridgeRequestError(message: "El token no puede estar vacío.") }
        let attributes: [String: Any] = [kSecValueData as String: data]
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw BridgeRequestError(message: "No se pudo guardar el token en el Llavero.") }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw BridgeRequestError(message: "No se pudo guardar el token en el Llavero.")
        }
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
        .tint(.indigo)
        .task(id: "\(bridgeBaseURL)|\(bridgeTokenVersion)") {
            history.activate(token: SecureTokenStore.currentToken())
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        NavigationStack {
            Group {
                if horizontalSizeClass == .regular {
                    tabletContent
                } else {
                    phoneContent
                }
            }
            .navigationTitle("Continuar viendo")
        }
        .task(id: bridgeBaseURL) {
            await history.sync(with: bridgeBaseURL, force: true)
        }
    }

    private var phoneContent: some View {
        List {
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
                    }
                }
            }
        }
    }

    private var tabletContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if history.entries.isEmpty {
                    ContentPlaceholder(icon: "play.circle", title: "Nada para continuar", detail: "Las series que reproduzcas aparecerán aquí con el segundo en que las dejaste.")
                        .liquidGlassCard()
                } else {
                    Text("Reproducciones recientes")
                        .font(.title2.bold())
                    LiquidGlassGroup {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 18)], spacing: 18) {
                            ForEach(history.entries) { entry in
                                NavigationLink {
                                    episodeScreen(for: entry)
                                } label: {
                                    HistoryCard(entry: entry)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1120, alignment: .leading)
            .padding(24)
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

struct SettingsScreen: View {
    @AppStorage("anksubbrd.bridge-base-url") private var bridgeBaseURL = "http://192.168.1.20:8787"
    @AppStorage("anksubbrd.bridge-token-version") private var bridgeTokenVersion = 0
    @AppStorage("anksubbrd.default-track-type") private var defaultTrackType = StreamKind.sub.rawValue
    @State private var testingBridge = false
    @State private var testResult: String?
    @State private var tokenConfigured = !SecureTokenStore.currentToken().isEmpty
    @State private var showProvisioning = false
    @State private var showImport = false
    @State private var showBackup = false
    @State private var showChangeWarning = false
    @State private var tokenError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://IP-DEL-BRIDGE:8787", text: $bridgeBaseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    Button {
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
            .navigationTitle("Configuración")
        }
        .onAppear { tokenConfigured = !SecureTokenStore.currentToken().isEmpty }
        .confirmationDialog("¿Cambiar identidad privada?", isPresented: $showChangeWarning, titleVisibility: .visible) {
            Button("Crear una identidad nueva", role: .destructive) { showProvisioning = true }
            Button("Usar un token existente", role: .destructive) { showImport = true }
        } message: {
            Text("Cambiar el token cambia de usuario. Tu historial actual no se borra del servidor, pero dejará de ser visible en este dispositivo hasta que restaures el token anterior. Respalda el token antes de continuar.")
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
            TokenBackupSheet(token: SecureTokenStore.currentToken())
        }
    }

    @ViewBuilder
    private var privateIdentitySection: some View {
        Section {
            if tokenConfigured {
                Label("Identidad privada configurada", systemImage: "lock.fill")
                    .foregroundStyle(.green)
                Button("Respaldar token…") { showBackup = true }
                Button("Cambiar identidad…", role: .destructive) { showChangeWarning = true }
            } else {
                Button("Crear identidad privada…") { showProvisioning = true }
                Button("Usar un token existente…") { showImport = true }
            }
            if let tokenError { ErrorNotice(message: tokenError) }
        } header: {
            Text("Identidad privada")
        } footer: {
            Text("El token vive en el Llavero de este dispositivo y determina qué historial puede leer. Comparte el mismo token sólo con los dispositivos que deban compartir lista.")
        }
    }

    private func install(token: String) throws {
        try SecureTokenStore.save(token)
        tokenConfigured = true
        tokenError = nil
        bridgeTokenVersion += 1
    }

    private func testBridge() {
        Task { @MainActor in
            testingBridge = true
            testResult = nil
            defer { testingBridge = false }
            do {
                let health: HealthResponse = try await BridgeClient.get(base: bridgeBaseURL, path: "/health")
                testResult = health.ok ? "Conectado al bridge." : "El bridge respondió de forma inesperada."
            } catch {
                testResult = error.localizedDescription
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
                    Section("Aprovisionamiento") {
                        SecureField("Token administrador del bridge", text: $administratorToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Etiqueta opcional, por ejemplo iPad privado", text: $label)
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
                    Section("Respalda este token antes de continuar") {
                        Text(generatedToken)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        ShareLink(item: generatedToken) {
                            Label("Copiar o compartir de forma segura", systemImage: "square.and.arrow.up")
                        }
                        Toggle("Ya guardé este token en un lugar seguro", isOn: $confirmedBackup)
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
                Section("Token existente") {
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
        authorize(&request)
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
        authorize(&request)
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
        authorize(&request)
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

    private static func authorize(_ request: inout URLRequest) {
        let token = SecureTokenStore.currentToken()
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
struct HistoryResponse: Decodable { let entries: [WatchHistoryEntry] }
struct HistoryPayload: Encodable { let entries: [WatchHistoryEntry] }
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

@MainActor
private final class WatchHistoryStore: ObservableObject {
    @Published private(set) var entries: [WatchHistoryEntry]
    private let legacyKey = "anksubbrd.watch-history.v1"
    private let profileMigrationKey = "anksubbrd.watch-history.v2.default"
    private let defaults: UserDefaults
    private var activeIdentity: String
    private var lastSync = Date.distantPast
    private var syncing = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        activeIdentity = HistoryIdentity.storageID(for: SecureTokenStore.currentToken())
        entries = []
        entries = loadEntries(for: activeIdentity)
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

    func activate(token: String) {
        let identity = HistoryIdentity.storageID(for: token)
        guard activeIdentity != identity else { return }
        persist()
        activeIdentity = identity
        entries = loadEntries(for: activeIdentity)
        lastSync = .distantPast
    }

    func sync(with bridgeBaseURL: String, force: Bool = false) async {
        guard !syncing, force || Date().timeIntervalSince(lastSync) >= 12 else { return }
        syncing = true
        defer { syncing = false; lastSync = Date() }
        do {
            let remote: HistoryResponse = try await BridgeClient.get(base: bridgeBaseURL, path: "/api/history")
            replace(with: merged(local: entries, remote: remote.entries))
            let saved: HistoryResponse = try await BridgeClient.put(base: bridgeBaseURL, path: "/api/history", body: HistoryPayload(entries: entries))
            replace(with: merged(local: entries, remote: saved.entries))
        } catch {
            // The local history remains usable while the private bridge is
            // offline or the user has not enabled server-side sync yet.
        }
    }

    private func upsert(_ entry: WatchHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        var copy = entry
        copy.updatedAt = Date()
        entries.insert(copy, at: 0)
        entries = Array(entries.prefix(50))
        persist()
    }

    private func merged(local: [WatchHistoryEntry], remote: [WatchHistoryEntry]) -> [WatchHistoryEntry] {
        var latest: [String: WatchHistoryEntry] = [:]
        for entry in local + remote {
            if let existing = latest[entry.id], existing.updatedAt > entry.updatedAt { continue }
            latest[entry.id] = entry
        }
        return Array(latest.values).sorted { $0.updatedAt > $1.updatedAt }.prefix(50).map { $0 }
    }

    private func replace(with updatedEntries: [WatchHistoryEntry]) {
        entries = updatedEntries
        persist()
    }

    private func storageKey(for identity: String) -> String {
        "anksubbrd.watch-history.v3.\(identity)"
    }

    private func loadEntries(for identity: String) -> [WatchHistoryEntry] {
        let data = defaults.data(forKey: storageKey(for: identity))
            ?? (identity == "local" ? defaults.data(forKey: profileMigrationKey) ?? defaults.data(forKey: legacyKey) : nil)
            ?? Data()
        return ((try? JSONDecoder().decode([WatchHistoryEntry].self, from: data)) ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: storageKey(for: activeIdentity))
        }
    }
}

private func formatTime(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", value / 60, value % 60)
}
