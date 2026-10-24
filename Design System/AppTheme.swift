import SwiftUI

// MARK: - Theme Identity

/// The themes ResearchBase ships with. All are real, fully specified
/// palettes; the Settings screen (Phase 13E) lists exactly these.
enum RBThemeID: String, CaseIterable, Identifiable {

    /// Light, frosted lavender-to-pink look (default).
    case lavender

    /// Light, fresh green.
    case mint

    /// Light, cool grey-blue.
    case cloud

    /// The original dark navy look from Phases 1–12.
    case midnight

    /// Dark, deep blue with a sky-blue accent.
    case oceanDeep

    // Agent 79 — new themes (all with real gradients).
    /// Light, peach-to-pink sunset.
    case sunset
    /// Light, soft rose and cream.
    case rose
    /// Light, warm sand.
    case sand
    /// Light, pale sky blue to mint.
    case sky
    /// Dark, deep forest green.
    case forest
    /// Dark, cool blue-grey.
    case slate
    /// Dark, neutral graphite.
    case graphite
    /// Dark, deep plum.
    case plum
    /// Dark, teal-to-violet night sky.
    case aurora
    /// Dark, glowing ember orange.
    case ember

    static let `default`: RBThemeID = .lavender

    /// True for the dark themes.
    var isDark: Bool { colorScheme == .dark }

    /// Light themes, in Settings order.
    static var lightThemes: [RBThemeID] { allCases.filter { !$0.isDark } }

    /// Dark themes, in Settings order.
    static var darkThemes: [RBThemeID] { allCases.filter { $0.isDark } }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lavender: return "Lavender"
        case .mint: return "Mint"
        case .cloud: return "Cloud"
        case .midnight: return "Midnight"
        case .oceanDeep: return "Ocean Deep"
        case .sunset: return "Sunset"
        case .rose: return "Rose"
        case .sand: return "Sand"
        case .sky: return "Sky"
        case .forest: return "Forest"
        case .slate: return "Slate"
        case .graphite: return "Graphite"
        case .plum: return "Plum"
        case .aurora: return "Aurora"
        case .ember: return "Ember"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .lavender: return .light
        case .mint: return .light
        case .cloud: return .light
        case .midnight: return .dark
        case .oceanDeep: return .dark
        case .sunset, .rose, .sand, .sky: return .light
        case .forest, .slate, .graphite, .plum, .aurora, .ember: return .dark
        }
    }

    var palette: RBPalette {
        switch self {
        case .lavender: return .lavender
        case .mint: return .mint
        case .cloud: return .cloud
        case .midnight: return .midnight
        case .oceanDeep: return .oceanDeep
        case .sunset: return .sunset
        case .rose: return .rose
        case .sand: return .sand
        case .sky: return .sky
        case .forest: return .forest
        case .slate: return .slate
        case .graphite: return .graphite
        case .plum: return .plum
        case .aurora: return .aurora
        case .ember: return .ember
        }
    }
}

// MARK: - Palette

/// One complete set of semantic colors. Views never read a palette
/// directly — they read `RBColor`, which always resolves against the
/// currently selected theme.
struct RBPalette {

    // Surfaces
    let background: Color
    let sidebar: Color
    let surface: Color
    let card: Color
    let elevatedSurface: Color
    let inputBackground: Color

    // Interaction
    let hover: Color
    let selected: Color
    let border: Color

    // Text
    let primaryText: Color
    let secondaryText: Color
    let mutedText: Color
    let selectedText: Color
    let onAccent: Color

    // Accents and status
    let accent: Color
    let accentSecondary: Color
    let success: Color
    let warning: Color
    let error: Color

    // Window backdrop
    let gradientStart: Color
    let gradientEnd: Color

    // From the HTML: `--pg` (the manuscript page) and the dark
    // overlay behind sheets and the narrow-window sidebar (`.ov`).
    let page: Color
    let scrim: Color

    // MARK: Lavender (light, default)

