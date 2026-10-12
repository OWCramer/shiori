/// What Collections' suggestions depend on, compared to know when to work them out again.
struct CollectionInputs: Equatable {
    var library: [LibraryGame]
    var added: Set<UInt32>
    var hidden: Set<UInt32>
    var downloaded: Set<UInt32>
}
