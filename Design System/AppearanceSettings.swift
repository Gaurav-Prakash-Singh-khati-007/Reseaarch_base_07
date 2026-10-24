import SwiftUI
import Combine

// MARK: - Appearance Settings (Phase 13D, extended in Phase 14)

/// Observable wrapper around the appearance preferences: theme, text
/// size and custom accent color.
///
/// `RBThemeStore` and `RBTextScale` (in AppTheme.swift and
/// RBTypography.swift) own the stored values and the UserDefaults
/// persistence. This class is the only thing that should change them,
/// because it also tells SwiftUI to rebuild: `RBColor` and `RBFont`
/// tokens are plain values read while a view builds its body, so a
/// change only shows up once the views that use them rebuild.
///
/// How the rebuild works:
/// - `ResearchBaseApp` creates one instance and puts it in the
///   environment.
/// - `ContentView` observes it and applies `.id(refreshToken)` to the
///   sidebar and the detail area. A new token makes SwiftUI rebuild
///   both from scratch, so every screen re-reads the new values.
/// - Navigation state (selected screen, open paper) lives in
///   `ContentView` itself, so it is not lost when the token changes.
///
/// Applied on COMMIT, not on every tick (Phase 14):
/// A rebuild throws away and recreates the whole UI, which is far too
/// heavy to do while a slider is being dragged or a color panel is
/// open. So text size and accent have no "live" setter. The Settings
/// controls keep their in-progress value in local `@State` (and may
/// preview it in a small sample), and call `commitTextScale(_:)` /
/// `commitAccent(hex:)` ONCE when the slider is released or the color
/// panel closes. Each commit changes `refreshToken` exactly once.
final class AppearanceSettings: ObservableObject {

    /// The theme currently in effect.
    @Published private(set) var theme: RBThemeID

    /// Text size multiplier currently in effect (1.0 = default).
    @Published private(set) var textScale: Double

    /// Custom accent as 6-digit hex, or nil for the theme's own accent.
    @Published private(set) var accentOverrideHex: String?

    /// Typeface currently in effect.
    @Published private(set) var fontFamily: RBFontFamily

    /// Changes every time an appearance preference changes. Used as a
    /// view identity.
    @Published private(set) var refreshToken = UUID()

    init() {
        theme = RBThemeStore.currentID
        textScale = RBTextScale.current
        fontFamily = RBFontFamily.current
        accentOverrideHex = RBThemeStore.accentOverrideHex
    }

    // MARK: Font family

    /// Saves a new typeface and refreshes the UI once. Choosing the
    /// family already in effect does nothing.
    func commitFontFamily(_ newFamily: RBFontFamily) {
        guard newFamily != fontFamily else { return }

        // Store first, so `RBFont` already uses the new family when the
        // views rebuild in response to the published changes below.
        RBFontFamily.current = newFamily

        fontFamily = newFamily
        refreshToken = UUID()
    }

    /// Back to the system font (one refresh).
    func resetFontFamily() {
        commitFontFamily(RBFontFamily.default)
    }

    // MARK: Theme

    /// Switches theme, saves it, and refreshes the UI.
    /// Selecting the theme that is already active does nothing.
    func select(_ newTheme: RBThemeID) {
        guard newTheme != theme else { return }

        // Store first, so the palette is already updated when the
        // views rebuild in response to the published changes below.
        RBThemeStore.currentID = newTheme

        theme = newTheme
        refreshToken = UUID()
    }

    /// Binding for a Picker in Settings.
    var themeBinding: Binding<RBThemeID> {
        Binding(
            get: { self.theme },
            set: { self.select($0) }
        )
    }

    // MARK: Text size

    /// Saves a new text size and refreshes the UI once. Call this when
    /// the slider is RELEASED, not while it is moving. The value is
    /// clamped to `RBTextScale.range`; committing the value already in
    /// effect does nothing.
    func commitTextScale(_ newScale: Double) {
        let clamped = RBTextScale.clamp(newScale)
        guard abs(clamped - textScale) > 0.0005 else { return }

        // Store first, so `RBFont` already returns the new sizes when
        // the views rebuild in response to the published changes below.
        RBTextScale.current = clamped

        textScale = clamped
        refreshToken = UUID()
    }

    /// Back to the default text size (one refresh).
    func resetTextScale() {
        commitTextScale(RBTextScale.default)
    }

    // MARK: Accent color

    /// The custom accent as a Color, or nil when the theme's own
    /// accent is in use.
    var accentOverrideColor: Color? {
        accentOverrideHex.map { Color(hex: $0) }
    }

    /// Saves a custom accent ("7C3AED" or "#7C3AED"; nil clears it)
    /// and refreshes the UI once. Call this when the color panel
    /// CLOSES, not on every color change. Invalid hex is ignored, and
    /// committing the accent already in effect does nothing.
    func commitAccent(hex: String?) {
        let normalized: String?
        if let hex {
            guard let valid = RBThemeStore.normalizedHex(hex) else { return }
            normalized = valid
        } else {
            normalized = nil
        }

        guard normalized != accentOverrideHex else { return }

        // Store first, so `RBColor.accent` already resolves to the new
        // value when the views rebuild.
        RBThemeStore.accentOverrideHex = normalized

        accentOverrideHex = normalized
        refreshToken = UUID()
    }

    /// Back to the theme's own accent (one refresh).
    func resetAccent() {
        commitAccent(hex: nil)
    }
}
