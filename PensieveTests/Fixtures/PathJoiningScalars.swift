/// Leading extenders join a preceding delimiter; trailing Prepend scalars join the next one (GB9b).
enum PathJoiningScalars {
    static let values = ["\u{0301}", "\u{200D}", "\u{200C}", "\u{1F3FB}", "\u{E0061}", "\u{0600}", "\u{110BD}"]

    static func name(_ stem: String, scalar: String) -> String {
        ["\u{0600}", "\u{110BD}"].contains(scalar) ? stem + scalar : scalar + stem
    }
}
