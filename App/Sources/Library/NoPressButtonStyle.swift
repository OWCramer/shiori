// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SwiftUI

/// A button whose label doesn't change while pressed: for large art that just opens a page
/// (Home's hero), where `.plain`'s dimming reads as the picture flickering.
struct NoPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(.rect)
    }
}