    static let lavender = RBPalette(
        background: Color(hex: "EFE9FB"),
        sidebar: Color.white.opacity(0.6),
        surface: Color.white.opacity(0.6),
        card: Color.white.opacity(0.82),
        elevatedSurface: Color.white.opacity(0.94),
        inputBackground: Color.white.opacity(0.85),

        hover: Color(hex: "7C3AED").opacity(0.08),
        selected: Color(hex: "7C3AED"),
        border: Color(hex: "7C3AED").opacity(0.16),

        primaryText: Color(hex: "1E1A2E"),
        secondaryText: Color(hex: "55506B"),
        mutedText: Color(hex: "7A748F"),
        selectedText: Color.white,
        onAccent: Color.white,

        accent: Color(hex: "7C3AED"),
        accentSecondary: Color(hex: "E879B0"),
        success: Color(hex: "1F8A5B"),
        warning: Color(hex: "C26A0C"),
        error: Color(hex: "C93B4A"),

        gradientStart: Color(hex: "DCCBF7"),
        gradientEnd: Color(hex: "F8DCEB"),

        page: Color.white,
        scrim: Color(hex: "140A28").opacity(0.45)
    )

    // MARK: Midnight (dark, original palette)

    static let midnight = RBPalette(
        background: Color(hex: "0F1419"),
        sidebar: Color(hex: "111820"),
        surface: Color(hex: "17212B"),
        card: Color(hex: "1B2632"),
        elevatedSurface: Color(hex: "1F2C3A"),
        inputBackground: Color(hex: "0F1419"),

        hover: Color(hex: "22303D"),
        selected: Color(hex: "7BA7D9").opacity(0.18),
        border: Color(hex: "2A3744"),

        primaryText: Color(hex: "F1F5F9"),
        secondaryText: Color(hex: "A8B3BF"),
        mutedText: Color(hex: "6F7C89"),
        selectedText: Color(hex: "F1F5F9"),
        onAccent: Color(hex: "0F1419"),

        accent: Color(hex: "7BA7D9"),
        accentSecondary: Color(hex: "9C8FD9"),
        success: Color(hex: "78B89A"),
        warning: Color(hex: "D6AD6E"),
        error: Color(hex: "D98282"),

        gradientStart: Color(hex: "0F1419"),
        gradientEnd: Color(hex: "172231"),

        page: Color(hex: "16202B"),
        scrim: Color(hex: "140A28").opacity(0.45)
    )

    // MARK: Mint (light)

    static let mint = RBPalette(
        background: Color(hex: "E8F5EF"),
        sidebar: Color(hex: "F2FAF6"),
        surface: Color(hex: "F7FCF9"),
        card: Color.white,
        elevatedSurface: Color.white,
        inputBackground: Color.white,

        hover: Color(hex: "0D7A5F").opacity(0.08),
        selected: Color(hex: "0D7A5F"),
        border: Color(hex: "0D7A5F").opacity(0.18),

        primaryText: Color(hex: "12302A"),
        secondaryText: Color(hex: "39574E"),
        mutedText: Color(hex: "566F66"),
        selectedText: Color.white,
        onAccent: Color.white,

        accent: Color(hex: "0D7A5F"),
        accentSecondary: Color(hex: "3B82C4"),
        success: Color(hex: "1F7A4F"),
        warning: Color(hex: "A65A05"),
        error: Color(hex: "C23B47"),

        gradientStart: Color(hex: "E3F4EC"),
        gradientEnd: Color(hex: "D3ECF3"),

        page: Color.white,
        scrim: Color(hex: "0B1F1A").opacity(0.45)
    )

    // MARK: Cloud (light)

    static let cloud = RBPalette(
        background: Color(hex: "EEF1F6"),
        sidebar: Color(hex: "F6F8FB"),
        surface: Color(hex: "F9FAFC"),
        card: Color.white,
        elevatedSurface: Color.white,
        inputBackground: Color.white,

        hover: Color(hex: "3B5BDB").opacity(0.08),
        selected: Color(hex: "3B5BDB"),
        border: Color(hex: "3B5BDB").opacity(0.18),

        primaryText: Color(hex: "1A2233"),
        secondaryText: Color(hex: "485068"),
        mutedText: Color(hex: "5F6780"),
        selectedText: Color.white,
        onAccent: Color.white,

        accent: Color(hex: "3B5BDB"),
        accentSecondary: Color(hex: "E8590C"),
        success: Color(hex: "1F7A4F"),
        warning: Color(hex: "A65A05"),
        error: Color(hex: "C23B47"),

        gradientStart: Color(hex: "EEF1F6"),
        gradientEnd: Color(hex: "DCE4F5"),

        page: Color.white,
        scrim: Color(hex: "111A33").opacity(0.45)
    )

