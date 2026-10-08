import Foundation

extension GitService {
    /// Narrow command overrides retain identity, URL rewrites, credentials and the rest of the user's
    /// configuration. GIT_ATTR_NOSYSTEM additionally excludes system attributes for these commands.
    static let storeConfigurationArgs = [
        "-c", "core.excludesFile=/dev/null", "-c", "core.attributesFile=/dev/null",
        "-c", "core.autocrlf=false", "-c", "core.eol=lf"
    ]

    /// info/attributes outranks even a nested skill's attributes. These rules affect conversions,
    /// leaving the root manifest's merge=union intact. Skill merge drivers cannot change its bytes.
    /// The file stays local to git metadata; the skill's shipped control files remain byte-pristine.
    func ensureStoreAttributes(at root: String) throws {
        let path = try gitMetadataPath("info/attributes", at: root)
        let attributes = "* -text -eol -ident -filter -working-tree-encoding\nskills/** !merge\n"
        if (try? fileService.readFile(at: path)) != attributes {
            try fileService.writeFile(at: path, content: attributes)
        }
    }

    /// First stage ordinary changes/deletions with the root rules. Then force only extra skill files,
    /// enumerated without per-folder/global excludes. The root ignore and info/exclude still apply.
    /// A NUL-delimited literal pathspec file avoids both argv size limits and filename interpretation.
    func stageStore(at root: String) throws {
        try ensureStoreAttributes(at: root)
        try runOrThrow(["-C", root, "add", "-A"], in: nil, storeRules: true)
        let paths = try unstagedSkillPaths(at: root)
        guard !paths.isEmpty else { return }
        let pathspec = try gitMetadataPath("pensieve-stage-" + UUID().uuidString, at: root)
        try fileService.writeData(at: pathspec, data: paths)
        defer { try? fileService.deleteFile(at: pathspec) }
        try runOrThrow(["--literal-pathspecs", "-C", root, "add", "--force", "--all",
                       "--pathspec-from-file=" + pathspec, "--pathspec-file-nul"], in: nil, storeRules: true)
    }

    func unstagedSkillPaths(at root: String) throws -> Data {
        var args = ["-C", root, "ls-files", "--others", "-z"]
        for path in [root + "/.gitignore", try gitMetadataPath("info/exclude", at: root)]
            where fileService.fileExists(at: path) {
            args.append("--exclude-from=" + path)
        }
        args += ["--", "skills"]
        let result = try runData(args, in: nil, storeRules: true)
        guard result.exit == 0 else {
            throw GitError.commandFailed(args: args, exitCode: result.exit,
                stderr: String(bytes: result.stderr, encoding: .utf8) ?? "",
                confirmingProbe: result.confirmingProbe)
        }
        return result.stdout
    }

    private func gitMetadataPath(_ path: String, at root: String) throws -> String {
        let result = try runOrThrow(["-C", root, "rev-parse", "--path-format=absolute", "--git-path", path], in: nil)
        let resolved = result.stdout.trimmingCharacters(in: .newlines)
        guard resolved.utf8.first == 0x2F else {
            throw GitError.repositoryUnreadable(path: root, detail: "git returned no metadata path.")
        }
        return resolved
    }
}
