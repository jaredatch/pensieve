import Foundation

extension ManifestService {
    /// Reader visibility for a byte path relative to manifest/. Recovery uses the same policy
    /// before decoding Git's untracked names; the flat readers inspect only their immediate child.
    static func ignoresEntry(at relativePath: Data.SubSequence, emptyDirectory: Bool = false) -> Bool {
        let parts = relativePath.split(separator: 0x2F)
        guard let first = parts.first else { return false }
        if emptyDirectory {
            if parts.count == 1 {
                return ["categories", "skills", "deploys"].contains { first.elementsEqual($0.utf8) }
            }
            guard first.elementsEqual("deploys".utf8), parts.count == 2,
                  let machine = String(bytes: parts[1], encoding: .utf8),
                  let uuid = UUID(uuidString: machine) else { return false }
            return machine == uuid.uuidString
        }
        if first.elementsEqual("categories".utf8) || first.elementsEqual("skills".utf8) {
            return parts.count > 1 && !parts[1].suffix(5).elementsEqual(".yaml".utf8)
        }
        if first.elementsEqual("deploys".utf8) {
            guard parts.count > 1 else { return false }
            return StoreExclusions.isExcludedFile(relativePath)
                || parts.dropFirst().contains(where: StoreExclusions.isExcludedDirectory)
        }
        return !first.elementsEqual("manifest.yaml".utf8) && !first.elementsEqual("projects.yaml".utf8)
    }

    func writeDeployIntents(_ records: [DeployIntentRecord], to deploysDir: String) throws {
        let grouped = Dictionary(grouping: records) { record in
            record.machineID + "|" + record.skillSlug
        }
        for recordsForFile in grouped.values {
            guard let first = recordsForFile.first else { continue }
            let machineDir = deploysDir + "/" + first.machineID
            try fileService.createDirectory(at: machineDir)
            let platforms = Array(Set(recordsForFile.compactMap { record in
                record.projectKey == nil ? record.platformRaw : nil
            })).sorted()
            let projectGroups = Dictionary(grouping: recordsForFile.compactMap { record in
                record.projectKey.map { ($0, record.platformRaw) }
            }, by: { $0.0 })
            let projects = projectGroups.mapValues { values in
                Array(Set(values.map { $0.1 })).sorted()
            }
            try fileService.writeFile(
                at: machineDir + "/" + first.skillSlug + ".yaml",
                content: Self.serializeDeployIntent(
                    slug: first.skillSlug,
                    platforms: platforms,
                    projects: projects
                )
            )
        }
    }

    func readDeployIntents(from manifestDir: String, schemaVersion: Int) throws -> [DeployIntentRecord] {
        let deploysDir = manifestDir + "/deploys"
        guard !fileService.isSymlink(at: deploysDir), fileService.directoryExists(at: deploysDir) else {
            if fileService.fileExists(at: deploysDir) || fileService.isSymlink(at: deploysDir) {
                throw ManifestError.corruptManifestFile("deploys")
            }
            return []
        }
        var records: [DeployIntentRecord] = []
        var seenMachines: [UUID: String] = [:]
        for machineEntry in try fileService.listDirectory(at: deploysDir).sorted() {
            let machineFile = "deploys/" + machineEntry
            if Self.ignoresEntry(at: Data(machineFile.utf8)) { continue }
            guard machineEntry == (machineEntry as NSString).lastPathComponent,
                  !PathSyntax.hasSeparator(machineEntry), !machineEntry.contains("\\"),
                  let uuid = UUID(uuidString: machineEntry),
                  machineEntry == uuid.uuidString,
                  !fileService.isSymlink(at: deploysDir + "/" + machineEntry),
                  fileService.directoryExists(at: deploysDir + "/" + machineEntry) else {
                throw ManifestError.corruptManifestFile(machineFile)
            }
            if let existing = seenMachines[uuid], existing != machineEntry {
                throw ManifestError.corruptManifestFile(machineFile)
            }
            seenMachines[uuid] = machineEntry
            try readDeployIntentDirectory(
                deploysDir + "/" + machineEntry,
                machineID: machineEntry,
                schemaVersion: schemaVersion,
                records: &records
            )
        }
        return records.sorted {
            ($0.machineID, $0.skillSlug, $0.projectKey ?? "", $0.platformRaw)
                < ($1.machineID, $1.skillSlug, $1.projectKey ?? "", $1.platformRaw)
        }
    }