    // MARK: Ocean Deep (dark)

    static let oceanDeep = RBPalette(
        background: Color(hex: "08151F"),
        sidebar: Color(hex: "0C1D2A"),
        surface: Color(hex: "0F2331"),
        card: Color(hex: "122736"),
        elevatedSurface: Color(hex: "183143"),
        inputBackground: Color(hex: "08151F"),

        hover: Color(hex: "1C2831"),
        selected: Color(hex: "38BDF8").opacity(0.18),
        border: Color(hex: "2B363E"),

        primaryText: Color(hex: "E4F2FA"),
        secondaryText: Color(hex: "9FBDD0"),
        mutedText: Color(hex: "7898AE"),
        selectedText: Color(hex: "E4F2FA"),
        onAccent: Color(hex: "08151F"),

        accent: Color(hex: "38BDF8"),
        accentSecondary: Color(hex: "FBBF24"),
        success: Color(hex: "6FCB9F"),
        warning: Color(hex: "EBC06B"),
        error: Color(hex: "EE8B8B"),

        gradientStart: Color(hex: "08151F"),
        gradientEnd: Color(hex: "0B2B3E"),

        page: Color(hex: "0D1E2B"),
        scrim: Color(hex: "020A12").opacity(0.55)
    )

    // MARK: - Agent 79: new themes
    //
    // Two small builders keep ten palettes consistent. Light themes use the
    // same frosted white surfaces as Lavender, so the window gradient shows
    // through. Dark themes use faint white overlays on the gradient, with a
    // solid `elevatedSurface` so popovers never show text through them.
    // Text colors were checked for at least 4.5:1 contrast on the surfaces.

    private static func light(
        background: String, gradient: (String, String),
        accent: String, accentSecondary: String,
        text: (String, String, String), scrim: String
    ) -> RBPalette {
        RBPalette(
            background: Color(hex: background),
            sidebar: Color.white.opacity(0.6),
            surface: Color.white.opacity(0.6),
            card: Color.white.opacity(0.82),
            elevatedSurface: Color.white.opacity(0.94),
            inputBackground: Color.white.opacity(0.85),

            hover: Color(hex: accent).opacity(0.08),
            selected: Color(hex: accent),
            border: Color(hex: accent).opacity(0.16),

            primaryText: Color(hex: text.0),
            secondaryText: Color(hex: text.1),
            mutedText: Color(hex: text.2),
            selectedText: Color.white,
            onAccent: Color.white,

            accent: Color(hex: accent),
            accentSecondary: Color(hex: accentSecondary),
            success: Color(hex: "1F8A5B"),
            warning: Color(hex: "C26A0C"),
            error: Color(hex: "C93B4A"),

            gradientStart: Color(hex: gradient.0),
            gradientEnd: Color(hex: gradient.1),

            page: Color.white,
            scrim: Color(hex: scrim).opacity(0.45)
        )
    }

    private static func dark(
        background: String, gradient: (String, String), elevated: String,
        accent: String, accentSecondary: String, onAccent: String,
        text: (String, String, String)
    ) -> RBPalette {
        RBPalette(
            background: Color(hex: background),
            sidebar: Color.white.opacity(0.05),
            surface: Color.white.opacity(0.06),
            card: Color.white.opacity(0.08),
            elevatedSurface: Color(hex: elevated),
            inputBackground: Color.black.opacity(0.25),

            hover: Color.white.opacity(0.08),
            selected: Color(hex: accent).opacity(0.18),
            border: Color.white.opacity(0.12),

            primaryText: Color(hex: text.0),
            secondaryText: Color(hex: text.1),
            mutedText: Color(hex: text.2),
            selectedText: Color(hex: text.0),
            onAccent: Color(hex: onAccent),

            accent: Color(hex: accent),
            accentSecondary: Color(hex: accentSecondary),
            success: Color(hex: "78B89A"),
            warning: Color(hex: "D6AD6E"),
            error: Color(hex: "D98282"),

            gradientStart: Color(hex: gradient.0),
            gradientEnd: Color(hex: gradient.1),

            page: Color(hex: elevated),
            scrim: Color.black.opacity(0.55)
        )
    }

