import Foundation
import Observation
import SwiftUI

struct GitHubRelease: Decodable, Identifiable {
    struct Asset: Decodable {
        let name: String
        let state: String
        let browserDownloadUrl: URL?
    }

    let tagName: String
    let body: String?
    let htmlUrl: URL
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date?
    let assets: [Asset]
    var id: String { tagName }

    var version: [Int]? { AppUpdateCenter.parse(tagName) }
    var hasIPA: Bool { assets.contains { $0.name == AppUpdateCenter.ipaName && $0.state == "uploaded" } }
}

struct AvailableUpdate: Identifiable {
    /// Every newer release that ships an IPA, newest first.
    let releases: [GitHubRelease]
    var latest: GitHubRelease { releases[0] }
    var id: String { latest.tagName }

    /// OTA manifest published next to the IPA (releases from 0.2.4 on).
    var manifestURL: URL? {
        latest.assets.first { $0.name == "manifest.plist" && $0.state == "uploaded" }?.browserDownloadUrl
    }
}

/// Checks GitHub Releases for a newer IPA. Bridge-only releases have no IPA
/// and are never marked as latest, so they are ignored here.
@MainActor
@Observable
final class AppUpdateCenter {
    nonisolated static let ipaName = "AirPlaySubtitlePlayer-unsigned.ipa"
    static let latestIPA = URL(string: "https://github.com/rsilva48/anksubbrd/releases/latest/download/AirPlaySubtitlePlayer-unsigned.ipa")!
    static let releasesPage = URL(string: "https://github.com/rsilva48/anksubbrd/releases")!
    private static let releasesAPI = URL(string: "https://api.github.com/repos/rsilva48/anksubbrd/releases?per_page=30")!
    private static let skippedVersionKey = "anksubbrd.skipped-update"

    static var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// LiveContainer refuses `livecontainer://install` while one of its apps is
    /// running ("restart LiveContainer to install apps"), which is always the
    /// case when this app asks. `open-web-page` instead offers to go back to
    /// LiveContainer, relaunches it and opens the page there; an
    /// `itms-services` manifest page is then installed by LiveContainer itself.
    /// Without a manifest (older releases) the direct install link is used.
    static func liveContainerInstallURL(manifest: URL?) -> URL? {
        guard let manifest else {
            var components = URLComponents()
            components.scheme = "livecontainer"
            components.host = "install"
            components.queryItems = [URLQueryItem(name: "url", value: latestIPA.absoluteString)]
            return components.url
        }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encodedManifest = manifest.absoluteString.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        let itms = "itms-services://?action=download-manifest&url=\(encodedManifest)"
        // LiveContainer reads the page URL as Base64 from the `url` query item.
        guard let payload = Data(itms.utf8).base64EncodedString().addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "livecontainer://open-web-page?url=\(payload)")
    }

    /// Nonisolated because `GitHubRelease` (a plain struct) uses it synchronously.
    nonisolated static func parse(_ value: String) -> [Int]? {
        let parts = value.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".")
        let numbers = parts.compactMap { Int($0) }
        return parts.count == 3 && numbers.count == 3 ? numbers : nil
    }

    var pendingUpdate: AvailableUpdate?
    private(set) var isChecking = false
    private(set) var statusMessage: String?
    @ObservationIgnored private var checkedOnLaunch = false

    func checkOnLaunch() async {
        guard !checkedOnLaunch else { return }
        checkedOnLaunch = true
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            guard let installed = Self.parse(Self.installedVersion) else {
                statusMessage = "Esta compilación (\(Self.installedVersion)) no tiene una versión de release."
                return
            }
            let newer = try await fetchReleases()
                .filter { release in
                    guard !release.draft, !release.prerelease, release.hasIPA, let version = release.version else { return false }
                    return installed.lexicographicallyPrecedes(version)
                }
                .sorted { ($1.version ?? []).lexicographicallyPrecedes($0.version ?? []) }
            guard let latest = newer.first else {
                statusMessage = "Tienes la versión más reciente (\(Self.installedVersion))."
                return
            }
            statusMessage = "Disponible la versión \(latest.tagName)."
            if !userInitiated, UserDefaults.standard.string(forKey: Self.skippedVersionKey) == latest.tagName { return }
            pendingUpdate = AvailableUpdate(releases: newer)
        } catch is CancellationError {
            return
        } catch {
            statusMessage = NetworkStatus.shared.isOnline
                ? "No se pudo consultar GitHub: \(error.localizedDescription)"
                : "Sin conexión: no se pudo buscar actualizaciones."
        }
    }

    func skip(_ update: AvailableUpdate) {
        UserDefaults.standard.set(update.latest.tagName, forKey: Self.skippedVersionKey)
        pendingUpdate = nil
    }

    private func fetchReleases() async throws -> [GitHubRelease] {
        var request = URLRequest(url: Self.releasesAPI)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRelease].self, from: data)
    }
}

