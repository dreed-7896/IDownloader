//
//  VLCPlayerViewController.swift
//  IDownloader
//
//  Created by Даниил Виноградов on 21.03.2026.
//

import Combine
import MvvmFoundation
import SwiftUI
import UIKit
import AVKit
import MediaPlayer
import SwiftVLC

struct PlaybackRateMenuView: View {
    let rates: [Float]
    @Binding var selectedRate: Float

    var body: some View {
        Menu {
            Section {
                ForEach(rates, id: \.self) { rate in
                    Toggle(rate.formattedRate, isOn: .init(get: {
                        selectedRate == rate
                    }, set: { value in
                        guard value else { return }
                        selectedRate = rate
                    }))
                }
            } header: {
                Text("Playback Speed")
            }
        } label: {
            Image(systemName: "speedometer")
        }
        .menuOrder(.fixed)
        .labelStyle(.iconOnly)
        .imageScale(.medium)
        .accessibilityLabel("Playback Speed")
    }
}

private extension Float {
    var formattedRate: String {
        if self == floor(self) {
            return "\(Int(self))x"
        }

        return String(format: "%.2gx", self)
    }
}

class VLCPlayerViewController: BaseHostingController<VLCPlayerViewController.Body>, MvvmViewControllerProtocol {
    var viewModel: VLCPlayerViewModel
    private var disposeBag = DisposeBag() // [AnyCancellable] = []
    private let volumeView = MPVolumeView(frame: CGRect(x: -200, y: -200, width: 160, height: 40))
    private var originalBrightness: CGFloat?
    private var originalIdleTimerDisabled = false
    private var originalOrientation: UIInterfaceOrientation = .portrait

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        viewModel.isLandscape ? .landscape : .portrait
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        viewModel.isLandscape ? .landscapeRight : .portrait
    }

    override var useMarqueeLabel: Bool { true }

    required init(viewModel: VLCPlayerViewModel) {
        self.viewModel = viewModel
        super.init(rootView: Body(viewModel: viewModel))
    }

    @available(*, unavailable)
    @MainActor @preconcurrency dynamic required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = viewModel.url.lastPathComponent
        navigationItem.largeTitleDisplayMode = .never
        overrideUserInterfaceStyle = .dark

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}

        navigationItem.rightBarButtonItem = .init(systemItem: .close, primaryAction: .init { [unowned self] _ in
            dismiss()
        })

        volumeView.alpha = 0.01
        view.addSubview(volumeView)
        disposeBag.bind {
            viewModel.$showOverlay.sink { [weak self] _ in
                self?.navigationController?.setNavigationBarHidden(true, animated: false)
            }
            viewModel.$url.sink { [weak self] url in self?.title = url?.lastPathComponent }
            viewModel.$isLandscape.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.rotatePlayer() }
            viewModel.closeSignal.sink { [weak self] _ in self?.dismiss(animated: true) }
            viewModel.volumeSignal.sink { [weak self] volume in
                guard let slider = self?.volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
                slider.setValue(volume, animated: false)
                slider.sendActions(for: .valueChanged)
                slider.sendActions(for: .touchUpInside)
            }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        navigationController?.setToolbarHidden(true, animated: false)
        originalBrightness = view.window?.windowScene?.screen.brightness ?? UIScreen.main.brightness
        originalOrientation = presentingViewController?.view.window?.windowScene?.interfaceOrientation
            ?? navigationController?.presentingViewController?.view.window?.windowScene?.interfaceOrientation ?? .portrait
        originalIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        rotatePlayer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let insets = view.window?.safeAreaInsets ?? .zero
        guard viewModel.playerSafeAreaInsets != insets else { return }
        // Publish outside UIKit's layout pass to avoid invalidating SwiftUI mid-layout.
        DispatchQueue.main.async { [weak self] in
            self?.viewModel.playerSafeAreaInsets = insets
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let originalBrightness { UIScreen.main.brightness = originalBrightness }
        UIApplication.shared.isIdleTimerDisabled = originalIdleTimerDisabled
        #if !os(visionOS)
        if let scene = presentingViewController?.view.window?.windowScene ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let orientation: UIInterfaceOrientationMask = originalOrientation.isLandscape ? .landscape : .portrait
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
        }
        #endif
    }

    private func rotatePlayer() {
        #if !os(visionOS)
        setNeedsUpdateOfSupportedInterfaceOrientations()
        navigationController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: supportedInterfaceOrientations))
        #endif
    }

    struct Body: View {
        @ObservedObject var viewModel: VLCPlayerViewModel
        var body: some View { VLCPlayerView(viewModel: viewModel).environment(\.colorScheme, .dark) }
    }

    struct VLCPlayerView: View {
        @ObservedObject var viewModel: VLCPlayerViewModel
        @State private var player = Player()
        @State private var currentPlaybackTime: TimeInterval = 0
        @State private var mediaTimeDuration: TimeInterval = 0
        @State private var isSeeking: Bool = false
        @State private var swipeSeekStart: TimeInterval?
        @State private var swipeSeekOffset: TimeInterval = 0
        @State private var isHoldingDoubleSpeed = false
        @State private var isMuted = false
        @State private var verticalStartValue: CGFloat = 0
        @State private var gestureHUD: String?
        @State private var gestureHUDIcon = "sun.max.fill"
        @State private var wasPlayingBeforeBackground = false
        @State private var playbackError: String?
        @State private var fitMode: VideoFitMode = .fullWidth
        @State private var subtitlesDisabled = false
        @State private var preferredSubtitleLanguage: String?
        @State private var controlRegions: [CGRect] = []
        @State private var playbackRate: Float = 1
        @State private var didStartPlayback = false
        @State private var isRestoringPlayback = false
        @State private var pendingPausedSeekRefreshTime: TimeInterval?
        @State private var remoteCommands = RemoteCommandController()
        @Namespace private var glassNamespace
        private let playbackRates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
        private let nowPlayingCenter = MPNowPlayingInfoCenter.default()

        var body: some View {
            WithPerceptionTracking {
                content
            }
            .task(id: viewModel.url) {
                await preparePlaybackIfNeeded()
            }
            .task {
                await observePlayerEvents()
            }
            .onAppear {
                configureRemoteCommandCenter()
                viewModel.registerPlaybackTeardownHandler {
                    tearDownPlayback(force: true)
                }
            }
            .onDisappear {
                tearDownPlayback()
            }
            .onChange(of: playbackRate) { newRate in
                setPlaybackRate(isHoldingDoubleSpeed ? 2 : newRate)
            }
            .onChange(of: isMuted) { player.isMuted = $0 }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                restorePlaybackAfterForeground()
            }
            .onReceive(NotificationCenter.default.publisher(for: .appDidUnlock)) { _ in
                restorePlaybackAfterForeground()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                wasPlayingBeforeBackground = wasPlayingBeforeBackground || player.isPlaying
                resetGestures()
                player.pause()
                updateNowPlayingPlaybackState()
            }
            .alert("Unable to play video", isPresented: Binding(get: { playbackError != nil }, set: { if !$0 { playbackError = nil } })) {
                Button("Close") { viewModel.closeSignal.send() }
                if viewModel.hasNext { Button("Next video") { viewModel.moveInPlaylist(by: 1) } }
            } message: {
                Text(playbackError ?? "")
            }
        }
    }
}

