import SwiftUI

// MARK: - Text Scale (Phase 14)

/// The person's chosen text size multiplier (1.0 = default).
///
/// Stored in UserDefaults like the theme (a lightweight preference, not
/// SwiftData). `AppearanceSettings` is the only place that changes it,
/// because it also tells the UI to rebuild: `RBFont` reads the scale
/// while a view builds its body, so a new value only shows up once the
/// views that use it rebuild.
enum RBTextScale {

    static let storageKey = "appearance.textScale"

    /// Smallest and largest supported multiplier.
    static let range: ClosedRange<Double> = 0.92...1.23

    static let `default`: Double = 1.0

    nonisolated(unsafe) private static var cachedScale: Double?

    /// Clamps to `range`; NaN and infinity fall back to the default so
    /// a corrupted preference can never produce an unusable UI.
    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return `default` }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static var current: Double {
        get {
            if let cachedScale { return cachedScale }

            let stored = UserDefaults.standard.object(forKey: storageKey) as? Double
            let resolved = clamp(stored ?? `default`)

            cachedScale = resolved
            return resolved
        }
        set {
            let clamped = clamp(newValue)
            cachedScale = clamped
            UserDefaults.standard.set(clamped, forKey: storageKey)
        }
    }
}

// MARK: - Type Scale

/// The app's type scale. Screens ask for a role (`body`, `caption`, ...)
/// instead of a raw point size, so text size can be adjusted in one
/// place. Every size is multiplied by `RBTextScale.current`.
///
/// Call sites look like `RBFont.body()` or `RBFont.secondary(.medium)`;
/// the font migration script emits exactly these.
///
///   title 26 · detail 20 · section 15 · body 13
///   secondary 12 · caption 11 · label 10
///
/// Icons are deliberately NOT part of this scale: they keep their own
/// fixed `.font(.system(size:))` so they do not grow with text.
enum RBFont {

    static func title(_ weight: Font.Weight = .regular) -> Font {
        scaled(26, weight)
    }

    static func detail(_ weight: Font.Weight = .regular) -> Font {
        scaled(20, weight)
    }

    static func section(_ weight: Font.Weight = .regular) -> Font {
        scaled(15, weight)
    }

    static func body(_ weight: Font.Weight = .regular) -> Font {
        scaled(13, weight)
    }

    static func secondary(_ weight: Font.Weight = .regular) -> Font {
        scaled(12, weight)
    }

    static func caption(_ weight: Font.Weight = .regular) -> Font {
        scaled(11, weight)
    }

    static func label(_ weight: Font.Weight = .regular) -> Font {
        scaled(10, weight)
    }

    private static func scaled(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        RBFontFamily.current.font(
            size: size * CGFloat(RBTextScale.current),
            weight: weight
        )
    }
}

// MARK: - Font Family

/// The typeface used for all text that goes through `RBFont`.
///
/// Stored in UserDefaults like the theme and text size, and changed only
/// through `AppearanceSettings.commitFontFamily(_:)`, which also rebuilds
/// the UI. Icons are not affected (they keep their fixed system font),
/// and neither is code, which stays monospaced where a screen asks for it.
///
/// The named families (Avenir Next, Georgia, ...) ship with macOS. If one
/// is ever missing, SwiftUI falls back to the system font, so the app
/// never ends up without text.
enum RBFontFamily: String, CaseIterable, Identifiable {

    case system
    case rounded
    case serif
    case monospaced
    case avenirNext
    case helveticaNeue
    case georgia
    case palatino
    case charter

    static let storageKey = "appearance.fontFamily"

    static let `default`: RBFontFamily = .system

    nonisolated(unsafe) private static var cachedFamily: RBFontFamily?

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .monospaced: return "Mono"
        case .avenirNext: return "Avenir Next"
        case .helveticaNeue: return "Helvetica Neue"
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        case .charter: return "Charter"
        }
    }

    /// PostScript-style family name for the named fonts; nil for the
    /// built-in system designs.
    private var customName: String? {
        switch self {
        case .avenirNext: return "Avenir Next"
        case .helveticaNeue: return "Helvetica Neue"
        case .georgia: return "Georgia"
        case .palatino: return "Palatino"
        case .charter: return "Charter"
        case .system, .rounded, .serif, .monospaced: return nil
        }
    }

    /// The font for a point size and weight in this family.
    func font(size: CGFloat, weight: Font.Weight) -> Font {
        switch self {
        case .system:
            return .system(size: size, weight: weight)
        case .rounded:
            return .system(size: size, weight: weight, design: .rounded)
        case .serif:
            return .system(size: size, weight: weight, design: .serif)
        case .monospaced:
            return .system(size: size, weight: weight, design: .monospaced)
        case .avenirNext, .helveticaNeue, .georgia, .palatino, .charter:
            return .custom(customName ?? "", fixedSize: size).weight(weight)
        }
    }

    /// The saved family; an unknown or missing value gives the default.
    static var current: RBFontFamily {
        get {
            if let cachedFamily { return cachedFamily }

            let stored = UserDefaults.standard.string(forKey: storageKey)
            let resolved = stored.flatMap(RBFontFamily.init(rawValue:)) ?? `default`

            cachedFamily = resolved
            return resolved
        }
        set {
            cachedFamily = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }
}
