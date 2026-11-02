import CryptoKit
import SwiftUI
import UIKit

/// A stable file name for a URL or path.
func cacheFileName(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Posters kept on disk (Application Support) so Continue, Downloads and the
/// series screen show them offline. Files unused for 60 days are pruned.
enum PosterCache {
    private static let memory = NSCache<NSString, UIImage>()

    static var folder: URL { URL.applicationSupportDirectory.appendingPathComponent("Posters", isDirectory: true) }

    private static func file(for url: URL) -> URL {
        folder.appendingPathComponent(cacheFileName(url.absoluteString))
    }

    /// A poster already in memory or on disk.
    static func cachedImage(for url: URL) -> UIImage? {
        let key = url.absoluteString as NSString
        if let image = memory.object(forKey: key) { return image }
        let file = file(for: url)
        guard let image = UIImage(contentsOfFile: file.path) else { return nil }
        memory.setObject(image, forKey: key)
        // Marks it as used for pruning.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return image
    }

    /// The cached poster, or downloads and stores it; nil offline.
    static func image(for url: URL) async -> UIImage? {
        if let cached = cachedImage(for: url) { return cached }
        guard let result = try? await URLSession.shared.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: result.0) else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? result.0.write(to: file(for: url), options: .atomic)
        memory.setObject(image, forKey: url.absoluteString as NSString)
        return image
    }

    /// Stores a poster ahead of time (series in Continue and downloads).
    static func prefetch(_ value: String?) async {
        guard let value, let url = URL(string: value) else { return }
        _ = await image(for: url)
    }

    static func prune(olderThanDays days: Double = 60) {
        pruneFiles(in: folder, olderThanDays: days)
    }
}

func pruneFiles(in folder: URL, olderThanDays days: Double) {
    let limit = Date().addingTimeInterval(-days * 86_400)
    guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    for file in files {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if modified < limit { try? FileManager.default.removeItem(at: file) }
    }
}

struct PosterImage: View {
    let imageURL: String?
    var cornerRadius: CGFloat = 10
    @State private var image: UIImage?
    @State private var failed = false

    init(imageURL: String?, cornerRadius: CGFloat = 10) {
        self.imageURL = imageURL
        self.cornerRadius = cornerRadius
        // Cached posters show on the first frame, without a spinner.
        _image = State(initialValue: imageURL.flatMap { URL(string: $0) }.flatMap { PosterCache.cachedImage(for: $0) })
    }

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed || imageURL == nil {
                    placeholder
                } else {
                    ProgressView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
            .task(id: imageURL) { await load() }
    }

    private func load() async {
        guard let imageURL, let url = URL(string: imageURL) else {
            image = nil
            failed = true
            return
        }
        if let cached = PosterCache.cachedImage(for: url) {
            image = cached
            failed = false
            return
        }
        image = nil
        failed = false
        let loaded = await PosterCache.image(for: url)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            image = loaded
            failed = loaded == nil
        }
    }

    private var placeholder: some View {
        Image(systemName: "film")
            .font(.title3)
            .foregroundStyle(.secondary)
    }
}

/// The last series payload loaded for each catalog path, so the series screen
/// (synopsis, episodes, seasons) opens offline from Continue or Downloads.
enum SeriesCache {
    static var folder: URL { URL.applicationSupportDirectory.appendingPathComponent("SeriesCache", isDirectory: true) }

    private static func file(for watchUrl: String) -> URL {
        folder.appendingPathComponent(cacheFileName(catalogPath(of: watchUrl)) + ".json")
    }

    static func store(_ series: Series, for watchUrl: String) {
        guard let data = try? JSONEncoder().encode(series) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file(for: watchUrl), options: .atomic)
    }

    static func load(_ watchUrl: String) -> Series? {
        guard let data = try? Data(contentsOf: file(for: watchUrl)) else { return nil }
        return try? JSONDecoder().decode(Series.self, from: data)
    }

    static func prune(olderThanDays days: Double = 60) {
        pruneFiles(in: folder, olderThanDays: days)
    }
}

/// Series title in the selected catalog language. In the Japanese mode the
/// English name stays first and the Japanese title is shown underneath.
struct SeriesTitle: View {
    let title: String
    let titleJp: String?
    let language: TitleLanguage
    var font: Font = .headline
    var lineLimit = 2

    private var japanese: String? {
        guard language == .jp, let titleJp, !titleJp.isEmpty, titleJp != title else { return nil }
        return titleJp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(font)
                .lineLimit(lineLimit)
            if let japanese {
                Text(japanese)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
            }
        }
    }
}

/// Settings that belong to this device rather than to the bridge identity.
enum DeviceSettings {
    /// Translate synopses to the device language as soon as they load.
    static let translateSynopsisKey = "anksubbrd.translate-synopsis"
}

/// "+18" marker for R+ and Rx series.
struct AdultBadge: View {
    var body: some View {
        Text("+18")
            .font(.caption2.weight(.heavy))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.red, in: Capsule())
            .accessibilityLabel("Para mayores de 18 años")
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
            Color.black.opacity(0.2).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
            .padding(32)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

/// On iPad the adaptable tab bar shares the navigation bar area while it
/// morphs to and from the sidebar; inline root titles avoid being covered.
struct AdaptableTabRootTitleStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationBarTitleDisplayMode(UIDevice.current.userInterfaceIdiom == .pad ? .inline : .automatic)
    }
}

/// Circular Liquid Glass icon used by the player controls and menus.
struct GlassIcon: View {
    let systemName: String
    var size: CGFloat = 44
    var font: Font = .title3

    var body: some View {
        Image(systemName: systemName)
            .font(font.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)
    }
}
