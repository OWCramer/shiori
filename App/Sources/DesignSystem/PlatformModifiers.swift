// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SwiftUI
import UIKit

/// Modifiers that exist on iOS but not tvOS, applied where the platform has them.
extension View {
    /// A compact navigation title (iOS); tvOS titles have one style.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// A count on a toolbar button (iOS); tvOS toolbars take no badges, so the count is drawn.
    func countBadge(_ count: Int) -> some View {
        #if os(iOS)
        badge(count)
        #else
        overlay(alignment: .topTrailing) {
            if count > 0 {
                Text("\(count)").font(.caption2.bold()).padding(4).background(.red, in: Capsule())
            }
        }
        #endif
    }

    /// A small explanation beside a control: a popover on iOS, a sheet on tvOS.
    func infoPopover<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        popover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }

    /// A search field that stays visible (iOS); tvOS places its own.
    func alwaysSearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(iOS)
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        #else
        searchable(text: text, prompt: prompt)
        #endif
    }

    /// No status bar (iOS); tvOS has none.
    func hiddenStatusBar() -> some View {
        #if os(iOS)
        statusBarHidden()
        #else
        self
        #endif
    }

    /// Text the reader can select and copy (iOS); tvOS has no text selection.
    func selectableText() -> some View {
        #if os(iOS)
        textSelection(.enabled)
        #else
        self
        #endif
    }
}

extension UITapGestureRecognizer {
    /// The "back out" gesture: a two-finger tap on iOS, the Menu button on the Siri Remote.
    func requireSecondaryClick() {
        #if os(tvOS)
        allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        #else
        numberOfTouchesRequired = 2
        #endif
    }
}
