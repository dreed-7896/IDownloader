//
//  FileRowCell.swift
//  Stash
//
//  Boxy file row: a square thumbnail tile, the name, and a mono meta line.
//

import UIKit

final class FileRowCell: UITableViewCell {
    static let reuseIdentifier = "StashFileRow"

    private let tile = UIView()
    private let thumb = UIImageView()
    private let symbol = UIImageView()
    private let badge = UILabel()
    private let name = UILabel()
    private let meta = UILabel()
    private var representedURL: URL?
    private var loadTask: Task<Void, Never>?
    static let tileSize = CGSize(width: 64, height: 48)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = SColor.bg
        let selected = UIView()
        selected.backgroundColor = SColor.s2
        selectedBackgroundView = selected

        tile.backgroundColor = SColor.s2
        tile.layer.borderWidth = 1
        tile.layer.borderColor = SColor.line.cgColor
        tile.clipsToBounds = true
        tile.translatesAutoresizingMaskIntoConstraints = false
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false
        symbol.contentMode = .center
        symbol.tintColor = SColor.text3
        symbol.preferredSymbolConfiguration = .init(pointSize: 18, weight: .medium)
        symbol.translatesAutoresizingMaskIntoConstraints = false
        badge.font = SFont.mono(9, .bold) ?? .monospacedSystemFont(ofSize: 9, weight: .bold)
        badge.textColor = SColor.onAccent
        badge.backgroundColor = SColor.mint
        badge.textAlignment = .center
        badge.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(symbol)
        tile.addSubview(thumb)
        tile.addSubview(badge)

        name.font = SFont.ui(15, .semibold) ?? .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = SColor.text
        name.numberOfLines = 2
        meta.font = SFont.mono(11, .medium) ?? .monospacedSystemFont(ofSize: 11, weight: .medium)
        meta.textColor = SColor.text3
        let text = UIStackView(arrangedSubviews: [name, meta])
        text.axis = .vertical
        text.spacing = 4
        text.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tile)
        contentView.addSubview(text)

        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            tile.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: Self.tileSize.width),
            tile.heightAnchor.constraint(equalToConstant: Self.tileSize.height),
            tile.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 10),
            thumb.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            thumb.topAnchor.constraint(equalTo: tile.topAnchor),
            thumb.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            symbol.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            badge.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            badge.heightAnchor.constraint(equalToConstant: 14),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            text.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        representedURL = nil
        thumb.image = nil
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        tile.layer.borderColor = SColor.line.resolvedColor(with: traitCollection).cgColor
    }

    func configure(url: URL, title: String, detail: String, symbolName: String, isDirectory: Bool, loadsThumbnail: Bool) {
        representedURL = url
        name.text = title
        meta.text = detail.uppercased()
        symbol.image = UIImage(systemName: symbolName)
        symbol.tintColor = isDirectory ? SColor.mint : SColor.text3
        let ext = url.pathExtension.uppercased()
        badge.text = isDirectory || ext.isEmpty ? nil : " \(ext.prefix(4)) "
        badge.isHidden = badge.text == nil
        thumb.image = nil
        guard loadsThumbnail, !isDirectory else { return }
        let size = Self.tileSize
        if let cached = ThumbnailProvider.shared.cached(for: url, size: size) {
            thumb.image = cached
            return
        }
        let scale = traitCollection.displayScale
        loadTask = Task { [weak self] in
            let image = await ThumbnailProvider.shared.thumbnail(for: url, size: size, scale: scale)
            guard !Task.isCancelled, let self, self.representedURL == url else { return }
            self.thumb.image = image
        }
    }
}

/// Mono uppercase section header used by Stash tables.
final class StashSectionHeader: UITableViewHeaderFooterView {
    static let reuseIdentifier = "StashSectionHeader"
    let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = SColor.bg
        backgroundConfiguration = background
        label.font = SFont.mono(11, .semibold) ?? .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = SColor.text3
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Centered empty state: mono kicker over a display title and a line of help.
final class StashEmptyView: UIView {
    init(kicker: String, title: String, message: String) {
        super.init(frame: .zero)
        let k = UILabel()
        k.text = kicker.uppercased()
        k.font = SFont.mono(11, .semibold) ?? .monospacedSystemFont(ofSize: 11, weight: .semibold)
        k.textColor = SColor.mint
        let t = UILabel()
        t.text = title
        t.font = SFont.display(26, .heavy) ?? .systemFont(ofSize: 26, weight: .heavy)
        t.textColor = SColor.text
        t.numberOfLines = 0
        t.textAlignment = .center
        let m = UILabel()
        m.text = message
        m.font = SFont.ui(15) ?? .systemFont(ofSize: 15)
        m.textColor = SColor.text2
        m.numberOfLines = 0
        m.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [k, t, m])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
