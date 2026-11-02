import SwiftUI

struct SettingsScreen: View {
    private enum TestResult {
        case success(String)
        case warning(String)
        case failure(String)
    }

    @Environment(ProfileStore.self) private var profile
    @Environment(AppUpdateCenter.self) private var updates
    @State private var scheme: BridgeScheme = .https
    @State private var host = ""
    @State private var testing = false
    @State private var testResult: TestResult?
    @State private var preferences = UserPreferences()
    @State private var showProvisioning = false
    @State private var showImport = false
    @State private var showBackup = false
    @State private var showChangeWarning = false
    @State private var tokenError: String?
    @FocusState private var hostFocused: Bool

    private var candidateURL: String? { BridgeEndpoint.make(scheme: scheme, host: host) }
    private var candidateIsActive: Bool { profile.isBridgeConfigured && candidateURL == profile.bridgeURL }

    var body: some View {
        NavigationStack {
            Form {
                bridgeSection
                identitySection
                catalogSection
                playbackSection
                aboutSection
            }
            .navigationTitle("Configuración")
            .modifier(AdaptableTabRootTitleStyle())
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear(perform: loadFields)
        .onChange(of: host) { _, value in
            // Only the host is typed here; a pasted scheme moves to the picker.
            let stripped = BridgeEndpoint.strippingScheme(value)
            if let pastedScheme = stripped.scheme {
                scheme = pastedScheme
                host = stripped.host
            }
        }
        .onChange(of: profile.preferences) { _, value in preferences = value }
        .onChange(of: preferences) { _, value in profile.setPreferences(value) }
        .sheet(isPresented: $showChangeWarning) {
            IdentityChangeGuardSheet { action in presentAfterChangeWarning(action) }
        }
        .sheet(isPresented: $showProvisioning) {
            TokenProvisioningSheet(bridgeBaseURL: profile.bridgeURL) { token in try install(token: token) }
        }
        .sheet(isPresented: $showImport) {
            TokenImportSheet { token in try install(token: token) }
        }
        .sheet(isPresented: $showBackup) {
            TokenBackupSheet(token: SecureTokenStore.currentToken(for: profile.bridgeURL))
        }
    }

    // MARK: Bridge

    private var bridgeSection: some View {
        Section {
            if profile.isBridgeConfigured {
                LabeledContent {
                    Text(profile.bridgeURL)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    Label("Activo", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            HStack(spacing: 4) {
                Picker("Protocolo", selection: $scheme) {
                    ForEach(BridgeScheme.allCases) { Text("\($0.rawValue)://").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                TextField("bridge.midominio.com", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .focused($hostFocused)
                    .submitLabel(.go)
                    .onSubmit(testBridge)
            }
            Button(action: testBridge) {
                if testing {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Probando conexión…")
                    }
                } else {
                    Label(candidateIsActive ? "Probar conexión" : "Probar y guardar", systemImage: "network")
                }
            }
            .disabled(testing || candidateURL == nil)
            if let testResult {
                resultView(testResult)
            }
        } header: {
            Text("Bridge")
        } footer: {
            Text("Escribe sólo el dominio o la IP, con el puerto si hace falta (por ejemplo bridge.midominio.com o 192.168.1.20:8787). HTTP sólo funciona dentro de tu red local. La dirección se guarda cuando la prueba responde.")
        }
    }

    @ViewBuilder
    private func resultView(_ result: TestResult) -> some View {
        switch result {
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
        case .warning(let message):
            Label(message, systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange).font(.footnote)
        case .failure(let message):
            ErrorNotice(message: message)
        }
    }

    private func loadFields() {
        preferences = profile.preferences
        guard host.isEmpty else { return }
        let source: String? = profile.isBridgeConfigured
            ? profile.bridgeURL
            : profile.savedBridgeAddress.flatMap(BridgeEndpoint.canonicalURL)
        if let source {
            let fields = BridgeEndpoint.fields(from: source)
            scheme = fields.scheme
            host = fields.host
        }
    }

    private func testBridge() {
        guard let candidate = candidateURL, !testing else { return }
        hostFocused = false
        Task {
            testing = true
            testResult = nil
            defer { testing = false }
            do {
                let health: HealthResponse = try await BridgeClient.get(base: candidate, path: "/health", timeoutInterval: 10)
                guard health.ok else {
                    testResult = .failure("El bridge respondió de forma inesperada.")
                    return
                }
                let migrated = try SecureTokenStore.migrateLegacyToken(to: candidate)
                let madeSynchronizable = try SecureTokenStore.makeCurrentTokenSynchronizable(for: candidate)
                profile.useBridge(candidate)
                let fields = BridgeEndpoint.fields(from: profile.bridgeURL)
                scheme = fields.scheme
                host = fields.host
                let connected = health.summary.map { "Conectado (\($0))." } ?? "Conectado."
                if !profile.hasToken, await BridgeClient.requiresIdentity(base: candidate) {
                    testResult = .warning("\(connected) Este bridge requiere una identidad privada: créala, restáurala o impórtala abajo.")
                } else if migrated || madeSynchronizable {
                    testResult = .success("\(connected) La identidad se guardó como sincronizable en el Llavero de iCloud.")
                } else {
                    testResult = .success("\(connected) Buscar, Recientes y Continuar ya están disponibles.")
                }
                await profile.sync(force: true)
            } catch is CancellationError {
                return
            } catch {
                testResult = .failure(error.localizedDescription)
            }
        }
    }

    // MARK: Identity

    private var identitySection: some View {
        Section {
            if !profile.isBridgeConfigured {
                Label("Primero prueba y guarda la dirección del bridge", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if profile.hasToken {
                Label("Identidad privada configurada", systemImage: "lock.fill")
                    .foregroundStyle(.green)
                Button("Respaldar token…") { showBackup = true }
                Button("Cambiar identidad…", role: .destructive) { showChangeWarning = true }
            } else {
                Button("Crear identidad privada…") { showProvisioning = true }
                Button("Restaurar desde Llavero de iCloud…", action: restoreFromICloud)
                Button("Importar token manualmente…") { showImport = true }
            }
            if let tokenError {
                ErrorNotice(message: tokenError)
            }
        } header: {
            Text("Identidad privada")
        } footer: {
            Text("El token define tu historial y tus preferencias. Se sincroniza mediante el Llavero de iCloud sólo para esta URL; compártelo únicamente con los dispositivos que deban compartir lista y ajustes.")
        }
    }

    private func install(token: String) throws {
        guard profile.isBridgeConfigured else {
            throw BridgeRequestError(message: "Primero prueba la conexión del bridge.")
        }
        try SecureTokenStore.save(token, for: profile.bridgeURL)
        tokenError = nil
        profile.reloadIdentity()
        Task { await profile.sync(force: true) }
    }

    private func restoreFromICloud() {
        do {
            try install(token: SecureTokenStore.restoreFromICloud(for: profile.bridgeURL))
            testResult = .success("Identidad restaurada desde el Llavero de iCloud.")
        } catch {
            tokenError = error.localizedDescription
        }
    }

    private func presentAfterChangeWarning(_ action: IdentityChangeAction) {
        showChangeWarning = false
        Task {
            // Let the warning sheet finish dismissing before presenting the next one.
            try? await Task.sleep(for: .milliseconds(350))
            switch action {
            case .backup: showBackup = true
            case .create: showProvisioning = true
            case .importExisting: showImport = true
            }
        }
    }

    // MARK: Preferences

    private var catalogSection: some View {
        Section {
            Picker("Idioma de los títulos", selection: $preferences.titleLanguage) {
                ForEach(TitleLanguage.allCases) { Text($0.displayName).tag($0) }
            }
        } header: {
            Text("Catálogo")
        } footer: {
            Text("En japonés, Continuar viendo mantiene el nombre en inglés y muestra debajo el título japonés.")
        }
        .disabled(!profile.isBridgeConfigured)
    }

    private var playbackSection: some View {
        Section {
            Picker("Servidores por defecto", selection: $preferences.defaultTrack) {
                ForEach(StreamKind.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Subtítulos en Sub", selection: $preferences.subtitleLanguage) {
                ForEach(subtitleOptions, id: \.tag) { option in
                    Text(option.label).tag(option.tag)
                }
            }
            Toggle("Reproducir el siguiente episodio", isOn: $preferences.autoNext)
            Toggle("Saltar intro automáticamente", isOn: $preferences.autoSkipIntro)
            Toggle("Saltar outro automáticamente", isOn: $preferences.autoSkipOutro)
        } header: {
            Text("Reproducción")
        } footer: {
            Text("Sub declara audio japonés y activa los subtítulos; Dub declara audio en inglés. Estas preferencias pertenecen a la identidad activa y se sincronizan con el bridge en tus otros dispositivos.")
        }
        .disabled(!profile.isBridgeConfigured)
    }

    private var subtitleOptions: [(tag: String, label: String)] {
        var options: [(tag: String, label: String)] = [("", "Automático (idioma del dispositivo)")]
        options += ["en", "es", "pt", "fr", "de", "it"].map { ($0, languageName($0)) }
        options.append((UserPreferences.subtitlesOff, "Desactivados"))
        let current = preferences.subtitleLanguage
        if !options.contains(where: { $0.tag == current }) {
            options.insert((current, languageName(current)), at: 1)
        }
        return options
    }

    private func languageName(_ tag: String) -> String {
        let spanish = Locale(identifier: "es")
        return spanish.localizedString(forIdentifier: tag)?.capitalized(with: spanish) ?? tag
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("Versión instalada", value: AppUpdateCenter.installedVersion)
            Button {
                Task { await updates.check(userInitiated: true) }
            } label: {
                if updates.isChecking {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Buscando actualizaciones…")
                    }
                } else {
                    Label("Buscar actualizaciones", systemImage: "arrow.down.circle")
                }
            }
            .disabled(updates.isChecking)
            if let status = updates.statusMessage {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Link(destination: AppUpdateCenter.releasesPage) {
                Label("Releases en GitHub", systemImage: "safari")
            }
        } header: {
            Text("Acerca de")
        }
    }
}

enum IdentityChangeAction {
    case backup
    case create
    case importExisting
}

private struct IdentityChangeGuardSheet: View {
    let onChoose: (IdentityChangeAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledgedCurrentToken = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Cambiar el token te convierte en otro usuario. El historial y las preferencias actuales seguirán en el servidor, pero este iPhone o iPad no podrá abrirlos de nuevo sin el token actual.")
                    Toggle("Ya guardé el token actual de forma segura", isOn: $acknowledgedCurrentToken)
                    Button("Respaldar token actual…") { onChoose(.backup) }
                } header: {
                    Text("Antes de cambiar")
                } footer: {
                    Text("No continúes si no tienes el token guardado: no existe recuperación de cuenta ni un listado de otros usuarios.")
                }

                Section {
                    Button("Crear una identidad nueva", role: .destructive) { onChoose(.create) }
                    Button("Usar un token existente", role: .destructive) { onChoose(.importExisting) }
                } footer: {
                    Text("Estas acciones permanecen bloqueadas hasta que confirmes que resguardaste el token actual.")
                }
                .disabled(!acknowledgedCurrentToken)
            }
            .navigationTitle("Cambiar identidad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", role: .cancel) { dismiss() }
                }
            }
        }
    }
}

private struct TokenProvisioningSheet: View {
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
                        Text("Será la única credencial para acceder a este historial y sus preferencias. Puedes usarlo después en otro dispositivo para compartirlos.")
                    }
                    Section {
                        Button(action: registerAndSave) {
                            if registering {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Registrando…")
                                }
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", role: .cancel) { dismiss() }
                        .disabled(registering)
                }
            }
        }
        .interactiveDismissDisabled(registering)
    }

    private func registerAndSave() {
        Task {
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

private struct TokenImportSheet: View {
    let onSaved: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var confirmedReplacement = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Token de 64 caracteres", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Entiendo que esto reemplaza la identidad actual", isOn: $confirmedReplacement)
                    Button("Guardar y cambiar identidad", role: .destructive, action: save)
                        .disabled(!confirmedReplacement || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Token existente")
                } footer: {
                    Text("Importa el token de otro dispositivo sólo si quieres acceder exactamente al mismo historial y a las mismas preferencias.")
                }
                if let errorMessage {
                    Section { ErrorNotice(message: errorMessage) }
                }
            }
            .navigationTitle("Importar token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar", role: .cancel) { dismiss() }
                }
            }
        }
    }

    private func save() {
        let candidate = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil else {
            errorMessage = "El token debe contener 64 caracteres hexadecimales."
            return
        }
        do {
            try onSaved(candidate)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TokenBackupSheet: View {
    let token: String
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledgedRisk = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Advertencia") {
                    Text("Quien tenga este token puede acceder al historial y las preferencias asociados. No lo envíes por mensajes, correo ni capturas sin protección.")
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }
}