private enum VideoFitMode: Int, CaseIterable {
    case fullWidth, safeWidth, fullHeight

    var title: String {
        switch self {
        case .fullWidth: return "Full width"
        case .safeWidth: return "Safe width"
        case .fullHeight: return "Full height"
        }
    }

    var next: VideoFitMode {
        Self(rawValue: (rawValue + 1) % Self.allCases.count) ?? .fullWidth
    }
}

// MARK: - Overlay State
private extension VLCPlayerViewController.VLCPlayerView {
    var showOverlay: Bool { viewModel.showOverlay }

    var showsPlayingState: Bool {
        isRestoringPlayback ? false : player.isPlaying
    }
}

// MARK: - Layout
private extension VLCPlayerViewController.VLCPlayerView {
    var content: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                videoOutput(in: geometry.size)
                gestureSurface
                if showOverlay {
                    LinearGradient(colors: [.black.opacity(0.6), .clear, .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                    overlayHeader
                        .playerControlArea()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    CompatibilityGlassContainer(spacing: 24) { overlayButtons.playerControlArea() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    bottomControls
                        .playerControlArea()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                gestureIndicators
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "playerSurface")
            .onPreferenceChange(PlayerControlAreaKey.self) { controlRegions = $0 }
            .clipped()
        }
        .ignoresSafeArea()
    }

    var gestureSurface: some View {
        PlayerGestureSurface(
            protectedRegions: showOverlay ? controlRegions : [],
            onTap: {
                withAnimation(.easeInOut(duration: 0.2)) { viewModel.showOverlay.toggle() }
            },
            onSeekBegan: beginSwipeSeek,
            onSeekChanged: updateSwipeSeek,
            onSeekEnded: endSwipeSeek,
            onHoldChanged: setHoldingDoubleSpeed,
            onVerticalBegan: beginVerticalGesture,
            onVerticalChanged: updateVerticalGesture,
            onVerticalEnded: endVerticalGesture,
            onClose: { viewModel.closeSignal.send() }
        )
    }

    var overlayHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                if viewModel.playlist.count > 1 {
                    Text("\(viewModel.playlistIndex + 1) of \(viewModel.playlist.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer(minLength: 12)
            Button { viewModel.closeSignal.send() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close video")
            .compatibilityGlassEffect(isClear: true, interactive: true)
        }
        .foregroundStyle(.white)
        .padding(.leading, viewModel.playerSafeAreaInsets.left + 20)
        .padding(.trailing, viewModel.playerSafeAreaInsets.right + 20)
        .padding(.top, viewModel.playerSafeAreaInsets.top + 12)
    }

    var bottomControls: some View {
        CompatibilityGlassContainer(spacing: 12) {
            VStack(spacing: 10) {
                controlsBar
                TimelineView(
                    mediaLengthTime: mediaTimeDuration,
                    currentPlaybackTime: $currentPlaybackTime,
                    isSeeking: $isSeeking,
                    availability: viewModel.segmentedProgress,
                    onScrubChanged: { seek(to: $0, fast: true) },
                    onScrubEnded: { seek(to: $0, fast: false) }
                )
                .compatibilityGlassID("timeline", in: glassNamespace)
            }
        }
        .padding(.leading, viewModel.playerSafeAreaInsets.left + 16)
        .padding(.trailing, viewModel.playerSafeAreaInsets.right + 16)
        .padding(.bottom, viewModel.playerSafeAreaInsets.bottom + 10)
    }

    var gestureIndicators: some View {
        ZStack {
            if swipeSeekStart != nil {
                VStack(spacing: 8) {
                    Label("\(swipeSeekOffset >= 0 ? "+" : "−")\(Int(abs(swipeSeekOffset)))s", systemImage: swipeSeekOffset >= 0 ? "goforward" : "gobackward")
                        .font(.title2.weight(.semibold))
                    Text(playbackTimeLabel(currentPlaybackTime)).font(.headline.monospacedDigit())
                }
                .padding(24)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
            }
            if isHoldingDoubleSpeed {
                Label("2× Speed", systemImage: "forward.fill")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(.top, viewModel.playerSafeAreaInsets.top + 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            if let gestureHUD {
                Label(gestureHUD, systemImage: gestureHUDIcon)
                    .font(.headline.monospacedDigit())
                    .padding(20)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
    }

    var controlsBar: some View {
        HStack(spacing: 10) {
            PlaybackRateMenuView(rates: playbackRates, selectedRate: $playbackRate)
                .frame(width: 44, height: 44)
                .compatibilityGlassEffect(isClear: true, interactive: true)
            Button { isMuted.toggle() } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(isMuted ? "Unmute" : "Mute")
            .compatibilityGlassEffect(isClear: true, interactive: true)
            subtitleControl
            Spacer(minLength: 0)
            Button { fitMode = fitMode.next } label: {
                ViewThatFits(in: .horizontal) {
                    Label(fitMode.title, systemImage: "aspectratio")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize()
                        .padding(.horizontal, 12)
                    Image(systemName: "aspectratio").frame(width: 44)
                }
                .frame(height: 44)
            }
            .accessibilityLabel("Video fit: \(fitMode.title). Tap for \(fitMode.next.title).")
            .compatibilityGlassEffect(isClear: true, interactive: true)
            Button { viewModel.isLandscape.toggle() } label: {
                Image(systemName: "rotate.right").frame(width: 44, height: 44)
            }
            .accessibilityLabel(viewModel.isLandscape ? "Rotate to portrait" : "Rotate to landscape")
            .compatibilityGlassEffect(isClear: true, interactive: true)
        }
        .tint(.white)
        .font(.title3.weight(.medium))
    }

    var subtitleControl: some View {
        Menu {
            Toggle("Off", isOn: Binding(get: { player.selectedSubtitleTrack == nil }, set: { enabled in
                guard enabled else { return }
                subtitlesDisabled = true
                preferredSubtitleLanguage = nil
                player.selectedSubtitleTrack = nil
            }))
            if player.subtitleTracks.isEmpty {
                Text("No subtitles available")
            } else {
                ForEach(player.subtitleTracks) { track in
                    Toggle(subtitleTitle(track), isOn: Binding(get: { player.selectedSubtitleTrack?.id == track.id }, set: { enabled in
                        guard enabled else { return }
                        subtitlesDisabled = false
                        preferredSubtitleLanguage = track.language
                        player.selectedSubtitleTrack = track
                    }))
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Subtitles")
        .compatibilityGlassEffect(isClear: true, interactive: true)
    }

    var overlayButtons: some View {
        HStack(spacing: 32) {
            PlayerButton(size: .small, imageName: "backward.end.fill") {
                viewModel.moveInPlaylist(by: -1)
            }
            .disabled(!viewModel.hasPrevious)
            .opacity(viewModel.hasPrevious ? 1 : 0.35)
            .accessibilityLabel("Previous video")
            .compatibilityGlassID("previous", in: glassNamespace)

            PlayerButton(size: .big, imageName: showsPlayingState ? "pause.fill" : "play.fill") {
                guard !isRestoringPlayback else { return }
                togglePlayback()
            }
            .accessibilityLabel(showsPlayingState ? "Pause" : "Play")
            .compatibilityGlassID("playPause", in: glassNamespace)

            PlayerButton(size: .small, imageName: "forward.end.fill") {
                viewModel.moveInPlaylist(by: 1)
            }
            .disabled(!viewModel.hasNext)
            .opacity(viewModel.hasNext ? 1 : 0.35)
            .accessibilityLabel("Next video")
            .compatibilityGlassID("next", in: glassNamespace)
        }
    }
}

// MARK: - Video Fit and Subtitles
private extension VLCPlayerViewController.VLCPlayerView {
    var videoAspect: CGFloat {
        if let size = player.videoSize, size.width > 0, size.height > 0 {
            return size.width / size.height
        }
        if let track = player.videoTracks.first, let width = track.width, let height = track.height, width > 0, height > 0 {
            return CGFloat(width) / CGFloat(height)
        }
        return 16 / 9
    }

    func videoOutput(in screen: CGSize) -> some View {
        let insets = viewModel.playerSafeAreaInsets
        let safe = fitMode == .safeWidth
        let width = max(1, screen.width - (safe ? insets.left + insets.right : 0))
        let height = max(1, screen.height - (safe ? insets.top + insets.bottom : 0))
        let videoWidth = fitMode == .fullHeight ? height * videoAspect : width
        let videoHeight = fitMode == .fullHeight ? height : width / videoAspect
        return VideoView(player)
            .frame(width: videoWidth, height: videoHeight)
            .frame(width: width, height: height, alignment: .center)
            .clipped()
            .position(x: (safe ? insets.left : 0) + width / 2, y: (safe ? insets.top : 0) + height / 2)
    }

    func subtitleTitle(_ track: Track) -> String {
        let name = track.trackDescription ?? track.name
        guard let language = track.language,
              let title = Locale.current.localizedString(forLanguageCode: language),
              !name.localizedCaseInsensitiveContains(title) else { return name }
        return "\(name) · \(title)"
    }

    func applySubtitlePreference() {
        if subtitlesDisabled {
            if player.selectedSubtitleTrack != nil { player.selectedSubtitleTrack = nil }
        } else if let language = preferredSubtitleLanguage,
                  player.selectedSubtitleTrack?.language != language,
                  let track = player.subtitleTracks.first(where: { $0.language == language }) {
            player.selectedSubtitleTrack = track
        }
    }
}

// MARK: - Playback Lifecycle
private extension VLCPlayerViewController.VLCPlayerView {
    func preparePlaybackIfNeeded() async {
        resetGestures()
        didStartPlayback = false
        await player.stopAndWait()
        currentPlaybackTime = 0
        mediaTimeDuration = 0
        pendingPausedSeekRefreshTime = nil
        playbackError = nil
        let url = viewModel.url!
        configureNowPlayingMetadata()

        do {
            let media = try Media(url: url)
            if let metadata = try? await media.parse(timeout: .seconds(1)), let duration = metadata.duration {
                updateMediaTimeDuration(duration.timeInterval)
                updateNowPlaying(duration: duration.timeInterval)
            }
            try Task.checkCancellation()
            guard viewModel.url == url else { return }
            try player.play(media)
            didStartPlayback = true
            player.isMuted = isMuted
            setPlaybackRate(playbackRate)
            applySubtitlePreference()
            updateNowPlayingPlaybackState()
        } catch is CancellationError {
            if viewModel.url == url { player.stop() }
        } catch {
            guard viewModel.url == url else { return }
            didStartPlayback = false
            playbackError = error.localizedDescription
        }
    }

    func observePlayerEvents() async {
        for await event in player.events {
            switch event {
            case .timeChanged(let time):
                guard !isSeeking else { continue }
                let newPlaybackTime = max(time.timeInterval, 0)
                if abs(currentPlaybackTime - newPlaybackTime) > 0.05 {
                    currentPlaybackTime = newPlaybackTime
                }
                updateNowPlaying()
            case .lengthChanged(let duration):
                updateMediaTimeDuration(duration.timeInterval)
                updateNowPlaying(duration: duration.timeInterval)
            case .tracksChanged, .mediaChanged:
                applySubtitlePreference()
            case .stateChanged:
                applySubtitlePreference()
                updateNowPlayingPlaybackState()
            case .encounteredError:
                playbackError = "This file could not be played. It may be incomplete or use an unsupported format."
                updateNowPlayingPlaybackState()
            case .endReached:
                currentPlaybackTime = mediaTimeDuration
                updateNowPlayingPlaybackState()
                if viewModel.hasNext { viewModel.moveInPlaylist(by: 1) }
            default:
                break
            }
        }
    }

    func tearDownPlayback(force: Bool = false) {
        resetGestures()
        player.stop()
        remoteCommands.tearDown()
        viewModel.clearPlaybackTeardownHandler()
    }

    private func updateMediaTimeDuration(_ duration: TimeInterval) {
        guard mediaTimeDuration != duration else { return }
        mediaTimeDuration = duration
    }
}

// MARK: - Playback Gestures
private extension VLCPlayerViewController.VLCPlayerView {
    func beginSwipeSeek() {
        guard !isRestoringPlayback, mediaTimeDuration > 0,
              player.isSeekable || player.duration != nil else { return }
        setHoldingDoubleSpeed(false)
        swipeSeekStart = currentPlaybackTime
        swipeSeekOffset = 0
        isSeeking = true
    }

    func updateSwipeSeek(translation: CGFloat, width: CGFloat) {
        guard let start = swipeSeekStart, width > 0 else { return }
        // A full-width swipe seeks up to two minutes; short clips use their full duration.
        let time = min(max(start + Double(translation / width) * min(mediaTimeDuration, 120), 0), mediaTimeDuration)
        swipeSeekOffset = time - start
        seek(to: time, fast: true)
    }

    func endSwipeSeek() {
        guard swipeSeekStart != nil else { return }
        let time = currentPlaybackTime
        swipeSeekStart = nil
        swipeSeekOffset = 0
        isSeeking = false
        seek(to: time)
    }

    func setHoldingDoubleSpeed(_ holding: Bool) {
        if holding {
            guard player.isPlaying, !isSeeking, !isRestoringPlayback else { return }
            isHoldingDoubleSpeed = true
            setPlaybackRate(2)
        } else if isHoldingDoubleSpeed {
            isHoldingDoubleSpeed = false
            setPlaybackRate(playbackRate)
        }
    }

    func resetGestures() {
        endSwipeSeek()
        setHoldingDoubleSpeed(false)
        gestureHUD = nil
    }

    func beginVerticalGesture(isLeft: Bool) {
        setHoldingDoubleSpeed(false)
        verticalStartValue = isLeft ? UIScreen.main.brightness : CGFloat(AVAudioSession.sharedInstance().outputVolume)
        gestureHUDIcon = isLeft ? "sun.max.fill" : (isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
    }

    func updateVerticalGesture(isLeft: Bool, translation: CGFloat, height: CGFloat) {
        let value = min(max(verticalStartValue - translation / max(height, 1) * 1.5, 0), 1)
        if isLeft {
            UIScreen.main.brightness = value
            gestureHUD = "Brightness \(Int(value * 100))%"
        } else if isMuted {
            gestureHUD = "Muted"
        } else {
            viewModel.volumeSignal.send(Float(value))
            gestureHUD = "Volume \(Int(value * 100))%"
        }
    }

    func endVerticalGesture() { gestureHUD = nil }

    func playbackTimeLabel(_ time: TimeInterval) -> String {
        let seconds = max(0, Int(time))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct PlayerControlAreaKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

private extension View {
    func playerControlArea() -> some View {
        background {
            GeometryReader { geometry in
                Color.clear
                    .preference(key: PlayerControlAreaKey.self, value: [geometry.frame(in: .named("playerSurface"))])
                    .allowsHitTesting(false)
            }
        }
    }
}

/// UIKit reports release and cancellation reliably, so temporary 2× never sticks.
private struct PlayerGestureSurface: UIViewRepresentable {
    let protectedRegions: [CGRect]
    let onTap: () -> Void
    let onSeekBegan: () -> Void
    let onSeekChanged: (CGFloat, CGFloat) -> Void
    let onSeekEnded: () -> Void
    let onHoldChanged: (Bool) -> Void
    let onVerticalBegan: (Bool) -> Void
    let onVerticalChanged: (Bool, CGFloat, CGFloat) -> Void
    let onVerticalEnded: () -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.15
        hold.allowableMovement = 8
        hold.delegate = context.coordinator
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        pan.require(toFail: hold)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.delegate = context.coordinator
        tap.require(toFail: pan)
        tap.require(toFail: hold)
        view.addGestureRecognizer(hold)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.surface = self }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.surface.onSeekEnded()
        coordinator.surface.onHoldChanged(false)
        coordinator.surface.onVerticalEnded()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var surface: PlayerGestureSurface
        private enum Mode { case seek, brightness, volume, close }
        private var mode: Mode?
        init(_ surface: PlayerGestureSurface) { self.surface = surface }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            let point = touch.location(in: gestureRecognizer.view)
            return !surface.protectedRegions.contains { $0.contains(point) }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) + abs(velocity.y) > 0
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended { surface.onTap() }
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                let velocity = gesture.velocity(in: gesture.view)
                if abs(velocity.x) > abs(velocity.y) {
                    mode = .seek
                    surface.onSeekBegan()
                } else {
                    let position = gesture.location(in: gesture.view)
                    let translation = gesture.translation(in: gesture.view)
                    let fraction = (position.x - translation.x) / max(gesture.view?.bounds.width ?? 1, 1)
                    mode = fraction < 0.35 ? .brightness : (fraction > 0.65 ? .volume : .close)
                    if mode == .brightness || mode == .volume { surface.onVerticalBegan(mode == .brightness) }
                }
                updatePan(gesture)
            case .changed:
                updatePan(gesture)
            case .ended, .cancelled, .failed:
                if mode == .seek { surface.onSeekEnded() }
                if mode == .brightness || mode == .volume { surface.onVerticalEnded() }
                if mode == .close, gesture.state == .ended {
                    let distance = gesture.translation(in: gesture.view).y
                    if distance > 100 || (distance > 50 && gesture.velocity(in: gesture.view).y > 700) { surface.onClose() }
                }
                mode = nil
            default: break
            }
        }

        private func updatePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)
            switch mode {
            case .seek:
                surface.onSeekChanged(translation.x, gesture.view?.bounds.width ?? 0)
            case .brightness, .volume:
                surface.onVerticalChanged(mode == .brightness, translation.y, gesture.view?.bounds.height ?? 0)
            default: break
            }
        }

        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            switch gesture.state {
            case .began: surface.onHoldChanged(true)
            case .ended, .cancelled, .failed: surface.onHoldChanged(false)
            default: break
            }
        }
    }
}

// MARK: - Remote Commands
private extension VLCPlayerViewController.VLCPlayerView {
    func configureRemoteCommandCenter() {
        remoteCommands.configure(
            supportedPlaybackRates: playbackRates,
            play: {
                guard !AppLockController.isAnySceneLocked else { return }
                try? player.play()
                refreshVideoAfterPausedSeekIfNeeded()
                updateNowPlayingPlaybackState()
            },
            pause: {
                player.pause()
                updateNowPlayingPlaybackState()
            },
            toggle: {
                guard !AppLockController.isAnySceneLocked else { return }
                togglePlayback()
            },
            seek: { time in
                seek(to: time)
            },
            skip: { interval in
                skip(by: interval)
            },
            rate: { rate in
                playbackRate = rate
                setPlaybackRate(rate)
            }
        )
    }
}

// MARK: - Transport Controls
private extension VLCPlayerViewController.VLCPlayerView {
    func setPlaybackRate(_ rate: Float) {
        try? player.setPlaybackRate(PlaybackRate(rate))
        updateNowPlayingPlaybackState()
    }

    func togglePlayback() {
        player.togglePlayPause()
        refreshVideoAfterPausedSeekIfNeeded()
        updateNowPlayingPlaybackState()
    }

    func refreshVideoAfterPausedSeekIfNeeded() {
        guard let time = pendingPausedSeekRefreshTime else { return }

        Task { @MainActor in
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(80))
                guard pendingPausedSeekRefreshTime == time else { return }
                guard player.isPlaying else { continue }
                pendingPausedSeekRefreshTime = nil
                seek(to: time)
                return
            }
        }
    }

    func seek(to time: TimeInterval, fast: Bool = false) {
        let duration = max(mediaTimeDuration, 0)
        let clampedTime = min(max(time, 0), duration)
        let wasPlaying = player.isPlaying
        currentPlaybackTime = clampedTime

        guard player.isSeekable || player.duration != nil else {
            updateNowPlaying()
            return
        }

        try? player.seek(to: .milliseconds(Int64((clampedTime * 1_000).rounded())), fast: fast)
        if wasPlaying {
            pendingPausedSeekRefreshTime = nil
        } else if !fast {
            pendingPausedSeekRefreshTime = clampedTime
        }
        updateNowPlaying()
    }

    func skip(by interval: TimeInterval) {
        seek(to: currentPlaybackTime + interval)
    }
}

// MARK: - Foreground Restore
private extension VLCPlayerViewController.VLCPlayerView {
    func restorePlaybackAfterForeground() {
        guard didStartPlayback, !isRestoringPlayback, wasPlayingBeforeBackground else { return }
        guard !AppLockController.isAnySceneLocked else { return }
        wasPlayingBeforeBackground = false
        try? player.play()
        player.isMuted = isMuted
        setPlaybackRate(playbackRate)
        refreshVideoAfterPausedSeekIfNeeded()
        updateNowPlayingPlaybackState()
    }

}

// MARK: - Now Playing
private extension VLCPlayerViewController.VLCPlayerView {
    func configureNowPlayingMetadata() {
        var info = nowPlayingCenter.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = viewModel.url.deletingPathExtension().lastPathComponent
        info[MPMediaItemPropertyPlaybackDuration] = max(mediaTimeDuration, 0)
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue

        let artworkImage = UIImage.icon(forFileURL: viewModel.url, size: 512)
        info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in artworkImage }

        nowPlayingCenter.nowPlayingInfo = info
        updateNowPlayingPlaybackState()
    }

    func updateNowPlaying(duration: TimeInterval? = nil) {
        var info = nowPlayingCenter.nowPlayingInfo ?? [:]
        if let duration {
            info[MPMediaItemPropertyPlaybackDuration] = max(duration, 0)
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(currentPlaybackTime, 0)
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isPlaying ? Double(isHoldingDoubleSpeed ? 2 : playbackRate) : 0
        nowPlayingCenter.nowPlayingInfo = info
    }

    func updateNowPlayingPlaybackState() {
        nowPlayingCenter.playbackState = player.isPlaying ? .playing : .paused
        updateNowPlaying()
    }
}

// MARK: - Player Button
private extension VLCPlayerViewController.VLCPlayerView {
    struct PlayerButton: View {
        enum Size {
            case small
            case big

            var view: Double {
                switch self {
                case .small:
                    52
                case .big:
                    76
                }
            }

            var font: Double {
                switch self {
                case .small:
                    24
                case .big:
                    34
                }
            }
        }

        var size: Size
        var imageName: String
        var action: () -> Void

        var body: some View {
            let button = Button {
                action()
            } label: {
                let image = Image(systemName: imageName)
                    .frame(width: size.view, height: size.view)
                    .font(.system(size: size.font, weight: .medium))
                    .foregroundStyle(Color.white)
                    .contentShape(Rectangle())

                if #available(iOS 17.0, *) {
                    image.contentTransition(.symbolEffect(.replace.downUp, options: .speed(3)))
                } else {
                    image
                }
            }

            button
                .buttonStyle(.plain)
                .compatibilityGlassEffect(isClear: true, interactive: true)
                .compatibilityGlassTransition()
        }
    }
}

private final class RemoteCommandController {
    private var remoteCommandTargets: [Any] = []
    private let remoteCommandCenter = MPRemoteCommandCenter.shared()
    private let nowPlayingCenter = MPNowPlayingInfoCenter.default()

