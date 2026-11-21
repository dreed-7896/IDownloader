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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: viewModel.kindIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(viewModel.isFile ? Color.sMint : Color.sAmber)
                .frame(width: 40, height: 40)
                .background(Color.sS2)
                .overlay(Rectangle().strokeBorder(Color.sLine, lineWidth: 1))
                .accessibilityLabel(viewModel.isFile ? "File download" : "Torrent")
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.title)
                    .font(.sInter(16, .semibold))
                    .foregroundStyle(Color.sText)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(viewModel.stateLabel)
                        .font(.sMono(11, .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.sOnAccent)
                        .padding(.horizontal, 5)
                        .frame(height: 18)
                        .background(viewModel.stateColor)
                    Text(viewModel.metaText)
                        .font(.sMono(13, .medium))
                        .foregroundStyle(Color.sText3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if !viewModel.detailText.isEmpty {
                    Text(viewModel.detailText)
                        .font(.sInter(14))
                        .foregroundStyle(Color.sText2)
                        .lineLimit(2)
                }
                SegmentedBar(values: viewModel.isFile ? viewModel.connections : [viewModel.progress],
                             complete: viewModel.progress >= 1)
                    .frame(height: 4)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
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
                        Rectangle().fill(Color.sS3)
                        Rectangle().fill(Color.sMint)
                            .frame(width: geometry.size.width * min(1, max(0, value)))
                    }
                }
                .accessibilityLabel("Connection \(index + 1)")
                .accessibilityValue("\(Int(value * 100)) percent")
            }
        }.frame(height: 6)
    }
}
