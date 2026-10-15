import Foundation
import Darwin

extension GitProcessProbe {
    static func storeWrite(_ mode: String, root: String) -> Never {
        do {
            let files = FileService()
            let skills = SkillStore(fileService: files, baseDir: root + "/skills", storeRoot: root)
            switch mode {
            case "store-write-create":
                _ = try skills.createSkill(name: "new", description: "New skill", body: "new body")
            case "store-write-body":
                try skills.writeBody(directoryName: "existing", body: "rewritten body")
            case "store-write-rewrite":
                let text = try skills.readBody(directoryName: "existing")
                _ = try skills.rewriteSkill(directoryName: "existing", body: "rewritten body",
                    preserving: SkillParser.parse(text), fallbackName: "existing", fallbackDescription: "Existing skill")
            default:
                try StoreIgnoreRules.prepare(at: root, files: files)
            }
            exit(0)
        } catch {
            fputs("\(error)\n", stderr)
            exit(1)
        }
    }
}
