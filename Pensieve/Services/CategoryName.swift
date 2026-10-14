import Foundation

/// Local admission and queued rename validation share the same name comparison. Sync still
/// merges exact same-name creates, and does not coalesce legacy names that differ in case.
enum CategoryName {
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(
            rhs.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    static func takenName(_ candidate: String, among names: [String]) -> String? {
        names.first { matches(candidate, $0) }
    }

    static func validationMessage(_ candidate: String, among categories: [Category], excluding id: UUID? = nil) -> String? {
        takenName(candidate, among: categories.filter { $0.id != id }.map(\.name))
            .map { CategoryNameError.taken($0).localizedDescription }
    }
}

enum CategoryNameError: LocalizedError {
    case taken(String)

    var errorDescription: String? {
        switch self {
        case .taken(let name): "A category named “\(name.trimmingCharacters(in: .whitespacesAndNewlines))” already exists."
        }
    }
}
