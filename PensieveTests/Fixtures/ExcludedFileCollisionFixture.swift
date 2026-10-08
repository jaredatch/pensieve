import SwiftData
import XCTest
@testable import Pensieve

/// An older writer publishes a tracked path after the other Mac creates its own excluded file.
@MainActor
struct ExcludedFileCollisionFixture {
    static let paths = ["skills/x/.env", "skills/x/.env.local", "skills/x/.DS_Store",
                        "skills/x/node_modules/pkg/index.js"]
    let root: String
    let remote: String
    let storeA: String
    let storeB: String
    let path: String
    let context: ModelContext
    let git = TestPaths.git
    let files = FileService()
    let localBytes = Data([0, 255, 128, 1])
    let remoteBytes = Data([0, 254, 129, 2])
    let beforeHead: String
    let beforeManifest: Data

    init(path: String, hidden: Bool, localCommit: Bool) throws {
        root = TestTemporaryDirectory.path + "ExcludedCollision-" + UUID().uuidString
        remote = root + "/remote.git"
        storeA = root + "/A"
        storeB = root + "/B"
        self.path = path
        let container = try ModelContainer(for: Skill.self, Project.self, Pensieve.Category.self,
            MachineDeployIntent.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        do {
            try files.createDirectory(at: root)
            try git.runOrThrow(["init", "--bare", "--initial-branch=main", remote], in: nil)
            let seed = root + "/seed"
            try files.createDirectory(at: seed)
            try git.initRepository(at: seed)
            try files.writeFile(at: seed + "/skills/x/SKILL.md",
                                content: "---\nname: X\ndescription: Collision fixture\n---\nbody\n")
            try files.writeFile(at: seed + "/skills/x/.gitignore",
                                content: hidden ? ".env\n.env.*\n.DS_Store\nnode_modules/\n" : "")
            try files.writeFile(at: seed + "/.gitignore", content: ".DS_Store\n")
            context.insert(Skill(name: "X", skillDescription: "Collision fixture", directoryName: "x"))
            try context.save()
            let manifest = ManifestService()
            try manifest.write(manifest.snapshot(from: context), toRoot: seed)
            try git.stageAllAndCommit(at: seed, message: "base")
            try git.setRemote("file://" + remote, at: seed)
            try git.push(at: seed, credential: nil)
            try git.clone(remote: "file://" + remote, into: storeA, credential: nil)
            try git.clone(remote: "file://" + remote, into: storeB, credential: nil)
            if localCommit {
                try files.writeFile(at: storeB + "/skills/x/local.txt", content: "local ordinary work\n")
                try git.stageAllAndCommit(at: storeB, message: "local ordinary commit")
            }
            try files.writeData(at: storeB + "/" + path, data: localBytes)
            try files.writeData(at: storeA + "/" + path, data: remoteBytes)
            // Seed a legacy tracked blob independently of the new staging policy.
            try git.runOrThrow(["-C", storeA, "add", "--force", "--", path], in: nil)
            try git.runOrThrow(["-C", storeA, "commit", "-m", "older build tracked file"], in: nil)
            try git.push(at: storeA, credential: nil)
            beforeHead = try XCTUnwrap(git.headSHA(at: storeB))
            beforeManifest = try files.readData(at: storeB + "/manifest/manifest.yaml")
        } catch {
            try? files.deleteDirectory(at: root)
            throw error
        }
    }

    var message: String {
        let obstruction = path == "skills/x/node_modules/pkg/index.js" ? "skills/x/node_modules" : path
        return "Sync paused so it won't overwrite \(obstruction) on this Mac. Another Mac already synced a file there. "
            + "Move or rename this one, then sync again."
    }

    func assertUntouched(line: UInt = #line) throws {
        XCTAssertEqual(try git.headSHA(at: storeB), beforeHead, line: line)
        XCTAssertEqual(try files.readData(at: storeB + "/" + path), localBytes, line: line)
        XCTAssertEqual(try files.readData(at: storeB + "/manifest/manifest.yaml"), beforeManifest, line: line)
        XCTAssertFalse(git.isRebaseInProgress(at: storeB), line: line)
        XCTAssertFalse(files.fileExists(at: storeB + "/.git/MERGE_HEAD"), line: line)
        let blob = try git.runData(["--git-dir", remote, "show", "main:" + path], in: nil)
        XCTAssertEqual(blob.exit, 0, line: line)
        XCTAssertEqual(blob.stdout, remoteBytes, line: line)
    }

    func moveLocalFile() throws {
        try files.replaceItem(at: root + "/preserved-local-file", with: storeB + "/" + path)
    }

    func assertResumed(line: UInt = #line) throws {
        XCTAssertEqual(try files.readData(at: root + "/preserved-local-file"), localBytes, line: line)
        XCTAssertEqual(try files.readData(at: storeB + "/" + path), remoteBytes, line: line)
        let fresh = root + "/fresh"
        try git.clone(remote: "file://" + remote, into: fresh, credential: nil)
        XCTAssertEqual(try files.readData(at: fresh + "/" + path), remoteBytes, line: line)
    }
}
