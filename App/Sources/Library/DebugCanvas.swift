#if os(iOS)
import SwiftUI

/// `-ShioriCanvas 1376x1032` (Debug): lays the library out at that size in points, scaled to
/// fit the screen, for checking iPad landscape (or other window sizes) in a simulator that
/// can only be rotated from Device Hub. Nothing in other builds or without the flag.
struct DebugCanvas: ViewModifier {
    private static var size: CGSize? {
        #if DEBUG
        let parts = (UserDefaults.standard.string(forKey: "ShioriCanvas") ?? "").split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
        #else
        return nil
        #endif
    }

    func body(content: Content) -> some View {
        if let size = Self.size {
            GeometryReader { proxy in
                let scale = min(1, proxy.size.width / size.width, proxy.size.height / size.height)
                content
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .scaleEffect(scale)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .ignoresSafeArea()
        } else {
            content
        }
    }
}
#endif
