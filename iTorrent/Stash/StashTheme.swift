//
//  StashTheme.swift
//  Stash
//
//  Stash shares Midoku's boxy look: square corners, a near-black dark palette, Inter for text,
//  Bricolage Grotesque for headings and JetBrains Mono for labels. Stash's own accent is mint.
//

import CoreText
import ObjectiveC
import SwiftUI
import UIKit

// MARK: - Palette

enum SColor {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    private static func dynamic(dark: UInt32, light: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? SColor.rgb(dark, alpha) : SColor.rgb(light, alpha) }
    }

    static let bg = dynamic(dark: 0x09090B, light: 0xFAFAF7)
    static let s1 = dynamic(dark: 0x111114, light: 0xFFFFFF)
    static let s2 = dynamic(dark: 0x18181D, light: 0xF0F2ED)
    static let s3 = dynamic(dark: 0x1F1F26, light: 0xE6E9E3)
    static let line = dynamic(dark: 0x23232A, light: 0xE0E6DD)
    static let line2 = dynamic(dark: 0x2E2E37, light: 0xCBD3C8)
    static let text = dynamic(dark: 0xF4F4F6, light: 0x14181A)
    static let text2 = dynamic(dark: 0xB4B4BE, light: 0x4A5350)
    static let text3 = dynamic(dark: 0x8E8E9A, light: 0x6E7773)
    /// The accent: the user's tint color (Stash mint by default).
    static var mint: UIColor { PreferencesStorage.shared.tintColor }
    static let amber = rgb(0xFFB547)
    static let coral = rgb(0xFF6B5E)
    /// Text on the accent: dark on light accents, white on dark ones.
    static var onAccent: UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        mint.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)).getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.55 ? rgb(0x0B0B0F) : .white
    }
}

extension Color {
    static let sBg = Color(uiColor: SColor.bg)
    static let sS1 = Color(uiColor: SColor.s1)
    static let sS2 = Color(uiColor: SColor.s2)
    static let sS3 = Color(uiColor: SColor.s3)
    static let sLine = Color(uiColor: SColor.line)
    static let sLine2 = Color(uiColor: SColor.line2)
    static let sText = Color(uiColor: SColor.text)
    static let sText2 = Color(uiColor: SColor.text2)
    static let sText3 = Color(uiColor: SColor.text3)
    static var sMint: Color { Color(uiColor: SColor.mint) }
    static let sAmber = Color(uiColor: SColor.amber)
    static let sCoral = Color(uiColor: SColor.coral)
    static var sOnAccent: Color { Color(uiColor: SColor.onAccent) }
}

// MARK: - Fonts

enum SFont {
    static let files = [
        "Inter-Regular", "Inter-Medium", "Inter-SemiBold", "Inter-Bold",
        "BricolageGrotesque-SemiBold", "BricolageGrotesque-Bold", "BricolageGrotesque-ExtraBold",
        "JetBrainsMono-Medium", "JetBrainsMono-SemiBold", "JetBrainsMono-Bold"
    ]

    nonisolated(unsafe) private(set) static var available = false

