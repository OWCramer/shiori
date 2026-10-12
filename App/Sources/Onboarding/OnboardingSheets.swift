#if os(iOS)
import SwiftUI

/// What's New after an update, and the controls guide before a first launch on an engine (or
/// from a game's More menu), presented over the whole hub by `RootView`.
struct OnboardingSheets: ViewModifier {
    @State private var whatsNew = WhatsNew.shared
    @State private var controls = ControlsGuide.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $whatsNew.pending) { release in
                WhatsNewView(release: release, onContinue: whatsNew.dismiss)
                    .preferredColorScheme(.dark)
                    .interactiveDismissDisabled()
                    .presentationSizing(.page) // Taller than a form sheet on iPad: every row shows.
            }
            .sheet(item: $controls.request) { request in
                ControlsGuideSheet(request: request)
                    .presentationSizing(.page)
            }
            #if DEBUG
            .onAppear(perform: controls.showDebugRequest)
            #endif
    }
}
#endif
