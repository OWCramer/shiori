import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A patch dragged onto a game from Files or another app: a zip, 7z or rar archive, or a
/// folder. The system's copy is only valid during the drop, so it's copied into a folder
/// of Shiori's own (deleted once imported).
struct DroppedPatch: Transferable {
    let url: URL

    static let sevenZip = UTType("org.7-zip.7-zip-archive") ?? .archive
    static let rar = UTType("com.rarlab.rar-archive") ?? .archive

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .zip, shouldAttemptToOpenInPlace: false) { try copy($0.file) }
        FileRepresentation(importedContentType: sevenZip, shouldAttemptToOpenInPlace: false) { try copy($0.file) }
        FileRepresentation(importedContentType: rar, shouldAttemptToOpenInPlace: false) { try copy($0.file) }
        FileRepresentation(importedContentType: .folder, shouldAttemptToOpenInPlace: false) { try copy($0.file) }
    }

    private static func copy(_ file: URL) throws -> DroppedPatch {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropped-patch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: destination)
        return DroppedPatch(url: destination)
    }
}
