import Foundation

enum ProjectFolderError: LocalizedError {
    case missing(String)
    case couldNotCheck(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .missing(let path):
            "Project folder is missing at \(path)."
        case .couldNotCheck(let path, let reason):
            "Project folder couldn't be checked at \(path): \(reason)"
        }
    }
}