    // MARK: Sunset (light)

    static let sunset = light(
        background: "FDEBE3", gradient: ("FFE2CF", "FBC9D8"),
        accent: "C2410C", accentSecondary: "DB2777",
        text: ("2B1A14", "5C4339", "7D635A"), scrim: "2A0F08"
    )

    // MARK: Rose (light)

    static let rose = light(
        background: "FDEFF2", gradient: ("FBE1E8", "FFF1E6"),
        accent: "BE185D", accentSecondary: "8B5CF6",
        text: ("2A1520", "5E3C4A", "7E5C6A"), scrim: "2A0A18"
    )

    // MARK: Sand (light)

    static let sand = light(
        background: "F4ECDD", gradient: ("F6EBD5", "E8D9BC"),
        accent: "8A5A12", accentSecondary: "0F766E",
        text: ("2B2418", "5A4E3A", "7A6D55"), scrim: "221A0C"
    )

    // MARK: Sky (light)

    static let sky = light(
        background: "E6F1FB", gradient: ("D6EAFB", "DDF5EE"),
        accent: "0369A1", accentSecondary: "0D9488",
        text: ("132436", "435468", "5F7085"), scrim: "0A1A2E"
    )

    // MARK: Forest (dark)

    static let forest = dark(
        background: "0C1712", gradient: ("0B1A14", "163B2A"), elevated: "1B2E25",
        accent: "6FCF97", accentSecondary: "E3B866", onAccent: "0B1A14",
        text: ("E6F4EC", "A9C4B6", "9ABAA9")
    )

    // MARK: Slate (dark)

    static let slate = dark(
        background: "10141A", gradient: ("141A22", "1E2733"), elevated: "232E3B",
        accent: "8AB4F8", accentSecondary: "F2A97E", onAccent: "141A22",
        text: ("EAEFF5", "AAB4C2", "9AA7B8")
    )

    // MARK: Graphite (dark)

    static let graphite = dark(
        background: "121212", gradient: ("141414", "232323"), elevated: "2A2A2A",
        accent: "FDBA74", accentSecondary: "A5B4FC", onAccent: "141414",
        text: ("F2F2F2", "B3B3B3", "A0A0A0")
    )

    // MARK: Plum (dark)

    static let plum = dark(
        background: "150B1E", gradient: ("170C22", "34154A"), elevated: "2A1B38",
        accent: "D8A0FF", accentSecondary: "FF8FB8", onAccent: "170C22",
        text: ("F5ECFB", "C4B0D4", "AD99BD")
    )

    // MARK: Aurora (dark)

    static let aurora = dark(
        background: "08141C", gradient: ("0A2230", "2A1F55"), elevated: "162B3B",
        accent: "5EEAD4", accentSecondary: "C4B5FD", onAccent: "0A2230",
        text: ("E8F6F6", "A7C4C9", "8FB0B8")
    )

    // MARK: Ember (dark)

    static let ember = dark(
        background: "170E0B", gradient: ("1A0F0B", "3A1A10"), elevated: "2D1B15",
        accent: "FB923C", accentSecondary: "F87171", onAccent: "1A0F0B",
        text: ("F8EDE6", "CDB3A5", "B39D90")
    )
}

// MARK: - Theme Store

/// Holds the selected theme. The selection is stored in UserDefaults
/// (a lightweight preference, not SwiftData) so it survives relaunch.
///
/// `AppearanceSettings` is the only place that changes the theme; it
/// also tells the UI to rebuild. Everything else just reads.
enum RBThemeStore {

    static let storageKey = "appearance.theme"

    nonisolated(unsafe) private static var cachedID: RBThemeID?

