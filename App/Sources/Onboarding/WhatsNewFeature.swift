#if os(iOS)
/// A row of What's New: an SF Symbol, a short title and a line or two on it.
struct WhatsNewFeature: Hashable {
    let systemImage: String
    let title: String
    let detail: String
}
#endif
