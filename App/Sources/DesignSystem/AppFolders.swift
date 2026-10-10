import Foundation

/// Where Shiori keeps things. On iOS: games in Documents (visible in the Files app) and
/// state in Application Support. Apple TV gives apps no permanent storage, only caches the
/// system may clear when space runs low, so both live there; a cleared game re-downloads,
/// and saves are kept off the box (iCloud, Steam Cloud). See spec, Apple TV.
extension URL {
    static var shioriDocuments: URL {
        #if os(tvOS)
        URL.cachesDirectory.appendingPathComponent("Documents", isDirectory: true)
        #else
        URL.documentsDirectory
        #endif
    }

    static var shioriSupport: URL {
        #if os(tvOS)
        URL.cachesDirectory.appendingPathComponent("Application Support", isDirectory: true)
        #else
        URL.applicationSupportDirectory
        #endif
    }
}
