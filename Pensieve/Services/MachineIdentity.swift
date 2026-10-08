import Foundation

protocol MachineIdentityProviding {
    func identifier() throws -> String
}

struct MachineIdentity: MachineIdentityProviding {
    private let fileService: FileServiceProtocol
    private let identityPath: String
    private let makeUUID: () -> UUID
    private let warn: (String) -> Void

    init(
        fileService: FileServiceProtocol = FileService(),
        appSupportDir: String,
        makeUUID: @escaping () -> UUID = UUID.init,
        warn: @escaping (String) -> Void = { NSLog("Pensieve machine identity: \($0)") }
    ) {
        self.fileService = fileService
        self.identityPath = appSupportDir + "/machine-id"
        self.makeUUID = makeUUID
        self.warn = warn
    }

    func identifier() throws -> String {
        if fileService.isSymlink(at: identityPath) {
            warn("rejected symlinked identity file; generated a new identity")
            try fileService.deleteFile(at: identityPath)
            return try generate()
        }

        guard fileService.fileExists(at: identityPath) else {
            return try generate()
        }
        guard let raw = try? fileService.readFile(at: identityPath) else {
            warn("identity file was unreadable; generated a new identity")
            return try generate()
        }
        let admitted = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: admitted) else {
            warn("identity file was not a UUID; generated a new identity")
            return try generate()
        }

        let canonical = uuid.uuidString
        if raw != canonical + "\n" {
            try write(canonical)
        }
        return canonical
    }

    private func generate() throws -> String {
        let canonical = makeUUID().uuidString
        try write(canonical)
        return canonical
    }

    private func write(_ identifier: String) throws {
        try fileService.writeFile(at: identityPath, content: identifier + "\n")
    }
}
