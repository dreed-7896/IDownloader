//
//  StashBarItem.swift
//  Stash
//
//  Boxy toolbar buttons: a square bordered tile with an icon and an optional label.
//

import UIKit

enum StashBarItem {
    /// A square toolbar button. `prominent` fills it with the accent.
    static func make(title: String?, systemImage: String, prominent: Bool = false, accessibilityLabel: String? = nil,
                     action: @escaping () -> Void) -> UIBarButtonItem {
        var configuration = prominent ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        let hugeicon: [String: Icon] = ["folder": .folder, "gearshape": .settings, "plus": .add, "square.and.arrow.down": .upload,
                                       "folder.badge.plus": .folderAdd]
        configuration.image = hugeicon[systemImage]?.image(21)
            ?? UIImage(systemName: systemImage, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        configuration.imagePadding = 7
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 14
        configuration.background.strokeWidth = 1
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: title == nil ? 0 : 14, bottom: 0, trailing: title == nil ? 0 : 16)
        if let title {
            var attributed = AttributedString(title)
            attributed.font = SFont.ui(15, .semibold) ?? .systemFont(ofSize: 15, weight: .semibold)
            configuration.attributedTitle = attributed
        }
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.configurationUpdateHandler = { button in
            var updated = button.configuration
            let accent = button.tintColor ?? SColor.mint
            if prominent {
                updated?.baseBackgroundColor = accent
                updated?.baseForegroundColor = SColor.onAccent
                updated?.background.strokeColor = accent
            } else {
                updated?.baseForegroundColor = SColor.text
                updated?.background.backgroundColor = SColor.s2
                updated?.background.strokeColor = UIColor.white.withAlphaComponent(0.07)
            }
            button.alpha = button.isHighlighted ? 0.65 : (button.isEnabled ? 1 : 0.4)
            button.configuration = updated
        }
        button.accessibilityLabel = accessibilityLabel ?? title
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 44),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        let item = UIBarButtonItem(customView: button)
        item.accessibilityLabel = button.accessibilityLabel
        return item
    }

    static func gap(_ width: CGFloat = 8) -> UIBarButtonItem { .fixedSpace(width) }
}
