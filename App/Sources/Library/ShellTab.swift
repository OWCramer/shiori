/// The library's tabs (design A), and on iPad the sidebar's items: the same set, with
/// Recently Played, an engine section and Settings in the sidebar only.
enum ShellTab: Hashable, RawRepresentable {
    case home, visualNovels, installed, recentlyPlayed, downloads, search, settings
    /// Games on one engine (`EngineMatch.engine`), or `LibrarySection.notPlayable`.
    case engine(String)
    /// Every collection, and one collection (iPad sidebar).
    case collections
    case collection(String)

    init?(rawValue: String) {
        switch rawValue {
        case "home": self = .home
        case "visualNovels": self = .visualNovels
        case "installed": self = .installed
        case "recentlyPlayed": self = .recentlyPlayed
        case "downloads": self = .downloads
        case "search": self = .search
        case "settings": self = .settings
        case "collections": self = .collections
        default:
            if rawValue.hasPrefix("collection:") {
                self = .collection(String(rawValue.dropFirst("collection:".count)))
                return
            }
            guard rawValue.hasPrefix("engine:") else { return nil }
            self = .engine(String(rawValue.dropFirst("engine:".count)))
        }
    }

    var rawValue: String {
        switch self {
        case .home: "home"
        case .visualNovels: "visualNovels"
        case .installed: "installed"
        case .recentlyPlayed: "recentlyPlayed"
        case .downloads: "downloads"
        case .search: "search"
        case .settings: "settings"
        case let .engine(key): "engine:\(key)"
        case .collections: "collections"
        case let .collection(id): "collection:\(id)"
        }
    }
}
