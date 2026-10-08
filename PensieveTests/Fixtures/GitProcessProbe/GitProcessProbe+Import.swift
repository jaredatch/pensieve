import Darwin
import Foundation

extension GitProcessProbe {
    static func holdImport(_ mode: String, root: String, report: String) -> Never {
        let files = ImportPublicationFileService()
        guard let lock = SyncLock.tryAcquire(at: root + "/sync.lock") else { exit(73) }
        defer { lock.release() }
        do {
            if mode == "import-build" {
                files.afterWrite = { path, _ in
                    try files.files.writeFile(at: report, content: path)
                    holdWhileParentLives()
                }
                let store = SkillStore(fileService: files, baseDir: root + "/store/skills", storeRoot: root + "/store")
                _ = try store.createSkill(
                    name: "Crash", content: "---\nname: Crash\ndescription: Crash\n---\n\nComplete",
                    avoiding: store.prepareImport())
            } else {
                try files.files.writeFile(at: report, content: "READY")
                holdWhileParentLives()
            }
        } catch { exit(74) }
        exit(1)
    }

    /// A dead test host cannot leave an orphan holding the fixture lock indefinitely.
    private static func holdWhileParentLives() -> Never {
        for _ in 0..<60 {
            if getppid() == 1 { exit(70) }
            Thread.sleep(forTimeInterval: 1)
        }
        exit(70)
    }
}