    func configure(
        supportedPlaybackRates: [Float],
        play: @escaping @MainActor @Sendable () -> Void,
        pause: @escaping @MainActor @Sendable () -> Void,
        toggle: @escaping @MainActor @Sendable () -> Void,
        seek: @escaping @MainActor @Sendable (TimeInterval) -> Void,
        skip: @escaping @MainActor @Sendable (TimeInterval) -> Void,
        rate: @escaping @MainActor @Sendable (Float) -> Void
    ) {
        guard remoteCommandTargets.isEmpty else { return }

        let playTarget = remoteCommandCenter.playCommand.addTarget { _ in
            Self.perform(play)
        }
        let pauseTarget = remoteCommandCenter.pauseCommand.addTarget { _ in
            Self.perform(pause)
        }
        let toggleTarget = remoteCommandCenter.togglePlayPauseCommand.addTarget { _ in
            Self.perform(toggle)
        }
        let seekTarget = remoteCommandCenter.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let positionTime = event.positionTime
            return Self.perform { seek(positionTime) }
        }
        let skipForwardTarget = remoteCommandCenter.skipForwardCommand.addTarget { _ in
            Self.perform { skip(10) }
        }
        let skipBackwardTarget = remoteCommandCenter.skipBackwardCommand.addTarget { _ in
            Self.perform { skip(-10) }
        }
        let rateTarget = remoteCommandCenter.changePlaybackRateCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let playbackRate = Float(event.playbackRate)
            return Self.perform { rate(playbackRate) }
        }

