import XCTest
@testable import Pensieve

extension SyncConflictResolutionTests {
    func assertUnsafeJoiningScalarPaths(root: String) throws {
        for (index, scalar) in PathJoiningScalars.values.enumerated() {
            let target = "/" + scalar + "outside/target.txt"
            let leaf = root + "/joined-leaf-\(index)"
            try FileManager.default.createSymbolicLink(atPath: leaf, withDestinationPath: target)
            try assertUnsafePath("joined-leaf-\(index)", root: root, escapedPath: nil)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: leaf), target)
            try assertUnsafePath("/" + scalar + "absolute.txt", root: root, escapedPath: nil)
            try assertUnsafePath("skills/" + scalar + "name/../SKILL.md", root: root, escapedPath: nil)
        }
    }
}
