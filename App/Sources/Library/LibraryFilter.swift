// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

/// The two lists the controller launcher and the Apple TV switch between with their tabs,
/// remembered under `libraryFilter`.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case visualNovels = "Visual Novels"
    case installed = "Installed"
    var id: Self { self }
}
