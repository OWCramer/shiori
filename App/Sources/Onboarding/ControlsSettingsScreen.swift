// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// Settings › Controls: each engine's guide, as shown before a first launch, with every input.
struct ControlsSettingsScreen: View {
    var body: some View {
        List {
            Section {
                ForEach(ControlsTable.engines, id: \.self) { engine in
                    NavigationLink(EngineDetection.displayName(for: engine)) {
                        ControlsGuideView(controls: ControlsTable.controls(for: engine))
                            .navigationTitle(EngineDetection.displayName(for: engine))
                            .inlineNavigationTitle()
                    }
                }
            }
            Section {
                Button("Show Before Playing Again", action: reset)
            } footer: {
                Text("Shows each engine's controls again the next time you play.")
            }
        }
        .navigationTitle("Controls")
    }

    private func reset() { ControlsGuide.shared.reset() }
}
#endif
