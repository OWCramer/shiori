#if os(iOS)
import SwiftUI

/// `ControlsGuide`'s sheet: before a first launch (Got It plays), or from a game's More menu
/// (Done). Dark like the rest of the Showcase design. In controller mode the pad answers it:
/// A is Got It (or Done), B closes it without playing.
struct ControlsGuideSheet: View {
    let request: ControlsGuide.Request
    @Environment(GameLibrary.self) private var games
    @Environment(ControllerInput.self) private var pad
    @Environment(\.dismiss) private var dismiss
    @State private var launcherHandler: ((PadAction) -> Void)?

    var body: some View {
        Group {
            if request.playAfter != nil {
                ControlsGuideView(controls: ControlsTable.controls(for: request.engine),
                                  gameName: request.gameName, onContinue: proceed)
            } else {
                NavigationStack {
                    ControlsGuideView(controls: ControlsTable.controls(for: request.engine), gameName: request.gameName)
                        .navigationTitle("Controls")
                        .inlineNavigationTitle()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done", action: close)
                            }
                        }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: takePad)
        .onDisappear(perform: returnPad)
    }

    private func close() { dismiss() }

    /// Got It (or Don't Show Again): the guide is done for this engine and the game starts
    /// once the sheet is gone, so the launch cover (or Ren'Py's window) never fights it.
    private func proceed(turnOff: Bool) {
        let guide = ControlsGuide.shared
        guide.markSeen(request.engine)
        if turnOff { guide.turnOff() }
        let appID = request.playAfter
        let games = games
        dismiss()
        guard let appID, appID != 0 else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            games.play(appID: appID)
        }
    }

    private func takePad() {
        guard pad.isActive else { return }
        launcherHandler = pad.handler
        pad.handler = { action in
            switch action {
            case .a: if request.playAfter != nil { proceed(turnOff: false) } else { close() }
            case .b: close()
            default: break
            }
        }
    }

    private func returnPad() {
        guard pad.isActive else { return }
        pad.handler = launcherHandler
    }
}
#endif
