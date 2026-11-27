//
//  FileRowCell.swift
//  Drift
//
//  File list row: a rounded thumbnail (or a tinted file-type tile), the name and a meta line.
//  Also the section header and the empty state used by the Files and Videos screens.
//

import UIKit

/// A label with padding: the small duration pill over a video thumbnail.
private final class FileRowPillLabel: UILabel {
    var insets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}

final class FileRowCell: UITableViewCell {
    static let reuseIdentifier = "StashFileRow"
    static let tileSize = CGSize(width: 52, height: 52)

    /// What the row shows until (or instead of) a thumbnail.
    enum Kind {
        case folder, location, video, audio, image, archive, document
    }

    private let tile = UIView()
    private let thumb = UIImageView()
    private let symbol = UIImageView()
    private let badge = FileRowPillLabel()
    private let name = UILabel()
    private let meta = UILabel()
    private let textStack = UIStackView()
    private let chevron = UIImageView(image: Icon.forward.image(16))
    private var representedURL: URL?
    private var loadTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = SColor.bg

        // Selection: a rounded, inset highlight instead of a full-width bar.
        let selection = UIView()
        let fill = UIView()
        fill.backgroundColor = SColor.s2
        fill.layer.cornerRadius = 14
        fill.layer.cornerCurve = .continuous
        fill.translatesAutoresizingMaskIntoConstraints = false
        selection.addSubview(fill)
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: selection.leadingAnchor, constant: 8),
            fill.trailingAnchor.constraint(equalTo: selection.trailingAnchor, constant: -8),
            fill.topAnchor.constraint(equalTo: selection.topAnchor, constant: 2),
            fill.bottomAnchor.constraint(equalTo: selection.bottomAnchor, constant: -2)
        ])
        selectedBackgroundView = selection

        tile.layer.cornerRadius = 10
        tile.layer.cornerCurve = .continuous
        tile.clipsToBounds = true
        tile.translatesAutoresizingMaskIntoConstraints = false
        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false
        symbol.contentMode = .center
        symbol.translatesAutoresizingMaskIntoConstraints = false
        badge.font = SFont.ui(10, .semibold) ?? .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .white
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 5
        badge.layer.cornerCurve = .continuous
        badge.layer.masksToBounds = true
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(symbol)
        tile.addSubview(thumb)
        tile.addSubview(badge)

        name.font = SFont.ui(15, .semibold) ?? .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = SColor.text
        name.numberOfLines = 2
        // Long file names keep their extension visible.
        name.lineBreakMode = .byTruncatingMiddle
        meta.font = SFont.ui(13) ?? .systemFont(ofSize: 13)
        meta.textColor = SColor.text3
        meta.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(name)
        textStack.addArrangedSubview(meta)
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tile)
        contentView.addSubview(textStack)

        chevron.tintColor = SColor.text3
        chevron.contentMode = .center
        chevron.frame = CGRect(x: 0, y: 0, width: 16, height: 16)

        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            tile.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: Self.tileSize.width),
            tile.heightAnchor.constraint(equalToConstant: Self.tileSize.height),
            tile.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
            thumb.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            thumb.topAnchor.constraint(equalTo: tile.topAnchor),
            thumb.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            symbol.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -3),
            badge.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -3),
            badge.heightAnchor.constraint(equalToConstant: 16),
            textStack.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 10),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 68)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Separators start where the text starts, like Files and Mail.
        let inset = textStack.frame.minX
        if inset > 0, separatorInset.left != inset {
            separatorInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: 0)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        durationTask?.cancel()
        durationTask = nil
        representedURL = nil
        thumb.image = nil
        badge.isHidden = true
        badge.text = nil
    }

    /// The icon and tint for rows without a thumbnail.
    private static func style(for kind: Kind) -> (Icon, UIColor) {
        switch kind {
        case .folder: return (.folder, SColor.mint)
        case .location: return (.drive, SColor.mint)
        case .video: return (.fileVideo, SColor.rgb(0x9B87F5))
        case .audio: return (.fileMusic, SColor.coral)
        case .image: return (.image, SColor.rgb(0x5AA9FF))
        case .archive: return (.fileZip, SColor.amber)
        case .document: return (.file, SColor.text2)
        }
    }

    func configure(url: URL, title: String, detail: String, kind: Kind, loadsThumbnail: Bool) {
        loadTask?.cancel()
        durationTask?.cancel()
        representedURL = url
        name.text = title
        meta.text = detail

        let (icon, color) = Self.style(for: kind)
        symbol.image = icon.image(kind == .folder || kind == .location ? 26 : 24)
        symbol.tintColor = color
        tile.backgroundColor = color.withAlphaComponent(0.14)

        let isContainer = kind == .folder || kind == .location
        accessoryView = isContainer ? chevron : nil
        accessibilityHint = isContainer ? "Opens the folder" : nil

        thumb.image = nil
        badge.isHidden = true
        badge.text = nil
        guard loadsThumbnail, !isContainer else { return }

        let size = Self.tileSize
        if let cached = ThumbnailProvider.shared.cached(for: url, size: size) {
            thumb.image = cached
        } else {
            let scale = traitCollection.displayScale
            loadTask = Task { [weak self] in
                let image = await ThumbnailProvider.shared.thumbnail(for: url, size: size, scale: scale)
                guard !Task.isCancelled, let self, self.representedURL == url, let image else { return }
                UIView.transition(with: self.thumb, duration: 0.2, options: .transitionCrossDissolve) {
                    self.thumb.image = image
                }
            }
        }

        // Videos show their length on the thumbnail, like Photos.
        guard kind == .video else { return }
        durationTask = Task { [weak self] in
            guard let seconds = await ThumbnailProvider.shared.duration(of: url), seconds.isFinite, seconds > 0 else { return }
            guard !Task.isCancelled, let self, self.representedURL == url else { return }
            let total = Int(seconds.rounded())
            self.badge.text = total >= 3600
                ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                : String(format: "%d:%02d", total / 60, total % 60)
            self.badge.isHidden = false
        }
    }
}