    static var currentID: RBThemeID {
        get {
            if let cachedID { return cachedID }

            let stored = UserDefaults.standard.string(forKey: storageKey)
            let resolved = stored.flatMap(RBThemeID.init(rawValue:))
                ?? RBThemeID.default

            cachedID = resolved
            return resolved
        }
        set {
            cachedID = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }

    static var palette: RBPalette {
        currentID.palette
    }

    // MARK: Accent override (Phase 14)

    static let accentOverrideKey = "appearance.accentOverride"

    // `loaded` distinguishes "not read yet" from "read, and nothing is
    // set" (nil), so the UserDefaults lookup happens only once.
    nonisolated(unsafe) private static var accentOverrideLoaded = false
    nonisolated(unsafe) private static var cachedAccentOverride: String?

    /// A person-chosen accent as 6-digit hex ("7C3AED", no "#"), or nil
    /// when the theme's own accent is in use.
    ///
    /// Like the theme, only `AppearanceSettings` should change this,
    /// because it also tells the UI to rebuild. Invalid values are
    /// ignored (treated as "no override") so a corrupted preference
    /// can never produce a broken color.
    static var accentOverrideHex: String? {
        get {
            if accentOverrideLoaded { return cachedAccentOverride }

            let stored = UserDefaults.standard.string(forKey: accentOverrideKey)
            cachedAccentOverride = stored.flatMap { normalizedHex($0) }
            accentOverrideLoaded = true
            return cachedAccentOverride
        }
        set {
            let normalized = newValue.flatMap { normalizedHex($0) }
            cachedAccentOverride = normalized
            accentOverrideLoaded = true

            if let normalized {
                UserDefaults.standard.set(normalized, forKey: accentOverrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: accentOverrideKey)
            }
        }
    }

    /// "#7c3aed" / "7C3AED" -> "7C3AED". Anything that is not exactly
    /// six hex digits -> nil.
    static func normalizedHex(_ raw: String) -> String? {
        let cleaned = raw
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .uppercased()
        guard cleaned.count == 6,
              cleaned.allSatisfy({ $0.isHexDigit }) else { return nil }
        return cleaned
    }

    /// Whether a color is light enough that dark text is the readable
    /// choice on top of it (used for text on a custom accent fill).
    static func prefersDarkText(onHex hex: String) -> Bool {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)

        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255

        // Perceived brightness (Rec. 601 weights).
        return (0.299 * red + 0.587 * green + 0.114 * blue) > 0.62
    }
}

// MARK: - Semantic Color Tokens

/// Semantic colors used across the whole app. Each token resolves
/// against the selected theme at the moment it is read, so a theme
/// change followed by a root-view rebuild restyles every screen.
enum RBColor {

    // Surfaces
    static var background: Color { RBThemeStore.palette.background }
    static var sidebar: Color { RBThemeStore.palette.sidebar }
    static var surface: Color { RBThemeStore.palette.surface }
    static var card: Color { RBThemeStore.palette.card }
    static var elevatedSurface: Color { RBThemeStore.palette.elevatedSurface }
    /// Alias for elevatedSurface — used by sheet backgrounds.
    static var elevated: Color { RBThemeStore.palette.elevatedSurface }
    static var inputBackground: Color { RBThemeStore.palette.inputBackground }

    // Interaction
    //
    // `hover`, `selected` and `border` are built from the accent in
    // Lavender, so they follow a custom accent (Phase 14). Midnight's
    // selection is a soft tint of the accent, so it follows too; its
    // hover and border are neutral greys and stay as they are.
    static var hover: Color {
        if let hex = RBThemeStore.accentOverrideHex,
           RBThemeStore.currentID.colorScheme == .light {
            return Color(hex: hex).opacity(0.08)
        }
        return RBThemeStore.palette.hover
    }

    static var selected: Color {
        if let hex = RBThemeStore.accentOverrideHex {
            return RBThemeStore.currentID.colorScheme == .light
                ? Color(hex: hex)
                : Color(hex: hex).opacity(0.18)
        }
        return RBThemeStore.palette.selected
    }

    static var border: Color {
        if let hex = RBThemeStore.accentOverrideHex,
           RBThemeStore.currentID.colorScheme == .light {
            return Color(hex: hex).opacity(0.16)
        }
        return RBThemeStore.palette.border
    }

