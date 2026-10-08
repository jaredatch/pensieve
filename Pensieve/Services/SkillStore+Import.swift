import Foundation

extension SkillStore {
    /// The caller holds sync.lock for the entire import batch, including build and cleanup.
    /// Prepare outside the store in the install sweep's namespace, then publish without replacing an occupant.
    func createSkill(name: String, content: String, avoiding: Set<String>) throws -> String {
        try fileService.createDirectory(at: baseDir)
        let occupied = Set(try fileService.listDirectory(at: baseDir).map { $0.lowercased() })
            .union(avoiding.map { $0.lowercased() })
        let slug = SkillStore.slugify(name)
        var candidate = slug
        var suffix = 2
        while occupied.contains(candidate) {
            candidate = slug + "-\(suffix)"
            suffix += 1
        }
        guard let destination = SkillStore.safeSkillDirectory(slug: candidate, base: baseDir, fileService: fileService) else {
            throw SkillStoreError.invalidDirectory(candidate)
        }
        let storeRoot = (baseDir as NSString).deletingLastPathComponent
        let parent = (storeRoot as NSString).deletingLastPathComponent
        let base = (storeRoot as NSString).lastPathComponent
        let temporary = parent + "/" + base + ".vendor-" + UUID().uuidString + ".tmp"
        do {
            try fileService.createDirectory(at: temporary)
            try fileService.writeFile(at: temporary + "/SKILL.md", content: content)
            guard SkillStore.safeSkillDirectory(slug: candidate, base: baseDir, fileService: fileService) != nil else {
                throw SkillStoreError.invalidDirectory(candidate)
            }
            try fileService.publishNewDirectory(at: temporary, to: destination)
            return candidate
        } catch {
            if fileService.directoryExists(at: temporary) || fileService.isSymlink(at: temporary) {
                try? fileService.deleteDirectory(at: temporary)
            }
            throw error
        }
    }
}