    static func register() {
        for name in files {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        available = UIFont(name: "Inter-Regular", size: 12) != nil
    }

    static func interName(_ weight: CGFloat) -> String {
        switch weight {
        case ..<0.1: return "Inter-Regular"
        case ..<0.27: return "Inter-Medium"
        case ..<0.35: return "Inter-SemiBold"
        default: return "Inter-Bold"
        }
    }

    static func displayName(_ weight: CGFloat) -> String {
        switch weight {
        case ..<0.35: return "BricolageGrotesque-SemiBold"
        case ..<0.5: return "BricolageGrotesque-Bold"
        default: return "BricolageGrotesque-ExtraBold"
        }
    }

    static func monoName(_ weight: CGFloat) -> String {
        switch weight {
        case ..<0.27: return "JetBrainsMono-Medium"
        case ..<0.35: return "JetBrainsMono-SemiBold"
        default: return "JetBrainsMono-Bold"
        }
    }

    static func ui(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont? {
        UIFont(name: interName(weight.rawValue), size: size)
    }

    static func display(_ size: CGFloat, _ weight: UIFont.Weight = .bold) -> UIFont? {
        UIFont(name: displayName(weight.rawValue), size: size)
    }

    static func mono(_ size: CGFloat, _ weight: UIFont.Weight = .semibold) -> UIFont? {
        UIFont(name: monoName(weight.rawValue), size: size)
    }

    static func size(for style: UIFont.TextStyle) -> (CGFloat, UIFont.Weight, Bool) {
        switch style {
        case .largeTitle: return (34, .heavy, true)
        case .title1: return (28, .bold, true)
        case .title2: return (22, .bold, true)
        case .title3: return (20, .bold, true)
        case .headline: return (16, .bold, false)
        case .subheadline: return (14, .regular, false)
        case .callout: return (15, .regular, false)
        case .footnote: return (14, .regular, false)
        case .caption1: return (13, .regular, false)
        case .caption2: return (12, .regular, false)
        default: return (15, .regular, false)
        }
    }

    static func preferred(_ style: UIFont.TextStyle, traits: UITraitCollection? = nil) -> UIFont? {
        let (size, weight, display) = size(for: style)
        guard let base = display ? Self.display(size, weight) : ui(size, weight) else { return nil }
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base, compatibleWith: traits)
    }
}

extension Font {
    static func sInter(_ size: CGFloat, _ weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        guard SFont.available else { return .system(size: size, weight: weight) }
        return .custom(SFont.interName(weight.sRaw), size: size, relativeTo: style)
    }

    static func sDisplay(_ size: CGFloat, _ weight: Font.Weight = .heavy, relativeTo style: Font.TextStyle = .title) -> Font {
        guard SFont.available else { return .system(size: size, weight: weight) }
        return .custom(SFont.displayName(weight.sRaw), size: size, relativeTo: style)
    }

    /// Mono uppercase labels (Midoku `.kicker` / `.label`).
    static func sMono(_ size: CGFloat = 12, _ weight: Font.Weight = .semibold) -> Font {
        guard SFont.available else { return .system(size: size, weight: weight, design: .monospaced) }
        return .custom(SFont.monoName(weight.sRaw), size: size, relativeTo: .caption)
    }
}

extension Font.Weight {
    var sRaw: CGFloat {
        switch self {
        case .ultraLight: return -0.8
        case .thin: return -0.6
        case .light: return -0.4
        case .regular: return 0
        case .medium: return 0.23
        case .semibold: return 0.3
        case .bold: return 0.4
        case .heavy: return 0.56
        case .black: return 0.62
        default: return 0
        }
    }
}

extension View {
    /// Mono, uppercase, letter-spaced, muted section label.
    func sLabel(_ size: CGFloat = 12) -> some View {
        font(.sMono(size)).textCase(.uppercase).tracking(1).foregroundStyle(Color.sText3)
    }
}

// MARK: - Global UIKit styling

enum StashTheme {
    private static var installed = false

    /// Installs fonts, palette and square chrome. Call once before the first window appears.
    static func install() {
        guard !installed else { return }
        installed = true
        SFont.register()
        overrideSystemColors()
        if SFont.available { overrideSystemFonts() }
        removeLiquidGlass()
        applyAppearance()
    }