    // Text
    static var primaryText: Color { RBThemeStore.palette.primaryText }
    static var secondaryText: Color { RBThemeStore.palette.secondaryText }
    static var mutedText: Color { RBThemeStore.palette.mutedText }

    /// Text/icon color to use on top of `selected`.
    /// In Lavender `selected` is a solid accent fill, so with a custom
    /// accent the text color is chosen for contrast (a pale accent
    /// gets dark text instead of white).
    static var selectedText: Color {
        if let hex = RBThemeStore.accentOverrideHex,
           RBThemeStore.currentID.colorScheme == .light {
            return RBThemeStore.prefersDarkText(onHex: hex)
                ? Color(hex: "1E1A2E")
                : Color.white
        }
        return RBThemeStore.palette.selectedText
    }

    /// Text/icon color to use on top of a solid `accent` fill.
    /// With a custom accent it is chosen for contrast.
    static var onAccent: Color {
        if let hex = RBThemeStore.accentOverrideHex {
            return RBThemeStore.prefersDarkText(onHex: hex)
                ? Color(hex: "1E1A2E")
                : Color.white
        }
        return RBThemeStore.palette.onAccent
    }

    // Accents and status

    /// The theme's accent, or the person's custom accent when one is
    /// set (Settings -> Appearance).
    static var accent: Color {
        if let hex = RBThemeStore.accentOverrideHex {
            return Color(hex: hex)
        }
        return RBThemeStore.palette.accent
    }
    static var accentSecondary: Color { RBThemeStore.palette.accentSecondary }
    static var success: Color { RBThemeStore.palette.success }
    static var warning: Color { RBThemeStore.palette.warning }
    static var error: Color { RBThemeStore.palette.error }

    // Manuscript page background and the dark overlay (scrim).
    static var page: Color { RBThemeStore.palette.page }
    static var scrim: Color { RBThemeStore.palette.scrim }

    // HTML hover / selected tints. Both are the accent at a fixed
    // opacity, so they work in both themes and follow a custom accent.
    static var hoverTint: Color { accent.opacity(RBTint.hover) }
    static var selectedTint: Color { accent.opacity(RBTint.selected) }

    /// Window backdrop gradient (every theme has one).
    static var backgroundGradient: LinearGradient {
        let palette = RBThemeStore.palette
        return LinearGradient(
            colors: [palette.gradientStart, palette.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)

        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)

        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255

        self.init(
            red: red,
            green: green,
            blue: blue
        )
    }
}

// MARK: - Theme Modifiers

extension View {

    /// Paints the theme's window backdrop behind the view, extending
    /// under the toolbar area.
    func rbWindowBackground() -> some View {
        background(RBColor.backgroundGradient.ignoresSafeArea())
    }

    /// Applies the color scheme that matches the selected theme, so
    /// system controls (text fields, menus, sheets) match too.
    func rbApplyThemeColorScheme() -> some View {
        preferredColorScheme(RBThemeStore.currentID.colorScheme)
    }
}

// MARK: - Radius

enum RBRadius {
    static let control: CGFloat = 9
    static let card: CGFloat = 10

    // From the HTML prototype.
    static let sidebarItem: CGFloat = 8   // sidebar rows
    static let field: CGFloat = 9         // rows, inputs, buttons
    static let panel: CGFloat = 10        // cards
    static let manuscript: CGFloat = 12   // manuscript cards
    static let page: CGFloat = 6          // the paper "sheet"
}

// MARK: - Spacing

/// Reusable spacing scale for screen-level content padding.
/// Use `RBSpacing` directly for fixed gaps (between rows, inside
/// cards, etc). For a screen's outer content padding, prefer
/// `.rbResponsiveContentPadding()` below so it adapts to window size
/// instead of staying fixed at the "large window" value.
enum RBSpacing {
    static let compact: CGFloat = 12
    static let regular: CGFloat = 20
    static let spacious: CGFloat = 28
}

