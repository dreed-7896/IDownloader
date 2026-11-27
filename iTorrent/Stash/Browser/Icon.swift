//
//  Icon.swift
//  Drift
//
//  Hugeicons (stroke rounded, MIT, see docs/licenses) bundled as vector template images in
//  Assets.xcassets/HugeIcons as "hi.<name>". Used across the browser instead of SF Symbols.
//

import SwiftUI
import UIKit

enum Icon: String {
    case back, forward, home, menu, downloads, saveVideo, shield, shieldOff, reload, stop, search, share
    case bookmark, bookmarkAdd, bookmarkRemove, history, folder, settings, desktop, moon, incognito, find
    case add, addSquare, copy, delete, link, globe, grid, video, lock, tick, close, sparkles
    case play, pause, playCircle, file, fileVideo, fileMusic, fileZip, image, music, magnet, film, alert, info, more
    case edit, upload, folderOpen, folderAdd, checkCircle, refresh, speed, timer, calendar, drive, star, rss, airplay, pip
    case grid2, list, sort, filter, inbox, wifi, faceId, bell, palette, unlink, expand

    var assetName: String { "hi." + rawValue }

    /// The icon drawn at `size` points, as a template image (tinted by the view).
    func image(_ size: CGFloat = 24) -> UIImage? {
        guard let base = UIImage(named: assetName) else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
            base.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    func view(_ size: CGFloat = 22) -> some View {
        Image(assetName).renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size)
    }
}

/// Brand colors that don't follow the user's accent.
enum Brand {
    static let mint = Color(red: 0.24, green: 0.84, blue: 0.64)
    static let teal = Color(red: 0.18, green: 0.70, blue: 0.86)
    static let violet = Color(red: 0.42, green: 0.32, blue: 0.86)
    static let ember = Color(red: 0.96, green: 0.52, blue: 0.30)
}
