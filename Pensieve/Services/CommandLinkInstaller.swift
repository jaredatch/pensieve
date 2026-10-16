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
    indirect case alongsideHomebrew(CommandLinkStatus, String)

    var message: String {
        switch self {
        case .alongsideHomebrew(let local, let brew): return local.message + "; also installed by Homebrew at " + brew
        case .absent: return "Not installed"
        case .installed(let path): return "Installed at \(path)"
        case .homebrew(let path): return "Installed by Homebrew at \(path)"
        case .broken: return "The link points to a Pensieve that was moved or deleted"
        case .occupied(let detail): return detail
        }
    }

    var hasProblem: Bool {
        switch self {
        case .broken, .occupied: return true
        case .alongsideHomebrew(let local, _): return local.hasProblem
        default: return false
        }
    }

    var action: CommandLinkAction? {
        switch self {
        case .alongsideHomebrew(let local, _): return local.action
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
        try status(entry: files.commandLinkEntry(at: directory + "/pensieve"))
    }

    private func status(entry: CommandLinkEntry?) throws -> CommandLinkStatus {
        let local = try localStatus(entry: entry)
        for bin in homebrewDirectories {
            let prefix = URL(fileURLWithPath: bin).deletingLastPathComponent().path
            if try files.entryExistsWithoutFollowingLinks(at: prefix + "/Caskroom/pensieve"),
               let entry = try files.commandLinkEntry(at: bin + "/pensieve"),
               let target = entry.target, try CommandLinkOwnership.isPensieve(target, files: files),
               files.isExecutableFile(at: bin + "/pensieve") {
                if local == .absent || bin == directory { return .homebrew(bin + "/pensieve") }
                return .alongsideHomebrew(local, bin + "/pensieve")
            }
        }
        return local
    }

    private func localStatus(entry: CommandLinkEntry?) throws -> CommandLinkStatus {
        let path = directory + "/pensieve"
        guard let entry else { return .absent }
        if let target = entry.target, try target == executable || CommandLinkOwnership.isPensieve(target, files: files) {
            return files.isExecutableFile(at: path) ? .installed(path) : .broken
        }
        return .occupied(entry.target.map { "\(path) is taken by a link to \($0)" }
            ?? "\(path) is taken by another file")
    }

    func perform(_ action: CommandLinkAction) throws {
        try checkParents()
        if action != .uninstall { try checkAppLocation() }
        let entry = try files.commandLinkEntry(at: directory + "/pensieve")
        var state = try status(entry: entry)
        if case .alongsideHomebrew(let local, _) = state { state = local }
        if case .homebrew = state { return }
        switch (action, state) {
        case (.install, .absent), (.uninstall, .installed), (.uninstall, .broken), (.repair, .broken): break
        case (.install, .installed): return
        default: throw CommandLinkError(message: state.message)
        }
        let request = makeRequest(action, expected: entry)
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
        try checkAppLocation()
        let entry = try files.commandLinkEntry(at: directory + "/pensieve")
        guard try localStatus(entry: entry) == .broken else { return }
        try checkParents()
        let request = makeRequest(.repair, expected: entry)
        guard let target = request.expected?.target,
              try CommandLinkOwnership.isMissingApp(target, files: files) else { return }
        try files.changeCommandLink(request)
    }

    private func checkAppLocation() throws {
        let path = files.realPath(at: executable)
        guard !PathSyntax.isWithin(path, root: "/Volumes"), !PathSyntax.components(path).contains("AppTranslocation") else {
            throw CommandLinkError(message: "Move Pensieve to your Applications folder first.")
        }
    }

    private func makeRequest(_ action: CommandLinkAction, expected: CommandLinkEntry?) -> CommandLinkRequest {
        CommandLinkRequest(action: action, directory: directory, executable: executable, user: user,
                           expected: expected)
    }

    private func checkParents() throws {
        let parent = URL(fileURLWithPath: directory).deletingLastPathComponent().path
        let ancestor = URL(fileURLWithPath: parent).deletingLastPathComponent().path
        guard let root = try files.commandLinkEntry(at: ancestor), root.kind == .directory,
              root.owner == 0 || (ancestor != "/usr" && root.owner == user) else {
            throw CommandLinkError(message: "\(ancestor) must be an administrator-owned directory.")
        }
        for path in [parent, directory] {
            guard let entry = try files.commandLinkEntry(at: path) else {
                if path == directory { continue }
                continue
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
            try prompt.run(shellCommand: shell, action: request.action)
        } catch let error as NSError where error.domain == AppleScriptAdministratorPrompt.errorDomain && error.code == -128 {
            throw Cancelled()
        }
    }
}
