import GoogleCast
import Observation
import SwiftUI
import UIKit

/// A temporary link the bridge creates so a Cast receiver can load one
/// playback without the identity token (`POST /api/cast`).
struct CastShare: Decodable {
    let id: String
    let url: String
    let contentType: String?
    let subtitles: [CastSubtitle]
}

/// A subtitle file of a cast link; `id` is the receiver's track id.
struct CastSubtitle: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let language: String
    let url: String
    let forced: Bool?
    let isDefault: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, language, url, forced
        case isDefault = "default"
    }
}

struct CastShareRequest: Encodable { let playbackUrl: String }
private struct CastRevokeResponse: Decodable { let ok: Bool }

enum CastPlaybackState: Equatable {
    case idle, loading, buffering, playing, paused
}

/// Google Cast with the Default Media Receiver: device discovery and the
/// session belong to the SDK (its Cast button picks the device and offers
/// disconnecting); this mirrors the session and the receiver's media status
/// for the player, and sends it commands. AirPlay is independent of it.
@MainActor
@Observable
final class CastCenter {
    static let shared = CastCenter()

    private(set) var isConnected = false
    /// The SDK found a Cast device on this Wi-Fi (or a session is open).
    private(set) var devicesAvailable = false
    private(set) var deviceName: String?
    private(set) var state: CastPlaybackState = .idle
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    /// The receiver's device volume, 0…1.
    private(set) var volume: Float = 0
    private(set) var activeTrackIDs: [Int] = []
    /// The content URL the receiver has loaded (a cast link).
    private(set) var loadedURL: String?
    /// Increases each time the loaded media plays to its end.
    private(set) var finishedCount = 0
    /// The receiver could not play what was sent.
    private(set) var failure: String?
    /// Increases when a session starts or resumes (after the app was in the
    /// background or relaunched); a suspension alone changes nothing, so the
    /// receiver keeps playing undisturbed.
    private(set) var sessionGeneration = 0
    /// Increases when a session really ends (the user stopped casting, or the
    /// device went away).
    private(set) var endedGeneration = 0

    @ObservationIgnored private let listener = CastListener()
    @ObservationIgnored private weak var observedClient: GCKRemoteMediaClient?
    @ObservationIgnored private var positionTask: Task<Void, Never>?

    private init() {
        listener.center = self
    }

    /// Called from `application(_:didFinishLaunchingWithOptions:)`, as the SDK
    /// requires for sessions to resume after the app was suspended or closed.
    static func configure() {
        guard !GCKCastContext.isSharedInstanceInitialized() else { return }
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        // Discovery starts with the app (the bridge on the home network
        // already asks for local network access), so the Cast button can
        // appear only when there is a device: the SDK's own button hides
        // itself without devices or Wi-Fi, which left an empty glass circle.
        options.startDiscoveryAfterFirstTapOnCastButton = false
        options.suspendSessionsWhenBackgrounded = true
        GCKCastContext.setSharedInstanceWith(options)
        shared.attach()
    }

    private var sessionManager: GCKSessionManager { GCKCastContext.sharedInstance().sessionManager }
    private var client: GCKRemoteMediaClient? { sessionManager.currentCastSession?.remoteMediaClient }

