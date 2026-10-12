#if os(iOS)
/// Every What's New, oldest first. For an update, add an entry at the end with a new `id`.
enum WhatsNewCatalog {
    static let releases: [WhatsNewRelease] = [
        WhatsNewRelease(
            id: "0.1.0-showcase",
            version: "0.1.0",
            features: [
                WhatsNewFeature(
                    systemImage: "sparkles.rectangle.stack",
                    title: "A New Look",
                    detail: "Home leads with the game you played last, game pages open on the game's art, iPad has a sidebar with your engines, and on iPhone Duo the game and your library sit side by side."
                ),
                WhatsNewFeature(
                    systemImage: "bandage",
                    title: "Patches on Every Game Page",
                    detail: "See the official and community patches for a game and install them in a tap, including Denpasoft's with your Denpasoft account."
                ),
                WhatsNewFeature(
                    systemImage: "pawprint",
                    title: "NEKOPARA Vol. 3",
                    detail: "CatSystem2 games now play, with the game's own screens, animated characters and movies."
                ),
                WhatsNewFeature(
                    systemImage: "icloud.and.arrow.up",
                    title: "Saves Sync When You Leave",
                    detail: "Like Steam, your saves go up to iCloud and Steam Cloud when you leave a game or switch apps."
                ),
                WhatsNewFeature(
                    systemImage: "line.3.horizontal.decrease.circle",
                    title: "Filters",
                    detail: "Narrow Visual Novels and Installed to what plays in Shiori, by engine or by compatibility."
                ),
            ]
        ),
    ]

    static var latest: WhatsNewRelease? { releases.last }
}
#endif
