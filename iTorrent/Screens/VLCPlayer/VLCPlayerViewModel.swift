//
//  VLCPlayerViewModel.swift
//  IDownloader
//
//  Created by Даниил Виноградов on 21.03.2026.
//

import Foundation
import MvvmFoundation
import LibTorrent
import SwiftVLC
import UniformTypeIdentifiers
import Combine
import UIKit

extension VLCPlayerViewModel {
    struct Config {
        let url: URL
        let torrentPair: (handle: TorrentHandle, fileIndex: Int)?
        var playlist: [URL] = []
    }
}

class VLCPlayerViewModel: BaseViewModelWith<VLCPlayerViewModel.Config>, ObservableObject {
    @Published private(set) var url: URL!
    private(set) var torrentPair: (handle: TorrentHandle, fileIndex: Int)?

    @Published var showOverlay: Bool = true
    @Published var segmentedProgress: [Double]?
    @Published var isLandscape = true
    @Published var playerSafeAreaInsets: UIEdgeInsets = .zero
    @Published private(set) var playlistIndex = 0
    private(set) var playlist: [URL] = []
    let closeSignal = PassthroughSubject<Void, Never>()
    let volumeSignal = PassthroughSubject<Float, Never>()
    private var playbackTeardownHandler: (() -> Void)?

    override func prepare(with model: Config) {
        self.url = model.url
        self.torrentPair = model.torrentPair
        playlist = model.playlist.isEmpty ? [model.url] : model.playlist
        playlistIndex = playlist.firstIndex(of: model.url) ?? 0
        binding()
    }

    private func binding() {
        guard let torrentPair else { return }
        refreshSegmentedProgress()
        disposeBag.bind {
            torrentPair.handle.updatePublisher.sink { [weak self] update in
                guard let self else { return }
                refreshSegmentedProgress()
            }
        }
    }

    private func refreshSegmentedProgress() {
        guard let torrentPair else { return }
        guard torrentPair.handle.snapshot.files.indices.contains(torrentPair.fileIndex) else { return }
        let file = torrentPair.handle.snapshot.files[torrentPair.fileIndex]
        segmentedProgress = file.segmentedProgress
    }

    static func validateURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        guard url.isFileURL, (try? url.checkResourceIsReachable()) == true else { return false }

        let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return resourceValues?.isRegularFile != false
    }

    static func isMediaFile(_ url: URL) -> Bool {
        let type = UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .movie) == true || type?.conforms(to: .audio) == true
            || ["mkv", "avi", "webm", "flv", "wmv", "ts", "mts", "m2ts", "vob", "ogv", "m4v", "mp4", "mov", "mp3", "flac", "ogg", "opus"].contains(url.pathExtension.lowercased())
    }

    static func isVideoFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
            || ["mkv", "avi", "webm", "flv", "wmv", "ts", "mts", "m2ts", "vob", "ogv", "m4v", "mp4", "mov"].contains(url.pathExtension.lowercased())
    }

    var hasPrevious: Bool { playlistIndex > 0 }
    var hasNext: Bool { playlistIndex + 1 < playlist.count }

    func moveInPlaylist(by offset: Int) {
        var index = playlistIndex + offset
        while playlist.indices.contains(index) {
            let nextURL = playlist[index]
            if Self.validateURL(nextURL) {
                playlistIndex = index
                torrentPair = nil
                segmentedProgress = nil
                url = nextURL
                return
            }
            index += offset > 0 ? 1 : -1
        }
    }

    static func canOpenInVLC(_ url: URL, timeoutMilliseconds: Int32 = 3_000) async -> Media? {
        guard validateURL(url), let media = try? Media(url: url) else { return nil }

        do {
            let metadata = try await media.parse(timeout: .milliseconds(Int64(timeoutMilliseconds)))
            if !media.tracks().isEmpty { return media }
            if (metadata.duration ?? media.duration)?.milliseconds ?? 0 > 0 { return media }
            return nil
        } catch {
            return nil
        }
    }

    static func canOpenInVLCSync(_ url: URL, timeoutMilliseconds: Int32 = 100) -> Media? {
        guard validateURL(url), let media = try? Media(url: url) else { return nil }
        return media
    }

    func registerPlaybackTeardownHandler(_ handler: @escaping () -> Void) {
        playbackTeardownHandler = handler
    }

    func requestPlaybackTeardown() {
        let handler = playbackTeardownHandler
        playbackTeardownHandler = nil
        handler?()
    }

    func clearPlaybackTeardownHandler() {
        playbackTeardownHandler = nil
    }
}
