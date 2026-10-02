import Foundation

enum InstallRelativePathPolicy {
    static func isValid(_ path: String) -> Bool {
        guard !path.hasPrefix("-"), !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: isUnsafeScalar) else {
            return false
        }
        if path.isEmpty { return true }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func isUnsafeScalar(_ scalar: Unicode.Scalar) -> Bool {
        let category = scalar.properties.generalCategory
        return category == .control
            || category == .lineSeparator
            || category == .paragraphSeparator
    }
}
