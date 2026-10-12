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
            } footer: {
                Text("Shiori shows a game's controls the first time you play a game on each engine. A game's More menu has them too.")
            }
            Section {
                Button("Show Before Playing Again", action: reset)
            } footer: {
                Text("The controls show again the next time you play a game on each engine.")
            }
        }
        .navigationTitle("Controls")
    }

    private func reset() { ControlsGuide.shared.reset() }
}
#endif
