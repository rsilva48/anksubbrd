import AVFoundation
import AVKit
import Combine
import MediaPlayer
import Observation
import SwiftUI
import UIKit

enum PlaybackSpeed: Float, CaseIterable, Identifiable {
    case slow = 0.75
    case normal = 1
    case fast = 1.25
    case faster = 1.5
    case double = 2

    var id: Float { rawValue }

    var label: String {
        switch self {
        case .slow: return "0,75×"
        case .normal: return "Normal"
        case .fast: return "1,25×"
        case .faster: return "1,5×"
        case .double: return "2×"
        }
    }
}

/// Owns the AVPlayer for one presentation of the player. Episodes change in
/// place: the item is replaced while the screen, AirPlay route and PiP stay.
@MainActor
@Observable
final class PlayerModel: Identifiable {
    let player = AVPlayer()
    private(set) var session: PlaybackSession
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = true
    private(set) var isExternalPlayback = false
    private(set) var externalRouteName: String?
    private(set) var legibleOptions: [AVMediaSelectionOption] = []
    private(set) var selectedLegible: AVMediaSelectionOption?
    private(set) var audibleOptions: [AVMediaSelectionOption] = []
    private(set) var selectedAudible: AVMediaSelectionOption?
    private(set) var canUsePictureInPicture = false
    private(set) var isPictureInPictureActive = false
    private(set) var isChangingEpisode = false
    private(set) var didFinish = false
    private(set) var errorMessage: String?
    private(set) var speed: PlaybackSpeed = .normal
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    private let resolver: PlaybackResolver
    private let profile: ProfileStore
    @ObservationIgnored private var legibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var audibleGroup: AVMediaSelectionGroup?
    /// Subtitle choice made during a Dub episode; kept only for this session.
    @ObservationIgnored private var dubSubtitleChoice = ""
    @ObservationIgnored private var playerTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var itemTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var pictureInPicture: AVPictureInPictureController?
    @ObservationIgnored private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var lastSavedSecond = -1
    @ObservationIgnored private var started = false
    @ObservationIgnored private var closed = false

    init(session: PlaybackSession, resolver: PlaybackResolver, profile: ProfileStore) {
        self.session = session
        self.resolver = resolver
        self.profile = profile
    }

    var hasPrevious: Bool { resolver.episode(adjacentTo: session.historyEntry.episode, offset: -1) != nil }
    var hasNext: Bool { resolver.episode(adjacentTo: session.historyEntry.episode, offset: 1) != nil }

    var activeSkip: (title: String, end: Double)? {
        let preferences = profile.preferences
        if let intro = session.playback.intro, intro.contains(currentTime), !preferences.autoSkipIntro { return ("Saltar intro", intro.end) }
        if let outro = session.playback.outro, outro.contains(currentTime), !preferences.autoSkipOutro { return ("Saltar outro", outro.end) }
        return nil
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        AudioSession.configure()
        AudioSession.setActive(true)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        observePlayer()
        registerRemoteCommands()
        load(session)
    }

    func close() {
        guard started, !closed else { return }
        closed = true
        saveProgress()
        playerTasks.forEach { $0.cancel() }
        itemTasks.forEach { $0.cancel() }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        pictureInPicture?.stopPictureInPicture()
        pictureInPicture = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        unregisterRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        AudioSession.setActive(false)
    }

    func attach(_ layer: AVPlayerLayer) {
        guard pictureInPicture == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller: AVPictureInPictureController? = AVPictureInPictureController(playerLayer: layer)
        guard let controller else { return }
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pictureInPicture = controller
        playerTasks.append(Task { [weak self] in
            for await possible in controller.publisher(for: \.isPictureInPicturePossible).values {
                self?.canUsePictureInPicture = possible
            }
        })
        playerTasks.append(Task { [weak self] in
            for await active in controller.publisher(for: \.isPictureInPictureActive).values {
                self?.isPictureInPictureActive = active
            }
        })
    }

