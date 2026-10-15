#if os(iOS)
import SwiftUI

/// One bundled component and its licence, read from `Acknowledgements/acknowledgements.json`
/// (kept in step with docs/licences.md).
struct Acknowledgement: Decodable, Identifiable, Hashable {
    let name: String
    let version: String?
    let licence: String
    /// The licence text's file in the bundle's `Acknowledgements` folder.
    let file: String

    var id: String { name }

    static let all: [Acknowledgement] = {
        guard let url = Bundle.main.url(forResource: "acknowledgements", withExtension: "json", subdirectory: "Acknowledgements"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Acknowledgement].self, from: data)
        else { return [] }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    var text: String {
        guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "Acknowledgements"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return text
    }
}

/// Settings › About › Acknowledgements: every component Shiori ships, with its licence.
struct AcknowledgementsScreen: View {
    var body: some View {
        List(Acknowledgement.all) { item in
            NavigationLink {
                AcknowledgementText(item: item)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                    Text(item.licence)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Acknowledgements")
        .inlineNavigationTitle()
    }
}

private struct AcknowledgementText: View {
    let item: Acknowledgement
    /// Paragraphs, so long texts (the Rust crates, the GPL) lay out lazily.
    @State private var paragraphs: [String] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(paragraphs.indices, id: \.self) { index in
                    Text(paragraphs[index])
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .task {
            paragraphs = item.text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        }
        .navigationTitle(item.name)
        .inlineNavigationTitle()
    }
}
#endif
