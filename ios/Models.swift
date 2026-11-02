import Foundation

enum StreamKind: String, Codable, CaseIterable, Identifiable {
    case sub
    case dub

    var id: String { rawValue }
    var displayName: String { self == .dub ? "Dub" : "Sub" }
    var detail: String { self == .dub ? "Audio en inglés" : "Audio en japonés con subtítulos" }
}

enum TitleLanguage: String, Codable, CaseIterable, Identifiable {
    case en
    case jp

    var id: String { rawValue }
    var displayName: String { self == .jp ? "Japonés" : "Inglés" }
}

/// Catalog and playback settings. They belong to the active identity (bridge
/// URL + token) and sync through the bridge like the watch history.
struct UserPreferences: Codable, Equatable {
    static let subtitlesOff = "off"

    var titleLanguage: TitleLanguage = .en
    var defaultTrack: StreamKind = .sub
    /// Subtitle language for Sub sources: empty follows the device languages,
    /// `off` disables them, anything else is a BCP-47 tag such as `en` or `es-419`.
    var subtitleLanguage = ""
    var autoNext = true
    var autoSkipIntro = false
    var autoSkipOutro = false
    var updatedAt = Date.distantPast

    enum CodingKeys: String, CodingKey {
        case titleLanguage
        case defaultTrack = "defaultTrackType"
        case subtitleLanguage
        case autoNext
        case autoSkipIntro
        case autoSkipOutro
        case updatedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        titleLanguage = (try? container.decode(TitleLanguage.self, forKey: .titleLanguage)) ?? .en
        defaultTrack = (try? container.decode(StreamKind.self, forKey: .defaultTrack)) ?? .sub
        subtitleLanguage = (try? container.decode(String.self, forKey: .subtitleLanguage)) ?? ""
        autoNext = (try? container.decode(Bool.self, forKey: .autoNext)) ?? true
        autoSkipIntro = (try? container.decode(Bool.self, forKey: .autoSkipIntro)) ?? false
        autoSkipOutro = (try? container.decode(Bool.self, forKey: .autoSkipOutro)) ?? false
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? .distantPast
    }

    /// Compares the settings themselves, ignoring when they were changed.
    func hasSameSettings(as other: UserPreferences) -> Bool {
        var copy = other
        copy.updatedAt = updatedAt
        return copy == self
    }
}

struct Anime: Codable, Hashable, Identifiable {
    let title: String
    let watchUrl: String
    let imageUrl: String?
    let meta: String
    let rating: String?
    let score: Double?
    let mediaType: String?
    let year: Int?
    var titleJp: String? = nil
    var episode: Int? = nil
    var id: String { watchUrl }

    func displayTitle(_ language: TitleLanguage) -> String {
        if language == .jp, let titleJp, !titleJp.isEmpty { return titleJp }
        return title
    }

    var metadataLine: String {
        [mediaType, year.map(String.init), score.map { String(format: "★ %.1f", $0) }, rating]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

struct Series: Decodable {
    let seriesKey: String
    let title: String
    let titleJp: String?
    let episodes: [Episode]
    let seasons: [Season]
}

struct Season: Decodable, Identifiable, Hashable {
    let title: String
    let titleJp: String?
    let watchUrl: String
    let imageUrl: String?
    let meta: String?
    let rating: String?
    let score: Double?
    let mediaType: String?
    let year: Int?
    let seasonNumber: Int
    var id: String { watchUrl }

    var anime: Anime {
        Anime(title: title, watchUrl: watchUrl, imageUrl: imageUrl, meta: meta ?? "", rating: rating, score: score, mediaType: mediaType, year: year, titleJp: titleJp)
    }
}

struct Episode: Decodable, Identifiable, Hashable {
    let number: Int
    let title: String
    var id: Int { number }

    /// The bridge falls back to "Episode N"; that adds nothing next to the number.
    var subtitle: String? {
        let value = title.trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value == "Episode \(number)" ? nil : value
    }
}

struct Server: Decodable, Identifiable {
    let index: Int
    let name: String
    let type: String
    var id: Int { index }
    var kind: StreamKind { StreamKind(rawValue: type.lowercased()) ?? .sub }
}

struct EpisodeServers: Identifiable {
    let episode: Episode
    let servers: [Server]
    var id: Int { episode.number }
}

struct SkipRange: Decodable {
    let start: Double
    let end: Double

    func contains(_ seconds: Double) -> Bool { seconds >= start && seconds < end }
}

struct Playback: Decodable {
    let playbackUrl: String
    let subtitleTracks: Int
    let serverName: String
    let serverKind: String?
    let intro: SkipRange?
    let outro: SkipRange?
}

struct PlaybackSession: Identifiable {
    let playback: Playback
    let historyEntry: WatchHistoryEntry
    let kind: StreamKind
    var id: String { playback.playbackUrl }
}

struct WatchHistoryEntry: Codable, Hashable, Identifiable {
    let seriesTitle: String
    let watchUrl: String
    let imageUrl: String?
    let episode: Int
    let episodeTitle: String
    let serverName: String
    var positionSeconds: Double
    var updatedAt: Date
    var titleJp: String? = nil
    var serverKind: String? = nil
    var id: String { "\(watchUrl)#\(episode)" }

    var kind: StreamKind? { serverKind.flatMap(StreamKind.init(rawValue:)) }

    var episodeLabel: String {
        let title = episodeTitle.trimmingCharacters(in: .whitespaces)
        return title.isEmpty || title == "Episode \(episode)" ? "Episodio \(episode)" : "Episodio \(episode) · \(title)"
    }

    var anime: Anime {
        Anime(title: seriesTitle, watchUrl: watchUrl, imageUrl: imageUrl, meta: "", rating: nil, score: nil, mediaType: nil, year: nil, titleJp: titleJp)
    }
}

struct HistoryDeletion: Codable, Hashable, Identifiable {
    let watchUrl: String
    let updatedAt: Date
    var id: String { watchUrl }
}

// MARK: - Bridge payloads

struct BridgeErrorResponse: Decodable { let error: String? }
struct HealthResponse: Decodable {
    let ok: Bool
    let provider: String?
    let version: String?

    /// "bridge 0.2.0 · ANK", or nil for bridges that predate the fields.
    var summary: String? {
        let parts = [version.map { "bridge \($0)" }, provider].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
struct SearchResponse: Decodable { let results: [Anime] }
struct LatestResponse: Decodable { let results: [Anime]; let page: Int; let hasNext: Bool }
struct WatchRequest: Encodable { let watchUrl: String }
struct ServerResponse: Decodable { let episode: Int; let servers: [Server] }
struct PlayRequest: Encodable { let seriesKey: String; let episode: Int; let serverIndex: Int }
struct HistoryResponse: Decodable { let entries: [WatchHistoryEntry]; let deletions: [HistoryDeletion]? }
struct HistoryPayload: Encodable { let entries: [WatchHistoryEntry]; let deletions: [HistoryDeletion] }
struct PreferencesEnvelope: Codable { let preferences: UserPreferences? }
struct AdminUserRequest: Encodable { let token: String; let label: String }
struct AdminUserResponse: Decodable { let userId: String; let createdAt: String }

/// Provider-relative identity of a series (its `/watch/…` path). The bridge
/// rebases watch URLs when the catalog moves to another domain, so history
/// entries saved under the old domain still match the same series.
func catalogPath(of watchUrl: String) -> String {
    let path = URLComponents(string: watchUrl)?.path ?? ""
    return path.isEmpty ? watchUrl : path
}

func formatTime(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
    let hours = value / 3600, minutes = (value % 3600) / 60, rest = value % 60
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
}
