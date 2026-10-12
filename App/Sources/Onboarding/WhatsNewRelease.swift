#if os(iOS)
/// One update's What's New. A new entry (a new `id`) is shown once to everyone who updates
/// from an earlier build; people installing fresh never see it.
struct WhatsNewRelease: Identifiable, Hashable {
    /// Stable and unique per entry: what's remembered as seen.
    let id: String
    /// The version it shipped in, shown under the title.
    let version: String
    /// Three to five rows, most important first.
    let features: [WhatsNewFeature]
}
#endif
