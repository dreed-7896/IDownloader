//
//  TorrentListItem.swift
//  Drift
//
//  One row of the downloads list: a rounded tile (the video's own thumbnail once it's saved,
//  otherwise a tinted icon for its kind), the name, a soft status pill with the transfer details,
//  and a slim rounded progress bar (one segment per connection for multi-connection files).
//

import LibTorrent
import MvvmFoundation
import SwiftUI

struct TorrentListItemView: MvvmSwiftUICellProtocol {
    typealias ViewModel = TorrentListItemViewModel

    @ObservedObject var viewModel: TorrentListItemViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            DownloadTile(viewModel: viewModel)

            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.title)
                    .font(.sInter(15, .semibold))
                    .foregroundStyle(Color.sText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    StatusPill(text: viewModel.stateLabel, color: viewModel.stateColor, icon: viewModel.stateIcon)
                    Text(viewModel.metaText)
                        .font(.sInter(13))
                        .monospacedDigit()
                        .foregroundStyle(Color.sText3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                if !viewModel.detailText.isEmpty {
                    Text(viewModel.detailText)
                        .font(.sInter(13))
                        .foregroundStyle(Color.sCoral.opacity(0.9))
                        .lineLimit(2)
                }

                if viewModel.showsProgress {
                    CapsuleProgress(values: progressValues, color: viewModel.stateColor)
                        .frame(height: 5)
                        .padding(.top, 2)
                        .accessibilityLabel("Progress")
                        .accessibilityValue("\(Int(viewModel.progress * 100)) percent")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                viewModel.removeTorrent()
            } label: {
                Label("Delete", image: Icon.delete.assetName)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if viewModel.canPause {
                Button {
                    viewModel.pause()
                } label: {
                    Label("Pause", image: Icon.pause.assetName)
                }
                .tint(Color.sAmber)
            } else if viewModel.canResume {
                Button {
                    viewModel.resume()
                } label: {
                    Label("Resume", image: Icon.play.assetName)
                }
                .tint(Color.sMint)
            }
        }
    }

    /// Per-connection segments for multi-connection files; a single bar otherwise.
    private var progressValues: [Double] {
        viewModel.isFile && viewModel.connections.count > 1 ? viewModel.connections : [viewModel.progress]
    }

    static let registration: UICollectionView.CellRegistration<UICollectionViewListCell, ViewModel> = .init { cell, _, itemIdentifier in
        cell.contentConfiguration = UIHostingConfiguration {
            Self(viewModel: itemIdentifier)
        }

        var config: UIBackgroundConfiguration
        if #available(iOS 18.0, visionOS 2.0, *) {
            config = .listCell()
        } else {
            config = .listPlainCell()
        }

        config.backgroundColorTransformer = .init { color in
            guard !cell.isHighlighted, !cell.isSelected
            else { return color }

            return .clear
        }
        cell.backgroundConfiguration = config
        // No chevrons: the whole row opens the download, like Music's downloads list.
        cell.accessories = [.multiselect(displayed: .whenEditing)]
    }
}

// MARK: - Pieces

/// The leading tile: the saved video's thumbnail when there is one, else a tinted kind icon.
private struct DownloadTile: View {
    @ObservedObject var viewModel: TorrentListItemViewModel
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?

    private static let side: CGFloat = 52

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            shape.fill(viewModel.kindTint.opacity(0.16))
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: Self.side, height: Self.side)
                if viewModel.isVideoFile {
                    Icon.play.view(12)
                        .foregroundStyle(Color.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                }
            } else {
                viewModel.kindHugeIcon.view(22)
                    .foregroundStyle(viewModel.kindTint)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        .accessibilityLabel(viewModel.isFile ? "File download" : "Torrent")
        .task(id: viewModel.thumbnailURL) {
            guard let url = viewModel.thumbnailURL else {
                thumbnail = nil
                return
            }
            let size = CGSize(width: Self.side, height: Self.side)
            if let cached = ThumbnailProvider.shared.cached(for: url, size: size) {
                thumbnail = cached
                return
            }
            let image = await ThumbnailProvider.shared.thumbnail(for: url, size: size, scale: displayScale)
            if !Task.isCancelled { thumbnail = image }
        }
    }
}

/// A soft capsule: tinted background, colored text, optional small icon.
private struct StatusPill: View {
    let text: String
    let color: Color
    let icon: Icon?

    var body: some View {
        HStack(spacing: 4) {
            if let icon { icon.view(11) }
            Text(text)
                .font(.sInter(11, .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(color.opacity(0.16)))
        .fixedSize()
    }
}

/// Rounded progress capsules with small gaps between segments.
private struct CapsuleProgress: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, values.count)
            let gap: CGFloat = count > 1 ? 3 : 0
            let segment = max(0, (geometry.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    let fraction = CGFloat(min(1, max(0, value)))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.sS3)
                        Capsule()
                            .fill(color)
                            .frame(width: fraction > 0 ? max(geometry.size.height, segment * fraction) : 0)
                    }
                    .frame(width: segment)
                }
            }
        }
        .animation(.easeOut(duration: 0.35), value: values)
    }
}

/// Each separated track represents the actual progress of one HTTP connection.
struct ConnectionProgressStrip: View {
    var progress: [Double]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(progress.enumerated()), id: \.offset) { index, value in
                GeometryReader { geometry in
                    let fraction = CGFloat(min(1, max(0, value)))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.sS3)
                        Capsule().fill(Color.sMint)
                            .frame(width: fraction > 0 ? max(geometry.size.height, geometry.size.width * fraction) : 0)
                    }
                }
                .accessibilityLabel("Connection \(index + 1)")
                .accessibilityValue("\(Int(value * 100)) percent")
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.35), value: progress)
    }
}
