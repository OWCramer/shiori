/// A game in a library tab with what the filters need about it, worked out once per update.
struct LibraryEntry: Identifiable {
    let game: LibraryGame
    let traits: GameTraits
    let isDownloaded: Bool
    var id: UInt32 { game.appID }
}