/// Section header for the Files screen: a quiet one-line summary.
final class StashSectionHeader: UITableViewHeaderFooterView {
    static let reuseIdentifier = "StashSectionHeader"
    let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = SColor.bg
        backgroundConfiguration = background
        label.font = SFont.ui(13, .semibold) ?? .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = SColor.text3
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Centered empty state: an icon in a soft accent circle, a title, a line of help and an optional action.
final class StashEmptyView: UIView {
    init(icon: Icon, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        super.init(frame: .zero)

        let badge = UIView()
        badge.backgroundColor = SColor.mint.withAlphaComponent(0.12)
        badge.layer.cornerRadius = 36
        badge.translatesAutoresizingMaskIntoConstraints = false
        let image = UIImageView(image: icon.image(30))
        image.tintColor = SColor.mint
        image.contentMode = .center
        image.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(image)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = SFont.display(22, .bold) ?? .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = SColor.text
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center

        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.font = SFont.ui(15) ?? .systemFont(ofSize: 15)
        messageLabel.textColor = SColor.text2
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center

        var arranged: [UIView] = [badge, titleLabel, messageLabel]
        if let actionTitle, let action {
            var configuration = UIButton.Configuration.filled()
            var attributed = AttributedString(actionTitle)
            attributed.font = SFont.ui(15, .semibold) ?? .systemFont(ofSize: 15, weight: .semibold)
            configuration.attributedTitle = attributed
            configuration.cornerStyle = .capsule
            configuration.baseBackgroundColor = SColor.mint
            configuration.baseForegroundColor = SColor.onAccent
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 22, bottom: 12, trailing: 22)
            let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
            arranged.append(button)
        }

        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(18, after: badge)
        stack.setCustomSpacing(22, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 72),
            badge.heightAnchor.constraint(equalToConstant: 72),
            image.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -36)
        ])
    }

    /// The earlier form (a text kicker over the title); the kicker is no longer shown.
    convenience init(kicker: String, title: String, message: String) {
        self.init(icon: .folderOpen, title: title, message: message)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
