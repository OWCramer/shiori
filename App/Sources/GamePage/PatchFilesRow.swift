#if os(iOS)
import SwiftUI

/// What's in the game's `patch/` folder: a count, opening to the files themselves.
struct PatchFilesRow: View {
    let files: [PatchStore.PatchFile]
    @State private var expanded = false

    private static let shown = 50

    var body: some View {
        GamePageRow {
            if files.isEmpty {
                LabeledContent("Patch files", value: "None")
            } else {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(files.prefix(Self.shown)) { file in
                            HStack(alignment: .firstTextBaseline) {
                                Text(file.path).font(.footnote.monospaced()).lineLimit(2)
                                Spacer(minLength: 8)
                                if file.overridesBase {
                                    Text("Replaces").font(.footnote).foregroundStyle(.orange)
                                }
                            }
                        }
                        if files.count > Self.shown {
                            Text("and \(files.count - Self.shown) more").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    LabeledContent("Patch files", value: files.count.formatted())
                }
            }
        }
    }
}
#endif