    // MARK: Controls

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        if didFinish {
            didFinish = false
            seek(to: 0)
        }
        player.defaultRate = speed.rawValue
        player.play()
    }

    func pause() {
        player.pause()
        saveProgress()
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        let upper = duration > 0 ? max(0, duration - 0.5) : max(0, seconds)
        let target = min(max(0, seconds), upper)
        currentTime = target
        let time = CMTime(seconds: target, preferredTimescale: 600)
        guard player.currentItem?.status == .readyToPlay else {
            player.seek(to: time)
            return
        }
        player.seek(to: time) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateNowPlaying() }
        }
    }

    func setSpeed(_ value: PlaybackSpeed) {
        speed = value
        player.defaultRate = value.rawValue
        if isPlaying { player.rate = value.rawValue }
        updateNowPlaying()
    }

    func selectLegible(_ option: AVMediaSelectionOption?) {
        guard let item = player.currentItem, let group = legibleGroup else { return }
        item.select(option, in: group)
        selectedLegible = option
        let choice = option.map { $0.extendedLanguageTag ?? "" } ?? UserPreferences.subtitlesOff
        if session.kind == .sub {
            // Remembered for the identity, so the next episode (and other
            // devices with the same token) start with the same subtitles.
            var preferences = profile.preferences
            preferences.subtitleLanguage = choice
            profile.setPreferences(preferences)
        } else {
            dubSubtitleChoice = choice
        }
    }

    func selectAudible(_ option: AVMediaSelectionOption) {
        guard let item = player.currentItem, let group = audibleGroup else { return }
        item.select(option, in: group)
        selectedAudible = option
    }

    func togglePictureInPicture() {
        guard let pictureInPicture else { return }
        if pictureInPicture.isPictureInPictureActive {
            pictureInPicture.stopPictureInPicture()
        } else {
            pictureInPicture.startPictureInPicture()
        }
    }

    func changeEpisode(by offset: Int) {
        guard !isChangingEpisode, !closed,
              let episode = resolver.episode(adjacentTo: session.historyEntry.episode, offset: offset) else { return }
        saveProgress()
        player.pause()
        isChangingEpisode = true
        errorMessage = nil
        let current = session
        Task {
            defer { isChangingEpisode = false }
            do {
                let next = try await resolver.session(for: episode, preferredName: current.playback.serverName, kind: current.kind)
                guard !closed else { return }
                load(next)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "No se pudo abrir el episodio \(episode.number). \(error.localizedDescription)"
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: Item

    private func load(_ session: PlaybackSession) {
        itemTasks.forEach { $0.cancel() }
        itemTasks = []
        self.session = session
        didFinish = false
        errorMessage = nil
        currentTime = 0
        duration = 0
        isBuffering = true
        legibleGroup = nil
        audibleGroup = nil
        legibleOptions = []
        audibleOptions = []
        selectedLegible = nil
        selectedAudible = nil
        lastSavedSecond = -1
        guard let url = URL(string: session.playback.playbackUrl) else {
            errorMessage = "La URL de reproducción no es válida."
            return
        }
        profile.open(session.historyEntry)
        let resumeAt = profile.position(for: session.historyEntry.watchUrl, episode: session.historyEntry.episode)
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if resumeAt > 3 {
            currentTime = resumeAt
            player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
        }
        observe(item)
        updateNowPlaying()
        player.defaultRate = speed.rawValue
        player.play()
    }

    private func observe(_ item: AVPlayerItem) {
        itemTasks = [
            Task { [weak self] in
                for await status in item.publisher(for: \.status).values {
                    self?.itemStatusChanged(status, item: item)
                }
            },
            Task { [weak self] in
                for await value in item.publisher(for: \.duration).values {
                    self?.durationChanged(value)
                }
            },
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: .AVPlayerItemDidPlayToEndTime, object: item) {
                    self?.playbackEnded()
                }
            },
            Task { [weak self] in
                for await notification in NotificationCenter.default.notifications(named: .AVPlayerItemFailedToPlayToEndTime, object: item) {
                    let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                    self?.fail(error)
                }
            },
        ]
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, item: AVPlayerItem) {
        guard player.currentItem === item else { return }
        switch status {
        case .readyToPlay:
            durationChanged(item.duration)
            Task { await loadMediaOptions(for: item) }
        case .failed:
            fail(item.error)
        default:
            break
        }
    }

    private func durationChanged(_ value: CMTime) {
        let seconds = value.seconds
        guard seconds.isFinite, seconds > 0, seconds != duration else { return }
        duration = seconds
        updateNowPlaying()
    }

    private func loadMediaOptions(for item: AVPlayerItem) async {
        let legible = try? await item.asset.loadMediaSelectionGroup(for: .legible)
        let audible = try? await item.asset.loadMediaSelectionGroup(for: .audible)
        guard player.currentItem === item else { return }
        legibleGroup = legible
        audibleGroup = audible
        legibleOptions = legible.map { AVMediaSelectionGroup.mediaSelectionOptions(from: $0.options, withoutMediaCharacteristics: [.containsOnlyForcedSubtitles]) } ?? []
        audibleOptions = audible?.options ?? []
        applySubtitleChoice(to: item)
        refreshSelection()
    }

    /// Sub sources carry Japanese audio, so subtitles are switched on: the
    /// remembered language, otherwise the device languages, otherwise the
    /// bridge default. Dub sources keep AVPlayer's automatic choice unless the
    /// user picked something during this session.
    private func applySubtitleChoice(to item: AVPlayerItem) {
        guard let group = legibleGroup else { return }
        let choice = session.kind == .sub ? profile.preferences.subtitleLanguage : dubSubtitleChoice
        if choice == UserPreferences.subtitlesOff {
            item.select(nil, in: group)
        } else if !choice.isEmpty, let option = legibleOption(matching: choice) {
            item.select(option, in: group)
        } else if session.kind == .sub, let option = automaticSubtitle() {
            item.select(option, in: group)
        }
    }

    private func legibleOption(matching tag: String) -> AVMediaSelectionOption? {
        let wanted = tag.lowercased()
        if let exact = legibleOptions.first(where: { $0.extendedLanguageTag?.lowercased() == wanted }) { return exact }
        return legibleOptions.first { option in
            guard let language = option.extendedLanguageTag?.lowercased() else { return false }
            return language.hasPrefix(wanted + "-") || wanted.hasPrefix(language + "-")
        }
    }

    private func automaticSubtitle() -> AVMediaSelectionOption? {
        let ranked = AVMediaSelectionGroup.mediaSelectionOptions(from: legibleOptions, filteredAndSortedAccordingToPreferredLanguages: Locale.preferredLanguages)
        return ranked.first
            ?? legibleOptions.first(where: { $0 == legibleGroup?.defaultOption })
            ?? legibleOption(matching: "en")
            ?? legibleOptions.first
    }

    private func refreshSelection() {
        guard let item = player.currentItem else { return }
        selectedLegible = legibleGroup.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }
        selectedAudible = audibleGroup.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }
    }

    private func playbackEnded() {
        saveProgress()
        if profile.preferences.autoNext, hasNext {
            changeEpisode(by: 1)
        } else {
            didFinish = true
        }
    }

    private func fail(_ error: Error?) {
        isBuffering = false
        errorMessage = error?.localizedDescription ?? "No se pudo reproducir este servidor."
    }

    // MARK: Player observation

    private func observePlayer() {
        let player = self.player
        playerTasks = [
            Task { [weak self] in
                for await status in player.publisher(for: \.timeControlStatus).values {
                    self?.timeControlChanged(status)
                }
            },
            Task { [weak self] in
                for await active in player.publisher(for: \.isExternalPlaybackActive).values {
                    self?.externalPlaybackChanged(active)
                }
            },
        ]
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { () -> Void in
                self?.tick(time.seconds)
            }
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        isPlaying = status != .paused
        isBuffering = status == .waitingToPlayAtSpecifiedRate
        updateNowPlaying()
    }

    private func externalPlaybackChanged(_ active: Bool) {
        isExternalPlayback = active
        externalRouteName = active
            ? AVAudioSession.sharedInstance().currentRoute.outputs.first(where: { $0.portType == .airPlay })?.portName
            : nil
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0, !isChangingEpisode, !closed else { return }
        currentTime = seconds
        let preferences = profile.preferences
        if preferences.autoSkipIntro, let intro = session.playback.intro, intro.contains(seconds) {
            seek(to: intro.end)
            return
        }
        if preferences.autoSkipOutro, let outro = session.playback.outro, outro.contains(seconds) {
            seek(to: outro.end)
            return
        }
        let second = Int(seconds)
        guard second != lastSavedSecond, seconds > 0 else { return }
        lastSavedSecond = second
        profile.update(session.historyEntry, positionSeconds: seconds)
        Task { await profile.sync() }
    }

    private func saveProgress() {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite, seconds > 0, player.currentItem != nil else { return }
        profile.update(session.historyEntry, positionSeconds: seconds)
        Task { await profile.sync(force: true) }
    }

    // MARK: Now Playing and remote commands

    private func updateNowPlaying() {
        guard started, !closed else { return }
        let entry = session.historyEntry
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: entry.episodeLabel,
            MPMediaItemPropertyArtist: entry.seriesTitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed.rawValue) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed.rawValue),
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        addRemoteCommand(center.playCommand) { $0.play() }
        addRemoteCommand(center.pauseCommand) { $0.pause() }
        addRemoteCommand(center.togglePlayPauseCommand) { $0.togglePlayback() }
        addRemoteCommand(center.skipForwardCommand) { $0.skip(by: 10) }
        addRemoteCommand(center.skipBackwardCommand) { $0.skip(by: -10) }
        addRemoteCommand(center.nextTrackCommand) { $0.changeEpisode(by: 1) }
        addRemoteCommand(center.previousTrackCommand) { $0.changeEpisode(by: -1) }
        center.changePlaybackPositionCommand.isEnabled = true
        let target = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            MainActor.assumeIsolated { () -> Void in
                self?.seek(to: position)
            }
            return .success
        }
        remoteCommandTargets.append((center.changePlaybackPositionCommand, target))
    }

    /// Remote commands arrive on the main thread.
    private func addRemoteCommand(_ command: MPRemoteCommand, action: @escaping (PlayerModel) -> Void) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] _ in
            MainActor.assumeIsolated { () -> Void in
                if let self { action(self) }
            }
            return .success
        }
        remoteCommandTargets.append((command, target))
    }

    private func unregisterRemoteCommands() {
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
        remoteCommandTargets = []
    }
}

