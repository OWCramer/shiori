import Foundation

/// Every collection edit, as synced through iCloud Keychain. Each device reads the synced
/// copy before writing, and the two are merged record by record, the newer record winning,
/// so edits made on the iPhone and the iPad close together both survive.
struct CollectionEdits: Codable, Equatable, Sendable {
    var records: [String: CollectionRecord] = [:]

    func merged(with other: CollectionEdits) -> CollectionEdits {
        var result = self
        for (id, record) in other.records {
            if let mine = result.records[id], mine.modified >= record.modified { continue }
            result.records[id] = record
        }
        return result
    }
}