    private func readDeployIntentDirectory(
        _ directory: String,
        machineID: String,
        schemaVersion: Int,
        records: inout [DeployIntentRecord]
    ) throws {
        var seenSlugs: [String: String] = [:]
        for entry in try fileService.listDirectory(at: directory).sorted() {
            let relativePath = "deploys/" + machineID + "/" + entry
            if Self.ignoresEntry(at: Data(relativePath.utf8)) { continue }
            guard entry == (entry as NSString).lastPathComponent,
                  !PathSyntax.hasSeparator(entry), !entry.contains("\\"), entry.hasSuffix(".yaml") else {
                throw ManifestError.corruptManifestFile(relativePath)
            }
            let stem = String(entry.dropLast(5))
            guard Self.isAdmittedIntentComponent(stem), SkillStore.isPathSafeSlug(stem) else {
                throw ManifestError.corruptManifestFile(relativePath)
            }
            let folded = stem.lowercased()
            if let existing = seenSlugs[folded], existing != stem {
                throw ManifestError.corruptManifestFile(relativePath)
            }
            seenSlugs[folded] = stem
            let parsed = try parseDeployIntentFile(
                at: directory + "/" + entry,
                stem: stem,
                relativePath: relativePath,
                schemaVersion: schemaVersion
            )
            records.append(contentsOf: parsed.platforms.map {
                DeployIntentRecord(machineID: machineID, skillSlug: stem, platformRaw: $0)
            })
            for project in parsed.projects {
                records.append(contentsOf: project.platforms.map {
                    DeployIntentRecord(
                        machineID: machineID,
                        skillSlug: stem,
                        platformRaw: $0,
                        projectKey: project.key
                    )
                })
            }
        }
    }

    private struct ParsedDeployIntent {
        let platforms: [String]
        let projects: [ParsedProjectDeployIntent]
    }

    private struct ParsedProjectDeployIntent {
        let key: String
        let platforms: [String]
    }

    private func parseDeployIntentFile(
        at path: String,
        stem: String,
        relativePath: String,
        schemaVersion: Int
    ) throws -> ParsedDeployIntent {
        guard fileService.isRegularFile(at: path),
              let content = try? readManifestText(at: path),
              let object = (try? CheckedYAMLLoader.load(yaml: content)) as? [String: Any],
              isAcceptedDeployIntentKeys(Set(object.keys), schemaVersion: schemaVersion),
              let slug = object["slug"] as? String, slug == stem,
              let rawPlatforms = object["platforms"] else {
            throw ManifestError.corruptManifestFile(relativePath)
        }
        let platforms = try parseIntentPlatforms(rawPlatforms, allowEmpty: true, file: relativePath)
        let projects = try parseDeployIntentProjects(object["projects"], file: relativePath)
        let isLegacyEmptyPlatformList = schemaVersion == 4
            && object["projects"] == nil
            && rawPlatforms is [Any]
        guard !platforms.isEmpty || !projects.isEmpty || isLegacyEmptyPlatformList else {
            throw ManifestError.corruptManifestFile(relativePath)
        }
        return ParsedDeployIntent(platforms: platforms, projects: projects)
    }

    private func isAcceptedDeployIntentKeys(_ keys: Set<String>, schemaVersion: Int) -> Bool {
        if keys == Set(["slug", "platforms"]) { return true }
        return schemaVersion >= 5 && keys == Set(["slug", "platforms", "projects"])
    }

    private func parseDeployIntentProjects(
        _ rawValue: Any?,
        file: String
    ) throws -> [ParsedProjectDeployIntent] {
        guard let rawValue else { return [] }
        guard let rawProjects = rawValue as? [Any] else {
            throw ManifestError.corruptManifestFile(file)
        }
        var seen = Set<String>()
        return try rawProjects.map { rawProject in
            guard let project = rawProject as? [String: Any],
                  Set(project.keys) == Set(["key", "platforms"]),
                  let key = project["key"] as? String,
                  Self.isAdmittedProjectKey(key),
                  seen.insert(key).inserted,
                  let rawPlatforms = project["platforms"] else {
                throw ManifestError.corruptManifestFile(file)
            }
            return ParsedProjectDeployIntent(
                key: key,
                platforms: try parseIntentPlatforms(rawPlatforms, allowEmpty: false, file: file)
            )
        }
    }

    private func parseIntentPlatforms(_ rawValue: Any, allowEmpty: Bool, file: String) throws -> [String] {
        let rawPlatforms: [Any]
        if rawValue is NSNull {
            rawPlatforms = []
        } else if let values = rawValue as? [Any] {
            rawPlatforms = values
        } else {
            throw ManifestError.corruptManifestFile(file)
        }
        let platforms = try rawPlatforms.map { value -> String in
            guard let platform = value as? String,
                  Self.isAdmittedIntentComponent(platform) else {
                throw ManifestError.corruptManifestFile(file)
            }
            return platform
        }
        guard allowEmpty || !platforms.isEmpty else {
            throw ManifestError.corruptManifestFile(file)
        }
        return Array(Set(platforms)).sorted()
    }

    static func serializeDeployIntent(
        slug: String,
        platforms: [String],
        projects: [String: [String]] = [:]
    ) -> String {
        var lines = ["slug: \(SkillSerializer.quotedScalar(slug))"]
        appendBlockList(&lines, key: "platforms", values: platforms)
        if !projects.isEmpty {
            lines.append("projects:")
            for key in projects.keys.sorted() {
                lines.append("  - key: \(flowQuoted(key))")
                lines.append("    platforms:")
                for platform in (projects[key] ?? []).sorted() {
                    lines.append("      - \(SkillSerializer.quotedScalar(platform))")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
