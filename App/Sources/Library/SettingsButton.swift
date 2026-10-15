// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

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