/// Window-width breakpoints. No longer `private`, so ContentView and
/// the screens can read them.
enum RBBreakpoint {
    /// Below this the sidebar becomes the 58pt rail.
    static let compact: CGFloat = 860
    /// Below this master/detail screens go single-column.
    static let stacked: CGFloat = 640
    /// Below this the writing info panel becomes an overlay.
    static let infoOverlay: CGFloat = 1000
    /// Below this the writing outline becomes a horizontal strip.
    static let outlineStrip: CGFloat = 720

    // Padding-only tier used by `rbResponsiveContentPadding` below.
    // It has no locked layout meaning. The 1000pt tier reuses
    // `infoOverlay`.
    static let medium: CGFloat = 1300
}

/// Fixed sizes from the HTML prototype.
enum RBLayout {
    static let sidebarItemHeight: CGFloat = 32
    static let pageTop: CGFloat = 22
    static let pageSide: CGFloat = 26
    static let pageBottom: CGFloat = 36
    static let manuscriptEdge: CGFloat = 5       // colored left edge
    static let outlineWidth: CGFloat = 220       // writing outline column
    static let infoWidth: CGFloat = 270          // writing info column
    static let paperMaxWidth: CGFloat = 760      // the paper sheet
}

/// Opacity of the accent tint used for hover and selected rows.
enum RBTint {
    static let hover: Double = 0.09
    static let selected: Double = 0.16
}

/// Reader focus mode (Full Page). Everything except the reader is
/// blurred, dimmed and made untouchable.
enum RBFocus {
    static let blurRadius: CGFloat = 12
    static let dimOpacity: Double = 0.5
    static var animation: Animation { .easeInOut(duration: 0.2) }
}

private struct RBWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = RBBreakpoint.infoOverlay
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct RBResponsivePadding: ViewModifier {
    var edges: Edge.Set

    // Seeded at the "regular" tier so the first frame doesn't flash
    // the compact padding before the background reader reports a
    // real width.
    @State private var width: CGFloat = RBBreakpoint.infoOverlay

    func body(content: Content) -> some View {
        content
            .padding(edges, Self.value(for: width))
            // Measured via a zero-size background reader (not by
            // wrapping the content in GeometryReader) so this never
            // fights a parent ScrollView over how tall/wide the
            // content is allowed to be.
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: RBWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(RBWidthKey.self) { newWidth in
                width = newWidth
            }
    }

    static func value(for width: CGFloat) -> CGFloat {
        switch width {
        case ..<RBBreakpoint.infoOverlay:
            return RBSpacing.compact
        case RBBreakpoint.infoOverlay..<RBBreakpoint.medium:
            return RBSpacing.regular
        default:
            return RBSpacing.spacious
        }
    }
}

extension View {
    /// Applies content padding that scales with the available width:
    /// ~12–16 below 1000pt, ~18–24 up to 1300pt, ~24–32 above that.
    /// Intended for a screen's single outermost content container —
    /// not for every inner card/row padding.
    func rbResponsiveContentPadding(_ edges: Edge.Set = .all) -> some View {
        modifier(RBResponsivePadding(edges: edges))
    }
}


// MARK: - Focus Mode

extension View {
    /// Blurs and dims the view, and blocks clicks, while `isOn` is true.
    /// ContentView puts this on the sidebar only. The top strip is
    /// faded through `toolbarBackground` instead, because SwiftUI
    /// cannot blur the system toolbar.
    func rbFocusDimmed(_ isOn: Bool) -> some View {
        self
            .blur(radius: isOn ? RBFocus.blurRadius : 0)
            .opacity(isOn ? RBFocus.dimOpacity : 1)
            .allowsHitTesting(!isOn)
            .accessibilityHidden(isOn)
            .animation(RBFocus.animation, value: isOn)
    }
}


// MARK: - Text Editor Style

extension View {
    /// Themed multi-line editor: transparent system background, themed
    /// inset field with a border, and enough inner padding that text
    /// never touches the edges (TextEditor has almost no inset of its
    /// own on macOS).
    func rbTextEditorStyle(minHeight: CGFloat = 90) -> some View {
        self
            .scrollContentBackground(.hidden)
            .foregroundStyle(RBColor.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(minHeight: minHeight)
            .background(RBColor.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: RBRadius.control))
            .overlay(
                RoundedRectangle(cornerRadius: RBRadius.control)
                    .stroke(RBColor.border)
            )
    }
}


