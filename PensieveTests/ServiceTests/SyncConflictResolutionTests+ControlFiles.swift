import Foundation

extension SyncConflictResolutionTests {
    func writeSyncControlFiles(at root: String) throws {
        let attrs = "manifest/categories/*.yaml merge=union\nmanifest/projects.yaml merge=union\n"
        try attrs.write(toFile: root + "/.gitattributes", atomically: true, encoding: .utf8)
        try ".DS_Store\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
    }
}
