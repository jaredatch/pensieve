import Foundation

/// Gives a fixture store its own parent, so clone staging and launch sweeps cannot cross
/// into another fixture, even within one worker. Keep sibling clones and locks under root.
/// Callers create what they need through FileService and remove root at teardown. The root
/// stays below TestTemporaryDirectory, including Xcode's fallback; this does not isolate
/// multiple stores deliberately placed within the same fixture or systemPath escapes.
struct TestStoreDirectory {
    let root: String
    var storeRoot: String { root + "/store" }

    init(named name: String) {
        root = TestTemporaryDirectory.path + name + "-" + UUID().uuidString
    }
}