struct UpdateSheet: View {
    let update: AvailableUpdate
    @Environment(AppUpdateCenter.self) private var updates
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var liveContainerUnavailable = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Instalada", value: AppUpdateCenter.installedVersion)
                    LabeledContent("Disponible", value: update.latest.tagName)
                }
                ForEach(update.releases) { release in
                    Section {
                        ReleaseNotesView(markdown: release.body ?? "")
                    } header: {
                        HStack {
                            Text(release.tagName)
                            Spacer()
                            if let date = release.publishedAt {
                                Text(date, format: .dateTime.day().month().year())
                            }
                        }
                    }
                }
            }
            .navigationTitle("Actualización disponible")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Ahora no", role: .cancel) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { actions }
            .alert("LiveContainer no respondió", isPresented: $liveContainerUnavailable) {
                Button("Descargar IPA") { openURL(AppUpdateCenter.latestIPA) }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("No se pudo abrir el enlace livecontainer://. Descarga el IPA e impórtalo manualmente en LiveContainer.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var actions: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(spacing: 10) {
                Button(action: installWithLiveContainer) {
                    Label("Instalar con LiveContainer", systemImage: "arrow.down.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                if update.manifestURL != nil {
                    Text("LiveContainer te pedirá volver a su pantalla principal; acepta y elige reemplazar la app existente para conservar tus datos.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button {
                    openURL(update.latest.htmlUrl)
                } label: {
                    Label("Ver la release en GitHub", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                Button("Omitir esta versión") {
                    updates.skip(update)
                    dismiss()
                }
                .font(.footnote)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func installWithLiveContainer() {
        guard let url = AppUpdateCenter.liveContainerInstallURL(manifest: update.manifestURL) else { return }
        openURL(url) { accepted in
            if accepted {
                dismiss()
            } else {
                liveContainerUnavailable = true
            }
        }
    }
}

/// Renders the release notes produced by the workflow: `##`/`###` headings,
/// `-` bullets and inline Markdown such as `code`. The "Instalar" section is
/// for the GitHub page; the sheet has its own install button.
private struct ReleaseNotesView: View {
    private struct Line: Identifiable {
        enum Kind { case heading, bullet, text }
        let id: Int
        let kind: Kind
        let text: String
    }

    let markdown: String

    private var lines: [Line] {
        var result: [Line] = []
        var skippingInstallSection = false
        for (index, raw) in markdown.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                skippingInstallSection = title == "Instalar"
                if skippingInstallSection || title == "Cambios" { continue }
                result.append(Line(id: index, kind: .heading, text: title))
            } else if line.isEmpty || skippingInstallSection {
                continue
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(Line(id: index, kind: .bullet, text: String(line.dropFirst(2))))
            } else {
                result.append(Line(id: index, kind: .text, text: line))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if lines.isEmpty {
                Text("Sin notas para esta versión.")
                    .foregroundStyle(.secondary)
            }
            ForEach(lines) { line in
                switch line.kind {
                case .heading:
                    Text(line.text)
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)
                case .bullet:
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(line.text))
                    }
                    .font(.subheadline)
                case .text:
                    Text(inline(line.text))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