    /// System background, separator and label colors become the Stash palette.
    private static func overrideSystemColors() {
        let map: [(String, UIColor)] = [
            ("systemBackgroundColor", SColor.bg),
            ("secondarySystemBackgroundColor", SColor.s1),
            ("tertiarySystemBackgroundColor", SColor.s2),
            ("systemGroupedBackgroundColor", SColor.bg),
            ("secondarySystemGroupedBackgroundColor", SColor.s1),
            ("tertiarySystemGroupedBackgroundColor", SColor.s2),
            ("separatorColor", SColor.line),
            ("opaqueSeparatorColor", SColor.line2),
            ("labelColor", SColor.text),
            ("secondaryLabelColor", SColor.text2),
            ("tertiaryLabelColor", SColor.text3)
        ]
        for (name, replacement) in map {
            let selector = NSSelectorFromString(name)
            guard let method = class_getClassMethod(UIColor.self, selector) else { continue }
            let block: @convention(block) (AnyObject) -> UIColor = { _ in replacement }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }

    /// Runs `make` unless a font override is already running on this thread (UIKit can call the
    /// overridden methods while building a font), in which case the system font is used.
    private static func guarded(_ make: () -> UIFont?, fallback: () -> UIFont) -> UIFont {
        let key = "StashTheme.fontOverride"
        let dictionary = Thread.current.threadDictionary
        if dictionary[key] != nil { return fallback() }
        dictionary[key] = true
        defer { dictionary.removeObject(forKey: key) }
        return make() ?? fallback()
    }

    /// UIKit text (labels, cells, alerts, bars) uses Inter instead of San Francisco.
    private static func overrideSystemFonts() {
        let cls: AnyClass = UIFont.self

        typealias SizeWeight = @convention(c) (AnyClass, Selector, CGFloat, CGFloat) -> UIFont
        let sizeWeightSelector = NSSelectorFromString("systemFontOfSize:weight:")
        if let method = class_getClassMethod(cls, sizeWeightSelector) {
            let original = unsafeBitCast(method_getImplementation(method), to: SizeWeight.self)
            let block: @convention(block) (AnyClass, CGFloat, CGFloat) -> UIFont = { c, size, weight in
                StashTheme.guarded({ SFont.ui(size, UIFont.Weight(rawValue: weight)) }) {
                    original(c, sizeWeightSelector, size, weight)
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        typealias Size = @convention(c) (AnyClass, Selector, CGFloat) -> UIFont
        for (name, weight) in [("systemFontOfSize:", UIFont.Weight.regular), ("boldSystemFontOfSize:", .bold)] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getClassMethod(cls, selector) else { continue }
            let original = unsafeBitCast(method_getImplementation(method), to: Size.self)
            let block: @convention(block) (AnyClass, CGFloat) -> UIFont = { c, size in
                StashTheme.guarded({ SFont.ui(size, weight) }) { original(c, selector, size) }
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        typealias Style = @convention(c) (AnyClass, Selector, NSString) -> UIFont
        let styleSelector = NSSelectorFromString("preferredFontForTextStyle:")
        if let method = class_getClassMethod(cls, styleSelector) {
            let original = unsafeBitCast(method_getImplementation(method), to: Style.self)
            let block: @convention(block) (AnyClass, NSString) -> UIFont = { c, style in
                StashTheme.guarded({ SFont.preferred(UIFont.TextStyle(rawValue: style as String)) }) {
                    original(c, styleSelector, style)
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }

        typealias StyleTraits = @convention(c) (AnyClass, Selector, NSString, UITraitCollection?) -> UIFont
        let styleTraitsSelector = NSSelectorFromString("preferredFontForTextStyle:compatibleWithTraitCollection:")
        if let method = class_getClassMethod(cls, styleTraitsSelector) {
            let original = unsafeBitCast(method_getImplementation(method), to: StyleTraits.self)
            let block: @convention(block) (AnyClass, NSString, UITraitCollection?) -> UIFont = { c, style, traits in
                StashTheme.guarded({ SFont.preferred(UIFont.TextStyle(rawValue: style as String), traits: traits) }) {
                    original(c, styleTraitsSelector, style, traits)
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }

    /// Flat and boxy: bar buttons lose their glass capsules, scroll views lose the blurred edge
    /// under the bars, and sheets get square corners. Each hook is skipped where the OS lacks it.
    private static func removeLiquidGlass() {
        func method(_ className: String, _ name: String) -> Method? {
            guard let cls = NSClassFromString(className) else { return nil }
            return class_getInstanceMethod(cls, NSSelectorFromString(name))
        }
        let yes: @convention(block) (AnyObject) -> Bool = { _ in true }
        for (className, name) in [("UIBarButtonItem", "hidesSharedBackground"), ("UIScrollEdgeEffect", "isHidden")] {
            if let m = method(className, name) { method_setImplementation(m, imp_implementationWithBlock(yes)) }
        }
    }

    /// A bordered square with a chevron: the boxy back button.
    private static func backSquareImage() -> UIImage {
        let side: CGFloat = 36
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: CGSize(width: side + 6, height: side), format: format).image { context in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            let traits = UITraitCollection(userInterfaceStyle: .dark)
            SColor.s2.resolvedColor(with: traits).setFill()
            UIBezierPath(ovalIn: rect).fill()
            UIColor.white.withAlphaComponent(0.08).setStroke()
            let border = UIBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
            if let chevron = (Icon.back.image(20) ?? UIImage(systemName: "chevron.left"))?
                .withTintColor(SColor.text.resolvedColor(with: traits), renderingMode: .alwaysOriginal) {
                let size = chevron.size
                chevron.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                        width: size.width, height: size.height))
            }
            _ = context
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    /// Re-applies accent-colored appearance after the user changes the tint.
    static func applyAccent(_ color: UIColor) {
        UISwitch.appearance().onTintColor = color
        UIProgressView.appearance().progressTintColor = color
    }

    private static func applyAppearance() {
        let titleFont = SFont.display(17, .bold) ?? .systemFont(ofSize: 17, weight: .semibold)
        let largeFont = SFont.display(34, .heavy) ?? .systemFont(ofSize: 34, weight: .bold)

        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = SColor.bg
        bar.shadowColor = SColor.line
        bar.titleTextAttributes = [.font: titleFont, .foregroundColor: SColor.text]
        bar.largeTitleTextAttributes = [.font: largeFont, .foregroundColor: SColor.text, .kern: -1.0]
        if let buttonFont = SFont.ui(15, .semibold) {
            let button = UIBarButtonItemAppearance()
            button.normal.titleTextAttributes = [.font: buttonFont]
            bar.buttonAppearance = button
            bar.doneButtonAppearance = button
        }
        let backImage = backSquareImage()
        bar.setBackIndicatorImage(backImage, transitionMaskImage: backImage)
        let back = UIBarButtonItemAppearance()
        back.normal.titleTextAttributes = [.foregroundColor: UIColor.clear, .font: UIFont.systemFont(ofSize: 1)]
        back.highlighted.titleTextAttributes = back.normal.titleTextAttributes
        back.normal.titlePositionAdjustment = UIOffset(horizontal: -1000, vertical: 0)
        bar.backButtonAppearance = back
        let edge = bar.copy()
        edge.shadowColor = .clear
        let navigationBar = UINavigationBar.appearance()
        navigationBar.standardAppearance = bar
        navigationBar.compactAppearance = bar
        navigationBar.scrollEdgeAppearance = edge
        navigationBar.compactScrollEdgeAppearance = edge

        let toolbar = UIToolbarAppearance()
        // Toolbars blend into the screen; their rounded buttons carry the shape.
        toolbar.configureWithOpaqueBackground()
        toolbar.backgroundColor = SColor.bg
        toolbar.shadowColor = .clear
        UIToolbar.appearance().standardAppearance = toolbar
        UIToolbar.appearance().scrollEdgeAppearance = toolbar
        UIToolbar.appearance().compactAppearance = toolbar

        applyAccent(SColor.mint)
        UIRefreshControl.appearance().tintColor = SColor.text3
        UITableView.appearance().separatorColor = SColor.line

        UIProgressView.appearance().trackTintColor = SColor.s3

        if let segmentFont = SFont.ui(13, .medium), let segmentSelected = SFont.ui(13, .semibold) {
            let segment = UISegmentedControl.appearance()
            segment.selectedSegmentTintColor = SColor.text
            segment.backgroundColor = SColor.s1
            segment.setTitleTextAttributes([.font: segmentFont, .foregroundColor: SColor.text2], for: .normal)
            segment.setTitleTextAttributes([.font: segmentSelected, .foregroundColor: SColor.bg], for: .selected)
        }

        if let searchFont = SFont.ui(16) {
            UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self]).defaultTextAttributes = [
                .font: searchFont, .foregroundColor: SColor.text
            ]
        }
    }
}
