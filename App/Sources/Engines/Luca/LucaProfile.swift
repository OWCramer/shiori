import CoreGraphics
import LucaKit

/// What one Luca System game's executable draws for itself, which Shiori rebuilds from the
/// game's art: the title and boot logos, the system menu, the page marker, the shortcut
/// buttons and the like. Everything else (archives, scripts, pictures, fonts, movies, saves,
/// the Prototype UI kit's OPTIONS / Save / Load / Message Log art) is shared by every Luca game.
///
/// A game is recognised by its art, not its Steam id, so another port that ships the same art
/// gets the same screens; a game Shiori doesn't know gets `plain`, with Shiori's stand-ins
/// wherever its art is missing.
struct LucaProfile {
    enum Title {
        /// The summer sky panning down to the heroines, the word row (REFLECTION BLUE).
        case reflectionBlue
        /// A still picture, the logo, a column of words from a two-column sheet (Harmonia
        /// Full HD: `title_menu`, plain words left, lit right, 110 px rows).
        case column(background: String, logo: String, menu: String, rowHeight: Int, copyright: String?)
        /// No title art: Shiori's own plain title.
        case plain
    }

    enum SystemMenu {
        /// `systemmenuen`: a 5×4 grid of 315 px cells (REFLECTION BLUE).
        case grid(String)
        /// `system_icon_1920_en`: nine 270 px icons, plain over lit, on `system_BG`.
        case icons(sheet: String, background: String?)
    }

    /// The message window and its text, in the game's 1920×1080 space.
    struct Window {
        /// Where `MWIN0` (the window's shape in white) is drawn, and in what colour.
        var rect: CGRect
        var colour: SIMD3<Float>
        /// Its opacity at the OPTIONS transparency slider's middle.
        var opacity: Float
        /// Where glyph cells start (`textLeft` beside a face), the line's and name's tops,
        /// the wrapping width and line pitch, and the outline's width.
        var textLeft: CGFloat
        var textLeftWithFace: CGFloat
        var textTop: CGFloat
        var nameTop: CGFloat
        var textWidth: Int
        var lineHeight: Int
        var outline: Int
        var pageMarker: CGRect
    }

    var name: String
    var title: Title
    var window: Window
    /// Pictures shown full screen on white before the title, in order.
    var bootPictures: [String]
    var titleMusic: Int?
    var systemMenu: SystemMenu?
    /// The page marker: its sheet and, when animated, the size of a frame.
    var pageMarker: (name: String, frame: Int?)?
    /// MENU / SKIP / AUTO / VOICE beside the window (`legacy_pt`).
    var shortcutSheet: String?
    var choiceSheet: String?
    var mapImage: String?
    /// The voiced characters' faces for OPTIONS › Voice: a row of square cells.
    var voiceFaces: (name: String, cell: Int)?
    var saveBlank: [String]
    var saveCursor: [String]

    /// REFLECTION BLUE's, measured against its Steam screenshots: a teal band, text at 37 px.
    static let tealWindow = Window(
        rect: CGRect(x: 0, y: 691, width: 1920, height: 389), colour: SIMD3(0, 0.745, 0.765), opacity: 0.45,
        textLeft: 396, textLeftWithFace: 474, textTop: 855, nameTop: 791, textWidth: 1300, lineHeight: 56, outline: 2,
        pageMarker: CGRect(x: 1640, y: 996, width: 72, height: 72))

    static let reflectionBlue = LucaProfile(
        name: "Summer Pockets REFLECTION BLUE", title: .reflectionBlue, window: tealWindow,
        bootPictures: ["warning_en", "logo1", "logo0", "logo2b"], titleMusic: 100_001,
        systemMenu: .grid("systemmenuen"), pageMarker: ("__SYS_MW01_KEY00", 72), shortcutSheet: "legacy_pt",
        choiceSheet: "__SYS_SEL_BTN02", mapImage: "__SYS_MAP_BG01en", voiceFaces: ("VOICE_ICONRB", 111),
        saveBlank: ["SAVE_BLANK"], saveCursor: ["save_cursor"])

    static let harmonia = LucaProfile(
        name: "Harmonia Full HD Edition",
        title: .column(background: "title_bg2", logo: "title_logo", menu: "title_menu", rowHeight: 110, copyright: "title_copy"),
        // A translucent black box inset from the edges; no speaker names (measured from the
        // Steam screenshots: text from x 248, y 848, lines 64 apart).
        window: Window(rect: CGRect(x: 0, y: 675, width: 1920, height: 405), colour: SIMD3(0, 0, 0), opacity: 0.6,
                       textLeft: 246, textLeftWithFace: 246, textTop: 848, nameTop: 784, textWidth: 1420, lineHeight: 64,
                       outline: 1, pageMarker: CGRect(x: 1664, y: 984, width: 45, height: 45)),
        bootPictures: ["warning_en", "logo1920_1", "logo1920_0", "logo1920_2", "logo1920_3"], titleMusic: 100_001,
        systemMenu: .icons(sheet: "system_icon_1920_en", background: "system_BG"), pageMarker: ("CURSOR", 45),
        shortcutSheet: nil, choiceSheet: nil, mapImage: nil, voiceFaces: ("voice_pt", 96),
        saveBlank: ["save_blank", "SAVE_BLANK"], saveCursor: ["save_blank_ov", "save_cursor"])

    /// For a game Shiori has no profile for: the shared kit, Shiori's stand-ins for the rest.
    static let plain = LucaProfile(
        name: "Luca System game", title: .plain, window: tealWindow, bootPictures: [], titleMusic: nil,
        systemMenu: nil, pageMarker: nil, shortcutSheet: nil, choiceSheet: nil, mapImage: nil, voiceFaces: nil,
        saveBlank: ["save_blank", "SAVE_BLANK"], saveCursor: ["save_blank_ov", "save_cursor"])

    /// The profile whose art the game has.
    static func detect(_ game: LucaGame) -> LucaProfile {
        if game.imageID(named: "__SYS_RBLOGO02a") != nil { return .reflectionBlue }
        if game.imageID(named: "title_menu") != nil, game.imageID(named: "title_bg2") != nil { return .harmonia }
        return .plain
    }
}
