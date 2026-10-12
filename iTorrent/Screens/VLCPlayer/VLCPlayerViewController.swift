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
            viewModel.$showOverlay.sink { [weak self] show in
                self?.navigationController?.setNavigationBarHidden(!show, animated: true)
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
        var body: some View { VLCPlayerView(viewModel: viewModel) }
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
        ZStack(alignment: .bottom) {
            Color(showOverlay ? .systemGroupedBackground : .black)
                .ignoresSafeArea()

            videoOutput
                .ignoresSafeArea()

            if showOverlay {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
            }

            PlayerGestureSurface(
                onTap: {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        viewModel.showOverlay.toggle()
                    }
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
                .ignoresSafeArea()

            ZStack {
                CompatibilityGlassContainer(spacing: 24) {
                    VStack {
                        if showOverlay {
                            overlayButtons
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .ignoresSafeArea()

                CompatibilityGlassContainer(spacing: 16) {
                    if showOverlay {
                        VStack(alignment: .trailing, spacing: 16) {
                            controlsBar

                            TimelineView(
                                mediaLengthTime: mediaTimeDuration,
                                currentPlaybackTime: $currentPlaybackTime,
                                isSeeking: $isSeeking,
                                availability: viewModel.segmentedProgress,
                                onScrubChanged: { time in
                                    seek(to: time, fast: true)
                                },
                                onScrubEnded: { time in
                                    seek(to: time, fast: false)
                                }
                            )
                            .compatibilityGlassID("timeline", in: glassNamespace)
                            .compatibilityGlassTransition()
                        }
                        .padding()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }

            if swipeSeekStart != nil {
                VStack(spacing: 8) {
                    Label("\(swipeSeekOffset >= 0 ? "+" : "−")\(Int(abs(swipeSeekOffset)))s",
                          systemImage: swipeSeekOffset >= 0 ? "goforward" : "gobackward")
                        .font(.title2.weight(.semibold))
                    Text(playbackTimeLabel(currentPlaybackTime))
                        .font(.headline.monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(24)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
            }

            if isHoldingDoubleSpeed {
                Label("2× Speed", systemImage: "forward.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }

            if let gestureHUD {
                Label(gestureHUD, systemImage: gestureHUDIcon)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(20)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var controlsBar: some View {
        HStack {
            HStack(spacing: 20) {
                PlaybackRateMenuView(rates: playbackRates, selectedRate: $playbackRate)
                Button {
                    isMuted.toggle()
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .accessibilityLabel(isMuted ? "Unmute" : "Mute")
            }
            .padding(.horizontal)
            .frame(height: 44)
            .compatibilityGlassEffect(interactive: true)
            Spacer()
            if viewModel.playlist.count > 1 {
                HStack(spacing: 20) {
                    Button { viewModel.moveInPlaylist(by: -1) } label: { Image(systemName: "backward.end.fill") }
                        .disabled(!viewModel.hasPrevious).accessibilityLabel("Previous video")
                    Button { viewModel.moveInPlaylist(by: 1) } label: { Image(systemName: "forward.end.fill") }
                        .disabled(!viewModel.hasNext).accessibilityLabel("Next video")
                }
                .padding(.horizontal)
                .frame(height: 44)
                .compatibilityGlassEffect(interactive: true)
            }
            Button { viewModel.isLandscape.toggle() } label: {
                Image(systemName: "rotate.right")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(viewModel.isLandscape ? "Rotate to portrait" : "Rotate to landscape")
            .compatibilityGlassEffect(interactive: true)
        }
        .tint(.white)
        .font(.title3.weight(.semibold))
    }

    var overlayButtons: some View {
        HStack(spacing: 32) {
            PlayerButton(size: .small, imageName: "10.arrow.trianglehead.counterclockwise") {
                skip(by: -10)
            }
            .compatibilityGlassID("backward", in: glassNamespace)

            PlayerButton(size: .big, imageName: showsPlayingState ? "pause.fill" : "play.fill") {
                guard !isRestoringPlayback else { return }
                togglePlayback()
            }
            .compatibilityGlassID("playPause", in: glassNamespace)

            PlayerButton(size: .small, imageName: "10.arrow.trianglehead.clockwise") {
                skip(by: 10)
            }
            .compatibilityGlassID("forward", in: glassNamespace)
        }
    }
}

private extension VLCPlayerViewController.VLCPlayerView {
    var videoOutput: some View { VideoView(player) }
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
            case .stateChanged:
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

/// UIKit reports release and cancellation reliably, so temporary 2× never sticks.
private struct PlayerGestureSurface: UIViewRepresentable {
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
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        pan.require(toFail: hold)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
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
                    62
                case .big:
                    92
                }
            }

            var font: Double {
                switch self {
                case .small:
                    32
                case .big:
                    46
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

                if #available(iOS 17.0, *) {
                    image.contentTransition(.symbolEffect(.replace.downUp, options: .speed(3)))
                } else {
                    image
                }
            }

            button
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
