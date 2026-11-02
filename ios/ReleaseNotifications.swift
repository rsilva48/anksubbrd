import Foundation
import Observation
import UserNotifications

/// One estimated airing from the catalog's weekly schedule.
struct ScheduleEntry: Decodable {
    let watchUrl: String
    let title: String
    let titleJp: String?
    let imageUrl: String?
    let episode: Int
    let kind: StreamKind
    /// Unix seconds.
    let airingAt: Double

    var airingDate: Date { Date(timeIntervalSince1970: airingAt) }
}

struct ScheduleResponse: Decodable { let entries: [ScheduleEntry] }

/// Reminders for new episodes of the series in Continue. They are local
/// notifications scheduled on the device from the estimated schedule: remote
/// push would need a signed app with the push entitlement and a sender.
@MainActor
@Observable
final class ReleaseNotifier {
    static let shared = ReleaseNotifier()
    static let enabledKey = "anksubbrd.release-notifications"
    private static let identifierPrefix = "anksubbrd.release."
    /// The catalog needs a few minutes after the estimated time to publish.
    private static let publishingDelay: TimeInterval = 5 * 60

    /// Series opened from a notification; the root view presents it.
    var openedSeries: Anime?

    @ObservationIgnored private let delegate = ReleaseNotificationDelegate()

    private init() {
        delegate.notifier = self
        UNUserNotificationCenter.current().delegate = delegate
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// Asks for permission; false when the user declined (now or before).
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Replaces the scheduled reminders: one per upcoming episode, newer than
    /// the one watched, of the Sub/Dub kind each series is followed in.
    func refresh(profile: ProfileStore) async {
        let center = UNUserNotificationCenter.current()
        guard isEnabled, profile.isBridgeConfigured else {
            await removeScheduled(keeping: [])
            return
        }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let reply: ScheduleResponse
        do {
            reply = try await BridgeClient.get(base: profile.bridgeURL, path: "/api/schedule")
        } catch {
            // Offline or an older bridge: the reminders already scheduled stay.
            return
        }
        let now = Date()
        var requests: [UNNotificationRequest] = []
        for item in reply.entries where item.airingDate.addingTimeInterval(Self.publishingDelay) > now {
            guard let entry = profile.entry(for: item.watchUrl),
                  item.kind == (entry.kind ?? profile.preferences.defaultTrack),
                  item.episode > entry.episode else { continue }
            requests.append(request(for: item, language: profile.preferences.titleLanguage))
        }
        // iOS keeps at most 64 pending local notifications per app.
        requests = Array(requests.prefix(48))
        await removeScheduled(keeping: Set(requests.map(\.identifier)))
        for request in requests {
            try? await center.add(request)
        }
    }

    fileprivate func open(watchUrl: String, title: String, titleJp: String?, imageUrl: String?) {
        openedSeries = Anime(title: title, watchUrl: watchUrl, imageUrl: imageUrl, meta: "", rating: nil, score: nil, mediaType: nil, year: nil, titleJp: titleJp)
    }

    private func removeScheduled(keeping identifiers: Set<String>) async {
        let center = UNUserNotificationCenter.current()
        let stale = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) && !identifiers.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
    }

    private func request(for item: ScheduleEntry, language: TitleLanguage) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        let japanese = item.titleJp.flatMap { $0.isEmpty ? nil : $0 }
        content.title = language == .jp ? japanese ?? item.title : item.title
        content.body = "El episodio \(item.episode) en \(item.kind.displayName) ya debería estar disponible."
        content.sound = .default
        content.threadIdentifier = catalogPath(of: item.watchUrl)
        content.userInfo = [
            "watchUrl": item.watchUrl,
            "title": item.title,
            "titleJp": japanese ?? "",
            "imageUrl": item.imageUrl ?? "",
        ]
        let date = item.airingDate.addingTimeInterval(Self.publishingDelay)
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let identifier = "\(Self.identifierPrefix)\(catalogPath(of: item.watchUrl))#\(item.episode)#\(item.kind.rawValue)"
        return UNNotificationRequest(identifier: identifier, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }
}

private final class ReleaseNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var notifier: ReleaseNotifier?

    /// Banners also show while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// Tapping a reminder opens that series.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let text = { (key: String) -> String? in
            guard let value = info[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        if let watchUrl = text("watchUrl") {
            let title = text("title") ?? "", titleJp = text("titleJp"), imageUrl = text("imageUrl")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.notifier?.open(watchUrl: watchUrl, title: title, titleJp: titleJp, imageUrl: imageUrl)
                }
            }
        }
        completionHandler()
    }
}