    private func attach() {
        sessionManager.add(listener)
        _ = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: kGCKCastStateDidChangeNotification), object: GCKCastContext.sharedInstance(), queue: .main) { _ in
            MainActor.assumeIsolated { CastCenter.shared.castStateChanged() }
        }
        castStateChanged()
        sessionChanged()
    }

    private func castStateChanged() {
        devicesAvailable = GCKCastContext.sharedInstance().castState != .noDevicesAvailable
    }

    // MARK: Session

    /// Start, resume (also after a relaunch) and end of a session.
    fileprivate func sessionChanged() {
        let session = sessionManager.currentCastSession
        let connected = session != nil && sessionManager.connectionState == .connected
        isConnected = connected
        deviceName = connected ? session?.device.friendlyName : nil
        if let session { volume = session.currentDeviceVolume }
        if observedClient !== session?.remoteMediaClient {
            observedClient?.remove(listener)
            observedClient = session?.remoteMediaClient
            observedClient?.add(listener)
        }
        if !connected {
            state = .idle
            loadedURL = nil
            activeTrackIDs = []
            positionTask?.cancel()
            positionTask = nil
        }
        mediaStatusChanged()
    }

    fileprivate func sessionStarted() {
        sessionChanged()
        if isConnected { sessionGeneration += 1 }
    }

    fileprivate func sessionEnded() {
        sessionChanged()
        endedGeneration += 1
    }

    fileprivate func sessionFailed(_ error: Error?) {
        failure = error.map { String(localized: "No se pudo conectar con el dispositivo Cast: \($0.localizedDescription)") }
        sessionChanged()
    }

    fileprivate func deviceVolumeChanged() {
        if let session = sessionManager.currentCastSession { volume = session.currentDeviceVolume }
    }

    // MARK: Media status

    fileprivate func mediaStatusChanged() {
        guard let status = client?.mediaStatus else {
            if isConnected { state = .idle }
            return
        }
        switch status.playerState {
        case .playing: state = .playing
        case .paused: state = .paused
        case .buffering: state = .buffering
        case .loading: state = .loading
        default:
            if state != .idle, status.idleReason == .finished { finishedCount += 1 }
            if status.idleReason == .error {
                failure = String(localized: "El dispositivo Cast no pudo reproducir el episodio. Comprueba que puede acceder al bridge (misma red o HTTPS público).")
            }
            state = .idle
        }
        if let info = status.mediaInformation {
            loadedURL = info.contentURL?.absoluteString ?? info.contentID
            if info.streamDuration.isFinite, info.streamDuration > 0 { duration = info.streamDuration }
        }
        activeTrackIDs = (status.activeTrackIDs ?? []).map(\.intValue)
        position = client?.approximateStreamPosition() ?? status.streamPosition
        followPosition()
    }

    /// The receiver reports its position only on changes; while it plays the
    /// SDK's estimate is read twice a second.
    private func followPosition() {
        guard state == .playing else {
            positionTask?.cancel()
            positionTask = nil
            return
        }
        guard positionTask == nil else { return }
        positionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, let client = self.client else { return }
                self.position = client.approximateStreamPosition()
            }
        }
    }

    // MARK: Commands

    /// Loads one episode on the receiver: the cast link's HLS stream (MPEG-TS
    /// segments) and its subtitle files as side-loaded WebVTT tracks.
    func load(_ share: CastShare, title: String, subtitle: String, imageURL: String?, startAt: Double, subtitleID: Int?) -> Bool {
        guard let client, let url = URL(string: share.url) else { return false }
        failure = nil
        let metadata = GCKMediaMetadata(metadataType: .tvShow)
        metadata.setString(title, forKey: kGCKMetadataKeySeriesTitle)
        metadata.setString(title, forKey: kGCKMetadataKeyTitle)
        metadata.setString(subtitle, forKey: kGCKMetadataKeySubtitle)
        if let imageURL, let image = URL(string: imageURL) {
            metadata.addImage(GCKImage(url: image, width: 480, height: 720))
        }
        let tracks = share.subtitles.compactMap { track in
            GCKMediaTrack(
                identifier: track.id,
                contentIdentifier: track.url,
                contentType: "text/vtt",
                type: .text,
                textSubtype: .subtitles,
                name: track.name,
                languageCode: track.language,
                customData: nil
            )
        }
        let builder = GCKMediaInformationBuilder(contentURL: url)
        builder.contentID = share.url
        builder.streamType = .buffered
        builder.contentType = share.contentType ?? "application/x-mpegURL"
        builder.hlsSegmentFormat = .TS
        builder.hlsVideoSegmentFormat = .MPEG2_TS
        builder.metadata = metadata
        builder.mediaTracks = tracks
        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = builder.build()
        request.autoplay = NSNumber(value: true)
        request.startTime = max(0, startAt)
        request.activeTrackIDs = subtitleID.map { [NSNumber(value: $0)] }
        _ = client.loadMedia(with: request.build())
        loadedURL = share.url
        state = .loading
        position = max(0, startAt)
        activeTrackIDs = subtitleID.map { [$0] } ?? []
        return true
    }

    func play() { _ = client?.play() }
    func pause() { _ = client?.pause() }

    func seek(to seconds: Double) {
        guard let client else { return }
        let options = GCKMediaSeekOptions()
        options.interval = max(0, seconds)
        options.resumeState = .unchanged
        _ = client.seek(with: options)
        position = max(0, seconds)
    }

    func setSubtitle(_ id: Int?) {
        _ = client?.setActiveTrackIDs(id.map { [NSNumber(value: $0)] } ?? [])
        activeTrackIDs = id.map { [$0] } ?? []
    }

    func setVolume(_ value: Float) {
        let clamped = min(1, max(0, value))
        volume = clamped
        _ = sessionManager.currentCastSession?.setDeviceVolume(clamped)
    }

    /// Ends the session and stops the receiver's playback.
    func disconnect() {
        _ = sessionManager.endSessionAndStopCasting(true)
    }

    func clearFailure() { failure = nil }

    /// Revokes a cast link once the receiver no longer needs it.
    static func revoke(_ share: CastShare, base: String) {
        Task {
            let _: CastRevokeResponse? = try? await BridgeClient.delete(base: base, path: "/api/cast/\(share.id)")
        }
    }
}

/// The SDK calls its listeners on the main thread.
private final class CastListener: NSObject, GCKSessionManagerListener, GCKRemoteMediaClientListener {
    weak var center: CastCenter?

    private func onMain(_ action: @escaping @MainActor (CastCenter) -> Void) {
        MainActor.assumeIsolated {
            if let center { action(center) }
        }
    }

    // Explicit selectors: these optional requirements are matched by their
    // Objective-C names, whatever Swift name the SDK's headers import as.
    @objc(sessionManager:didStartSession:)
    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        onMain { $0.sessionStarted() }
    }

    @objc(sessionManager:didResumeSession:)
    func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) {
        onMain { $0.sessionStarted() }
    }

    @objc(sessionManager:didEndSession:withError:)
    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        onMain { $0.sessionEnded() }
    }

    @objc(sessionManager:didFailToStartSession:withError:)
    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
        onMain { $0.sessionFailed(error) }
    }

    @objc(sessionManager:session:didReceiveDeviceVolume:muted:)
    func sessionManager(_ sessionManager: GCKSessionManager, session: GCKSession, didReceiveDeviceVolume volume: Float, muted: Bool) {
        onMain { $0.deviceVolumeChanged() }
    }

    @objc(remoteMediaClient:didUpdateMediaStatus:)
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        onMain { $0.mediaStatusChanged() }
    }
}

/// The SDK's Cast button: picks a device, and once connected shows the
/// device with its volume and a button to stop casting.
struct CastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> GCKUICastButton {
        let button = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        button.tintColor = .white
        return button
    }

    func updateUIView(_ button: GCKUICastButton, context: Context) {}
}
