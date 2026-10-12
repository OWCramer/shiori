#if os(iOS)
import SwiftUI

/// Settings' last section: the version, and the public lists Shiori reads.
struct SettingsAboutSection: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        Section {
            LabeledContent("Version", value: version)
            Link(destination: CompatibilityStore.repository) {
                Label("Compatibility List", systemImage: "checklist")
            }
            Link(destination: PatchListStore.repository) {
                Label("Patch List", systemImage: "bandage")
            }
        } header: {
            Text("About Shiori")
        } footer: {
            Text("Shiori is free software under the GPL-3.0. The compatibility and patch lists are public on GitHub; anyone can add to them.")
        }
    }
}
#endif
