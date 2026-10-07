import SwiftUI

@main
struct VNHubApp: App {
    @State private var steam = SteamModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(steam)
        }
    }
}

struct RootView: View {
    @Environment(SteamModel.self) private var steam

    var body: some View {
        if steam.isLoggedOn || steam.hasStoredSession {
            LibraryView()
        } else {
            SignInView()
        }
    }
}
