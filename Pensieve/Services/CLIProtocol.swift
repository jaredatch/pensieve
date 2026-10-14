import Foundation

/// Versioned wire values shared by the app and its store-free command line client.
enum CLIProtocol {
    static let version = 1
    static let requestLimit = 64 * 1_024
    static let replyLimit = 16 * 1_024 * 1_024
    static let backgroundArgument = "--background"
    // Three times the slowest isolated cold launch (0.942 s), rounded up to a whole second.
    static let readyTimeout: TimeInterval = 3
    static let commandReplyTimeout: TimeInterval = 30
    static let syncReplyTimeout: TimeInterval = 10 * 60

    static func socketPath(appSupport: String, bundleID: String,
                           fileService: FileServiceProtocol = FileService()) -> String {
        var directory = appSupport
        if let alias = ProcessInfo.processInfo.environment["PENSIEVE_SOCKET_DIRECTORY"],
           let identity = fileService.fileIdentity(at: appSupport, followingLinks: true),
           fileService.fileIdentity(at: alias, followingLinks: true) == identity {
            directory = alias
        }
        return directory + "/" + bundleID + ".sock"
    }
}

enum CLIValue: Codable, Equatable {
    case string(String), number(Int), decimal(Double), bool(Bool), array([CLIValue]), object([String: CLIValue]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let decoded = try? value.decode(Bool.self) {
            self = .bool(decoded)
        } else if let decoded = try? value.decode(Int.self) {
            self = .number(decoded)
        } else if let decoded = try? value.decode(Double.self) {
            self = .decimal(decoded)
        } else if let decoded = try? value.decode(String.self) {
            self = .string(decoded)
        } else if let decoded = try? value.decode([CLIValue].self) {
            self = .array(decoded)
        } else {
            self = .object(try value.decode([String: CLIValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .string(item): try value.encode(item)
        case let .number(item): try value.encode(item)
        case let .decimal(item): try value.encode(item)
        case let .bool(item): try value.encode(item)
        case let .array(item): try value.encode(item)
        case let .object(item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
}

struct CLIError: Codable, Equatable {
    let code: String
    let message: String
    let hint: String
    let retryable: Bool
}

struct CLIEnvelope: Codable, Equatable {
    var schema = CLIProtocol.version
    let ok: Bool
    var changed: Bool?
    var data: CLIValue?
    var next: [String]?
    var error: CLIError?
}

struct CLIReply: Codable {
    let envelope: CLIEnvelope
    let exitCode: Int32

    static func success(_ data: CLIValue) -> Self {
        Self(envelope: CLIEnvelope(ok: true, changed: false, data: data), exitCode: 0)
    }

    static func failure(_ code: String, _ message: String, hint: String, exit: Int32,
                        retryable: Bool = false) -> Self {
        Self(envelope: CLIEnvelope(ok: false, error: CLIError(
            code: code, message: message, hint: hint, retryable: retryable)), exitCode: exit)
    }
}

struct CLIHandshake: Codable {
    let bundlePath: String
    var protocolVersion = CLIProtocol.version
    let appVersion: String
    var supportsReadiness: Bool?
    var supportsCommit: Bool?
}

struct CLIReadinessAcknowledgement: Codable {
    let ready: Bool
}

struct CLICommandCommit: Codable {
    let commit: Bool
}

struct CLIRequest: Codable {
    var protocolVersion = CLIProtocol.version
    let command: String
    var arguments: [String] = []
    var content = false
    var acknowledgeReadiness: Bool?
    var requiresCommit: Bool?
    var deployment: CLIDeployOptions?

    var isWrite: Bool { ["deploy", "undeploy", "sync"].contains(command) }
}

struct CLIDeployOptions: Codable {
    var agents: [String] = []
    var global = false
    var project: String?
    var machines: [String] = []
    var dryRun = false
    var workingDirectory: String = ""
}
