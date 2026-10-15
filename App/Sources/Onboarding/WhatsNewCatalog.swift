// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

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
                    detail: "Home leads with your last game, game pages open on its art, iPad has a sidebar, and iPhone Duo shows a game beside your library."
                ),
                WhatsNewFeature(
                    systemImage: "bandage",
                    title: "Patches on Every Game Page",
                    detail: "Official and community patches install in a tap."
                ),
                WhatsNewFeature(
                    systemImage: "pawprint",
                    title: "NEKOPARA Vol. 3",
                    detail: "CatSystem2 games play, with their own menus, animated characters and movies."
                ),
                WhatsNewFeature(
                    systemImage: "icloud.and.arrow.up",
                    title: "Saves Sync When You Leave",
                    detail: "Saves go up to iCloud and Steam Cloud when you leave a game or switch apps."
                ),
                WhatsNewFeature(
                    systemImage: "line.3.horizontal.decrease.circle",
                    title: "Filters",
                    detail: "Narrow Visual Novels and Installed by engine or compatibility."
                ),
            ]
        ),
    ]

    static var latest: WhatsNewRelease? { releases.last }
}
#endif
