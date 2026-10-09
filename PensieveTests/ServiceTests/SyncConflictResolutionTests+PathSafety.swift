import XCTest
@testable import Pensieve

extension SyncConflictResolutionTests {
    func assertUnsafeJoiningScalarPaths(root: String) throws {
        for (index, scalar) in PathJoiningScalars.values.enumerated() {
            let target = "/" + PathJoiningScalars.name("outside", scalar: scalar) + "/target.txt"
            let leaf = root + "/joined-leaf-\(index)"
            try FileManager.default.createSymbolicLink(atPath: leaf, withDestinationPath: target)
            try assertUnsafePath("joined-leaf-\(index)", root: root, escapedPath: nil)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: leaf), target)
            try assertUnsafePath("/" + PathJoiningScalars.name("absolute.txt", scalar: scalar),
                                 root: root, escapedPath: nil)
            try assertUnsafePath("skills/" + PathJoiningScalars.name("name", scalar: scalar) + "/../SKILL.md",
                                 root: root, escapedPath: nil)
        }
    }
}
