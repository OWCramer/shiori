#if os(iOS)
import SwiftUI

/// How to play a game on one engine: its gestures, and the trackpad, keyboard and controller
/// equivalents. Before a first launch only the inputs connected now are listed, with Got It
/// (which starts the game) and Don't Show Again; elsewhere every input is listed.
struct ControlsGuideView: View {
    let controls: EngineControls
    var gameName: String?
    /// Set before a launch: the game starts when it's called (`true`: don't show the guide again).
    var onContinue: ((_ turnOff: Bool) -> Void)?

    @State private var connected: [ControlsInput] = [.touch]

    private var isBeforePlay: Bool { onContinue != nil }

    private var inputs: [ControlsInput] {
        isBeforePlay ? connected : ControlsInput.allCases
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                ForEach(inputs) { input in
                    section(input)
                }
                if isBeforePlay {
                    Text("You can see this again from a game's More menu, or in Settings › Controls.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, isBeforePlay ? 40 : 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            if let onContinue { buttons(onContinue) }
        }
        .background(Color.black)
        .onAppear(perform: refreshConnected)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isBeforePlay {
                Image(systemName: "hand.tap")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.pink)
                    .accessibilityHidden(true)
                Text("How to Play")
                    .font(.largeTitle.bold())
            }
            Text(subtitle)
                .font(isBeforePlay ? .headline : .subheadline)
                .foregroundStyle(.secondary)
            if let note = controls.note {
                Text(note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subtitle: String {
        let engine = EngineDetection.displayName(for: controls.engine)
        if let gameName { return "\(gameName) · \(engine)" }
        return "Games on \(engine)"
    }

    private func section(_ input: ControlsInput) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(input.title, systemImage: input.systemImage)
                .font(.title3.bold())
            let rows = controls.rows(for: input)
            if rows.isEmpty {
                Text(controls.noController)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.self) { row in
                    ControlRowView(row: row)
                }
            }
        }
    }

    private func buttons(_ onContinue: @escaping (Bool) -> Void) -> some View {
        VStack(spacing: 10) {
            Button { onContinue(false) } label: {
                Text("Got It")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.pink)
            .keyboardShortcut(.defaultAction)
            Button("Don't Show Again") { onContinue(true) }
                .font(.subheadline)
                .tint(.secondary)
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        // Solid under the buttons, fading out above them, so the list scrolls away beneath.
        .background {
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black, location: 0.3)],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -24)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func refreshConnected() {
        connected = ControlsInput.allCases.filter(\.isConnected)
    }
}
#endif
