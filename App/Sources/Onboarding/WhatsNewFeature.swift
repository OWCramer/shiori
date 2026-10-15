// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
/// A row of What's New: an SF Symbol, a short title and a line or two on it.
struct WhatsNewFeature: Hashable {
    let systemImage: String
    let title: String
    let detail: String
}
#endif