struct PlayerScreen: View {
    let model: PlayerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    private var entry: WatchHistoryEntry { model.session.historyEntry }
    private var compact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The video always fills the screen; controls float above it and
            // never resize the layer.
            VideoSurface(model: model, gravity: model.videoGravity)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            if model.isExternalPlayback {
                externalPlaybackCard
            }

            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture(perform: toggleControls)
                .gesture(MagnifyGesture().onEnded { value in
                    withAnimation(.easeInOut(duration: 0.25)) {
                        model.videoGravity = value.magnification > 1 ? .resizeAspectFill : .resizeAspect
                    }
                })
                .accessibilityLabel(controlsVisible ? "Ocultar controles" : "Mostrar controles")
                .accessibilityAddTraits(.isButton)

            if (model.isBuffering && model.isPlaying) || model.isChangingEpisode {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .allowsHitTesting(false)
            }

            if controlsVisible {
                controls
                    .transition(.opacity)
            }

            skipButton

            if let message = model.errorMessage {
                errorCard(message)
            }
        }
        .environment(\.colorScheme, .dark)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .onAppear {
            model.start()
            scheduleAutoHide()
        }
        .onDisappear {
            hideTask?.cancel()
            model.close()
        }
        .onChange(of: model.isPlaying) { _, playing in
            if playing { scheduleAutoHide() } else { showControls(autoHide: false) }
        }
        .onChange(of: model.currentTime) { _, time in
            if !scrubbing { scrubValue = time }
        }
        .onChange(of: model.didFinish) { _, finished in
            if finished { showControls(autoHide: false) }
        }
    }

    // MARK: Controls

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.65), .clear, .clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                transport
                Spacer(minLength: 12)
                bottomBar
            }
            .padding(.horizontal, compact ? 16 : 28)
            .padding(.vertical, 12)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: close) {
                GlassIcon(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cerrar")

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.seriesTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(entry.episodeLabel) · \(model.session.kind.displayName)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .shadow(radius: 4)

            Spacer(minLength: 8)

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    if model.canUsePictureInPicture || model.isPictureInPictureActive {
                        Button {
                            model.togglePictureInPicture()
                            bumpControls()
                        } label: {
                            GlassIcon(systemName: model.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Imagen dentro de imagen")
                    }
                    RoutePickerButton()
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .accessibilityLabel("AirPlay")
                }
            }
        }
    }

    private var transport: some View {
        GlassEffectContainer(spacing: compact ? 16 : 28) {
            HStack(spacing: compact ? 16 : 28) {
                Button {
                    model.changeEpisode(by: -1)
                    bumpControls()
                } label: {
                    GlassIcon(systemName: "backward.end.fill", size: compact ? 40 : 48, font: .body)
                }
                .buttonStyle(.plain)
                .disabled(!model.hasPrevious || model.isChangingEpisode)
                .opacity(model.hasPrevious ? 1 : 0.4)
                .accessibilityLabel("Episodio anterior")

                Button {
                    model.skip(by: -10)
                    bumpControls()
                } label: {
                    GlassIcon(systemName: "gobackward.10", size: compact ? 52 : 60, font: .title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retroceder 10 segundos")

                Button {
                    model.togglePlayback()
                    bumpControls()
                } label: {
                    GlassIcon(systemName: model.isPlaying ? "pause.fill" : "play.fill", size: compact ? 68 : 80, font: .largeTitle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.isPlaying ? "Pausar" : "Reproducir")

                Button {
                    model.skip(by: 10)
                    bumpControls()
                } label: {
                    GlassIcon(systemName: "goforward.10", size: compact ? 52 : 60, font: .title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Adelantar 10 segundos")

                Button {
                    model.changeEpisode(by: 1)
                    bumpControls()
                } label: {
                    GlassIcon(systemName: "forward.end.fill", size: compact ? 40 : 48, font: .body)
                }
                .buttonStyle(.plain)
                .disabled(!model.hasNext || model.isChangingEpisode)
                .opacity(model.hasNext ? 1 : 0.4)
                .accessibilityLabel("Siguiente episodio")
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text(formatTime(scrubbing ? scrubValue : model.currentTime))
                Slider(value: $scrubValue, in: 0...max(model.duration, 1), onEditingChanged: { editing in
                    scrubbing = editing
                    if editing {
                        hideTask?.cancel()
                    } else {
                        model.seek(to: scrubValue)
                        scheduleAutoHide()
                    }
                })
                .disabled(model.duration <= 0)
                .accessibilityLabel("Posición")
                Text("-" + formatTime(max(0, model.duration - (scrubbing ? scrubValue : model.currentTime))))
            }
            .font(.footnote.weight(.medium).monospacedDigit())
            .foregroundStyle(.white)

            HStack {
                Spacer()
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        mediaMenu
                        speedMenu
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                model.videoGravity = model.videoGravity == .resizeAspect ? .resizeAspectFill : .resizeAspect
                            }
                            bumpControls()
                        } label: {
                            GlassIcon(systemName: model.videoGravity == .resizeAspect ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.videoGravity == .resizeAspect ? "Llenar pantalla" : "Ajustar a pantalla")
                    }
                }
            }
        }
    }

    private var mediaMenu: some View {
        Menu {
            Section("Subtítulos") {
                Button {
                    model.selectLegible(nil)
                    bumpControls()
                } label: {
                    selectionLabel("Desactivados", selected: model.selectedLegible == nil)
                }
                ForEach(model.legibleOptions, id: \.self) { option in
                    Button {
                        model.selectLegible(option)
                        bumpControls()
                    } label: {
                        selectionLabel(option.displayName, selected: model.selectedLegible == option)
                    }
                }
            }
            if model.audibleOptions.count > 1 {
                Section("Audio") {
                    ForEach(model.audibleOptions, id: \.self) { option in
                        Button {
                            model.selectAudible(option)
                            bumpControls()
                        } label: {
                            selectionLabel(option.displayName, selected: model.selectedAudible == option)
                        }
                    }
                }
            }
        } label: {
            GlassIcon(systemName: model.selectedLegible == nil ? "captions.bubble" : "captions.bubble.fill")
        }
        .disabled(model.legibleOptions.isEmpty && model.audibleOptions.count < 2)
        .accessibilityLabel("Subtítulos y audio")
    }

    private var speedMenu: some View {
        Menu {
            Section("Velocidad") {
                ForEach(PlaybackSpeed.allCases) { speed in
                    Button {
                        model.setSpeed(speed)
                        bumpControls()
                    } label: {
                        selectionLabel(speed.label, selected: model.speed == speed)
                    }
                }
            }
        } label: {
            GlassIcon(systemName: "gauge.with.dots.needle.67percent")
        }
        .accessibilityLabel("Velocidad de reproducción")
    }

    @ViewBuilder
    private func selectionLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private var skipButton: some View {
        if let skip = model.activeSkip {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        model.seek(to: skip.end)
                        bumpControls()
                    } label: {
                        Label(skip.title, systemImage: "forward.fill")
                            .font(.headline)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, compact ? 16 : 28)
            .padding(.bottom, controlsVisible ? 128 : 28)
            .animation(.easeInOut(duration: 0.2), value: controlsVisible)
            .transition(.opacity)
        }
    }

    private var externalPlaybackCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "airplayvideo")
                .font(.system(size: 56, weight: .regular))
            Text("Reproduciendo en \(model.externalRouteName ?? "AirPlay")")
                .font(.title3.weight(.semibold))
            Text("Controla la reproducción desde aquí o con el control del TV.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding(32)
        .allowsHitTesting(false)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Cerrar reproductor", action: close)
                    .buttonStyle(.glass)
                Button("Continuar") { model.dismissError() }
                    .buttonStyle(.glassProminent)
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(32)
    }

    // MARK: Visibility

    private func close() {
        hideTask?.cancel()
        model.close()
        dismiss()
    }

    private func toggleControls() {
        if controlsVisible {
            hideTask?.cancel()
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
        } else {
            showControls(autoHide: true)
        }
    }

    private func bumpControls() {
        showControls(autoHide: true)
    }

    private func showControls(autoHide: Bool) {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        }
        if autoHide { scheduleAutoHide() } else { hideTask?.cancel() }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard model.isPlaying, !scrubbing else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, model.isPlaying, !scrubbing else { return }
            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
        }
    }
}

/// UIView backed by an AVPlayerLayer, which also renders the selected subtitles.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct VideoSurface: UIViewRepresentable {
    let model: PlayerModel
    let gravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.player = model.player
        view.playerLayer.videoGravity = gravity
        model.attach(view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.videoGravity != gravity {
            view.playerLayer.videoGravity = gravity
        }
    }
}

private struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = true
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}
