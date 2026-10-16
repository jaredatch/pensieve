import Foundation

protocol CommandLinkAuthorizing {
    func run(_ request: CommandLinkRequest) throws
}

protocol CommandLinkInstalling {
    func status() throws -> CommandLinkStatus
    func perform(_ action: CommandLinkAction) throws
    func repairAtLaunch() throws
}

enum CommandLinkStatus: Equatable {
    case absent, installed(String), homebrew(String), broken, occupied(String)

    var message: String {
        switch self {
        case .absent: return "Not installed"
        case .installed(let path): return "Installed at \(path)"
        case .homebrew(let path): return "Installed by Homebrew at \(path)"
        case .broken: return "The link points to a Pensieve that was moved or deleted"
        case .occupied(let detail): return detail
        }
    }

    var action: CommandLinkAction? {
        switch self {
        case .absent, .occupied: return .install
        case .installed: return .uninstall
        case .broken: return .repair
        case .homebrew: return nil
        }
    }
}

struct CommandLinkInstaller: CommandLinkInstalling {
    let files: FileServiceProtocol
    let directory: String
    let executable: String
    let user: UInt32
    let homebrewDirectories: [String]
    let authorization: CommandLinkAuthorizing

    func status() throws -> CommandLinkStatus {
        for bin in homebrewDirectories {
            let prefix = URL(fileURLWithPath: bin).deletingLastPathComponent().path
            if try files.entryExistsWithoutFollowingLinks(at: prefix + "/Caskroom/pensieve"),
               let entry = try files.commandLinkEntry(at: bin + "/pensieve"),
               let target = entry.target, try CommandLinkOwnership.isPensieve(target, files: files),
               files.isExecutableFile(at: bin + "/pensieve") {
                return .homebrew(bin + "/pensieve")
            }
        }
        let path = directory + "/pensieve"
        guard let entry = try files.commandLinkEntry(at: path) else { return .absent }
        if let target = entry.target, try CommandLinkOwnership.isPensieve(target, files: files) {
            return files.isExecutableFile(at: path) ? .installed(path) : .broken
        }
        return .occupied(entry.target.map { "\(path) is taken by a link to \($0)" }
            ?? "\(path) is taken by another file")
    }

    func perform(_ action: CommandLinkAction) throws {
        try checkParents()
        let state = try status()
        if case .homebrew = state { return }
        switch (action, state) {
        case (.install, .absent), (.uninstall, .installed), (.uninstall, .broken), (.repair, .broken): break
        case (.install, .installed): return
        default: throw CommandLinkError(message: state.message)
        }
        let request = try makeRequest(action)
        if action == .repair {
            guard let target = request.expected?.target,
                  try CommandLinkOwnership.isMissingApp(target, files: files) else {
                throw CommandLinkError(message: "The app still exists. Reinstall Pensieve to restore its command.")
            }
        }
        try authorization.run(request)
    }

    /// Launch never asks for authorization. A permission failure leaves the broken link visible.
    func repairAtLaunch() throws {
        guard try status() == .broken else { return }
        try checkParents()
        let request = try makeRequest(.repair)
        guard let target = request.expected?.target,
              try CommandLinkOwnership.isMissingApp(target, files: files) else { return }
        try files.changeCommandLink(request)
    }

    private func makeRequest(_ action: CommandLinkAction) throws -> CommandLinkRequest {
        CommandLinkRequest(action: action, directory: directory, executable: executable, user: user,
                           expected: try files.commandLinkEntry(at: directory + "/pensieve"))
    }

    private func checkParents() throws {
        let parent = URL(fileURLWithPath: directory).deletingLastPathComponent().path
        for path in [parent, directory] {
            guard let entry = try files.commandLinkEntry(at: path) else {
                if path == directory { continue }
                throw CommandLinkError(message: "\(path) is missing. Restore it before installing the command.")
            }
            guard entry.kind == .directory, entry.owner == 0 || entry.owner == user else {
                throw CommandLinkError(message: "\(path) must be a directory owned by root or your user, not a link.")
            }
        }
    }
}

struct AdminCommandLinkAuthorization: CommandLinkAuthorizing {
    struct Cancelled: Error {}

    var prompt: AdministratorPromptRunning = AppleScriptAdministratorPrompt()

    func run(_ request: CommandLinkRequest) throws {
        let shell = try PrivilegedCommandLink.command(for: request)
        do {
            try prompt.run(shellCommand: shell)
        } catch let error as NSError where error.domain == AppleScriptAdministratorPrompt.errorDomain && error.code == -128 {
            throw Cancelled()
        }
    }
}