        remoteCommandTargets = [playTarget, pauseTarget, toggleTarget, seekTarget, skipForwardTarget, skipBackwardTarget, rateTarget]
        remoteCommandCenter.playCommand.isEnabled = true
        remoteCommandCenter.pauseCommand.isEnabled = true
        remoteCommandCenter.togglePlayPauseCommand.isEnabled = true
        remoteCommandCenter.changePlaybackPositionCommand.isEnabled = true
        remoteCommandCenter.skipForwardCommand.isEnabled = true
        remoteCommandCenter.skipForwardCommand.preferredIntervals = [10]
        remoteCommandCenter.skipBackwardCommand.isEnabled = true
        remoteCommandCenter.skipBackwardCommand.preferredIntervals = [10]
        remoteCommandCenter.changePlaybackRateCommand.isEnabled = true
        remoteCommandCenter.changePlaybackRateCommand.supportedPlaybackRates = supportedPlaybackRates.map(NSNumber.init(value:))
    }

    func tearDown() {
        remoteCommandTargets.forEach { target in
            remoteCommandCenter.playCommand.removeTarget(target)
            remoteCommandCenter.pauseCommand.removeTarget(target)
            remoteCommandCenter.togglePlayPauseCommand.removeTarget(target)
            remoteCommandCenter.changePlaybackPositionCommand.removeTarget(target)
            remoteCommandCenter.skipForwardCommand.removeTarget(target)
            remoteCommandCenter.skipBackwardCommand.removeTarget(target)
            remoteCommandCenter.changePlaybackRateCommand.removeTarget(target)
        }
        remoteCommandTargets.removeAll()
        nowPlayingCenter.nowPlayingInfo = nil
        nowPlayingCenter.playbackState = .stopped
    }

    private static func perform(_ action: @escaping @MainActor @Sendable () -> Void) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor in
            action()
        }
        return .success
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        TimeInterval(milliseconds) / 1_000
    }
}

#Preview {
    UINavigationController(rootViewController: VLCPlayerViewController(viewModel: .init(with: .init(url: URL(string: "ttest.com")!, torrentPair: nil))))
        .asView
        .ignoresSafeArea()
}