// MARK: - Master / Detail Layout

/// Two-pane layout (list + detail) that always fits the space it is
/// given. Plain `HStack`s with `minWidth` frames let the panes' own
/// minimum sizes push the layout wider than the window, so the list
/// slides under the sidebar and the detail runs off the right edge.
/// Here the widths are computed from the available width and each pane
/// is given an exact, clipped frame, so nothing can overflow.
///
/// Phase 14 — stacked mode. When the caller passes a `showDetail`
/// binding AND the available width is below `stackBreakpoint`, the two
/// panes are shown one at a time: the master (list) fills the width,
/// and when `showDetail` is true the detail fills it instead, under a
/// slim "‹ Back" bar that sets `showDetail` back to false. The screen
/// owns `showDetail` (set it true when the user picks an item), so
/// selection stays entirely in the screen. With `showDetail == nil`
/// (the default) the layout is always side-by-side, exactly as before,
/// so existing call sites are unaffected until they opt in.
struct RBMasterDetail<Master: View, Detail: View>: View {

    private let masterMin: CGFloat
    private let masterIdeal: CGFloat
    private let masterFraction: CGFloat
    private let stackBreakpoint: CGFloat
    private let showDetail: Binding<Bool>?
    private let backTitle: String

    private let master: () -> Master
    private let detail: () -> Detail

    init(
        masterMin: CGFloat = 240,
        masterIdeal: CGFloat = 340,
        masterFraction: CGFloat = 0.38,
        stackBreakpoint: CGFloat = 640,
        showDetail: Binding<Bool>? = nil,
        backTitle: String = "Back",
        @ViewBuilder master: @escaping () -> Master,
        @ViewBuilder detail: @escaping () -> Detail
    ) {
        self.masterMin = masterMin
        self.masterIdeal = masterIdeal
        self.masterFraction = masterFraction
        self.stackBreakpoint = stackBreakpoint
        self.showDetail = showDetail
        self.backTitle = backTitle
        self.master = master
        self.detail = detail
    }

    var body: some View {
        GeometryReader { proxy in
            // Stacked only when the caller opted in with a binding.
            if let detailBinding = showDetail,
               proxy.size.width < stackBreakpoint {
                stackedLayout(detailBinding, size: proxy.size)
            } else {
                sideBySideLayout(size: proxy.size)
            }
        }
    }

    // MARK: Side by side (unchanged behavior)

    private func sideBySideLayout(size: CGSize) -> some View {
        let total = size.width
        let masterWidth = min(
            masterIdeal,
            max(masterMin, total * masterFraction)
        )
        let detailWidth = max(total - masterWidth - 1, 0)

        return HStack(spacing: 0) {
            master()
                .frame(width: masterWidth, height: size.height)
                .clipped()

            Rectangle()
                .fill(RBColor.border)
                .frame(width: 1)

            detail()
                .frame(width: detailWidth, height: size.height)
                .clipped()
        }
    }

    // MARK: Stacked

    private func stackedLayout(_ detailBinding: Binding<Bool>, size: CGSize) -> some View {
        let isShowingDetail = detailBinding.wrappedValue

        return ZStack {
            if isShowingDetail {
                VStack(spacing: 0) {
                    backBar(detailBinding)

                    Divider().overlay(RBColor.border)

                    detail()
                        .frame(width: size.width)
                        .frame(maxHeight: .infinity)
                        .clipped()
                }
                .transition(
                    .move(edge: .trailing).combined(with: .opacity)
                )
            } else {
                master()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .animation(.easeInOut(duration: 0.18), value: isShowingDetail)
    }

    private func backBar(_ detailBinding: Binding<Bool>) -> some View {
        HStack {
            Button {
                detailBinding.wrappedValue = false
            } label: {
                Label(backTitle, systemImage: "chevron.left")
                    .font(RBFont.secondary(.medium))
                    .foregroundStyle(RBColor.accent)
            }
            .buttonStyle(.plain)
            .help(backTitle)

            Spacer()
        }
        .padding(.horizontal, RBSpacing.compact)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(RBColor.surface)
    }
}
