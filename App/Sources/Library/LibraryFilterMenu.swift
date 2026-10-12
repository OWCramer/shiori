#if os(iOS)
import SwiftUI

/// The library tab's Filter menu: whether games play in Shiori, the compatibility list's
/// verdict, engine, and (on Visual Novels) downloaded or not. Each choice shows how many of
/// the tab's games it covers. The menu stays open while choosing.
struct LibraryFilterMenu: View {
    @Binding var filters: LibraryFilters
    /// The tab's games before filtering.
    let entries: [LibraryEntry]
    var showsDownload = true

    /// Engines among the tab's games, most games first, with their counts.
    private var engines: [(key: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in entries { counts[entry.traits.engine ?? LibraryFilters.uncheckedEngine, default: 0] += 1 }
        // A remembered choice stays, so it can be turned off, even with no games left.
        for key in filters.engines where counts[key] == nil { counts[key] = 0 }
        return counts.map { (key: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : LibraryFilters.engineName($0.key) < LibraryFilters.engineName($1.key) }
    }

    var body: some View {
        Menu {
            if filters.isActive {
                Button("Clear Filters", systemImage: "xmark.circle", action: clear)
                    .menuActionDismissBehavior(.enabled)
            }
            Picker("Show", selection: $filters.playability) {
                ForEach(LibraryFilters.Playability.allCases) { option in
                    Text("\(option.rawValue) (\(count(option)))").tag(option)
                }
            }
            .pickerStyle(.inline)
            Section("Compatibility List") {
                ForEach(LibraryFilters.Compatibility.allCases) { option in
                    Toggle("\(option.rawValue) (\(count(option)))", isOn: compatibilityBinding(option))
                }
            }
            Section("Engine") {
                ForEach(engines, id: \.key) { engine in
                    Toggle("\(LibraryFilters.engineName(engine.key)) (\(engine.count))", isOn: engineBinding(engine.key))
                }
            }
            if showsDownload {
                Picker("Downloads", selection: $filters.download) {
                    ForEach(LibraryFilters.Download.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            }
        } label: {
            Label("Filter", systemImage: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .menuActionDismissBehavior(.disabled)
    }

    private func count(_ option: LibraryFilters.Playability) -> Int {
        var only = LibraryFilters()
        only.playability = option
        return entries.filter { only.admits($0.traits, isDownloaded: $0.isDownloaded) }.count
    }

    private func count(_ option: LibraryFilters.Compatibility) -> Int {
        entries.filter { LibraryFilters.Compatibility($0.traits.compatibility) == option }.count
    }

    private func compatibilityBinding(_ option: LibraryFilters.Compatibility) -> Binding<Bool> {
        Binding {
            filters.compatibility.contains(option)
        } set: { on in
            if on { filters.compatibility.insert(option) } else { filters.compatibility.remove(option) }
        }
    }

    private func engineBinding(_ key: String) -> Binding<Bool> {
        Binding {
            filters.engines.contains(key)
        } set: { on in
            if on { filters.engines.insert(key) } else { filters.engines.remove(key) }
        }
    }

    private func clear() { filters = LibraryFilters() }
}
#endif
