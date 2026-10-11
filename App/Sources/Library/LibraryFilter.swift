/// The two lists the controller launcher and the Apple TV switch between with their tabs,
/// remembered under `libraryFilter`.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case visualNovels = "Visual Novels"
    case installed = "Installed"
    var id: Self { self }
}
