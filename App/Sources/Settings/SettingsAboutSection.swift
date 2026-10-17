// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// Settings' last section: the version, What's New, the controls guide, and the public lists Shiori reads.
struct SettingsAboutSection: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        Section {
            LabeledContent("Version", value: version)
            if let release = WhatsNewCatalog.latest {
                NavigationLink {
                    WhatsNewView(release: release)
                        .inlineNavigationTitle()
                } label: {
                    Label("What's New in Shiori", systemImage: "sparkles")
                }
            }
            NavigationLink {
                ControlsSettingsScreen()
            } label: {
                Label("Controls", systemImage: "hand.tap")
            }
            NavigationLink {
                AcknowledgementsScreen()
            } label: {
                Label("Acknowledgements", systemImage: "doc.text")
            }
            Link(destination: CompatibilityStore.website) {
                Label("Compatibility List", systemImage: "checklist")
            }
            Link(destination: PatchListStore.repository) {
                Label("Patch List", systemImage: "bandage")
            }
        } header: {
            Text("About Shiori")
        } footer: {
            Text("Shiori is free software under the MPL-2.0.")
        }
    }
}
#endif
