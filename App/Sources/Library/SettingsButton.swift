#if os(iOS)
import SwiftUI

/// Settings, from the toolbar of the library's screens.
struct SettingsButton: View {
    @Environment(ShellModel.self) private var shell

    var body: some View {
        Button("Settings", systemImage: "gearshape", action: shell.showSettings)
    }
}
#endif
