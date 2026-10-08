//
//  TorrentListItem.swift
//  Pulled
//
//  Created by Daniil Vinogradov on 29/10/2023.
//

import LibTorrent
import MvvmFoundation
import SwiftUI

struct TorrentListItemView: MvvmSwiftUICellProtocol {
    typealias ViewModel = TorrentListItemViewModel

    @ObservedObject var viewModel: TorrentListItemViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: viewModel.kindIcon)
                    .foregroundStyle(.tint)
                    .accessibilityLabel(viewModel.isFile ? "File download" : "Torrent")
                Text(viewModel.title)
                    .foregroundStyle(.primary)
                    .font(.subheadline.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(String(viewModel.progressText))
                Text(String(viewModel.statusText))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(.secondary)
            .font(.footnote)
            if viewModel.isFile {
                ConnectionProgressStrip(progress: viewModel.connections)
            } else {
                ProgressView(value: viewModel.progress)
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                viewModel.removeTorrent()
            } label: {
                Image(systemName: "trash")
            }
        }
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
        cell.accessories = [.disclosureIndicator(displayed: .whenNotEditing), .multiselect(displayed: .whenEditing)]
    }
}


/// Each separated track represents the actual progress of one HTTP connection.
struct ConnectionProgressStrip: View {
    var progress: [Double]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(progress.enumerated()), id: \.offset) { index, value in
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(uiColor: .systemFill))
                        Capsule().fill(.tint)
                            .frame(width: geometry.size.width * min(1, max(0, value)))
                    }
                }
                .accessibilityLabel("Connection \(index + 1)")
                .accessibilityValue("\(Int(value * 100)) percent")
            }
        }.frame(height: 6)
    }
}
