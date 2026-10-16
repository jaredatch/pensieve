import Foundation

/// Root executes this in-memory program with system tools only. Values are positional arguments,
/// never code or executable paths. The elevation boundary runs the same program in fixture tests.
enum PrivilegedCommandLink {
    static func command(for request: CommandLinkRequest) throws -> String {
        let folder = URL(fileURLWithPath: request.directory)
        guard PathSyntax.isAbsolute(request.directory), folder.lastPathComponent == "bin",
              folder.standardized.path == request.directory else {
            throw CommandLinkError(message: "The command folder must be an absolute bin directory.")
        }
        let expected = request.expected
        let identity = expected.map { entry in
            "\(entry.kind == .symlink ? "Symbolic Link" : "Other"):\(entry.owner):\(entry.device):\(entry.inode)"
        } ?? ""
        let arguments = [folder.deletingLastPathComponent().path, request.executable, String(request.user),
                         request.action.rawValue, identity, expected?.target ?? "",
                         expected?.target.flatMap(CommandLinkOwnership.appPath) ?? ""]
        return (["/bin/sh", "-c", program, "pensieve-command-link"] + arguments).map(quote).joined(separator: " ")
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static let program = #"""
    set -eu
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export PATH
    parent=$1 executable=$2 user=$3 action=$4 expected=$5 target=$6 app=$7
    fail() { printf '%s\n' "$1" >&2; exit 1; }
    exists() { /bin/test -e "$1" || /bin/test -L "$1"; }
    identity() { /usr/bin/stat -f '%HT:%u:%d:%i' "$1"; }
    enter() {
        /bin/test ! -L "$1" && /bin/test -d "$1" || fail 'The command folder must be a directory, not a link.'
        before=$(identity "$1") || exit 1
        cd -P -- "$1" || exit 1
        /bin/test "$(identity .)" = "$before" || fail 'The command folder changed.'
        owner=$(/usr/bin/stat -f '%u' .) || exit 1
        /bin/test "$owner" = 0 || /bin/test "$owner" = "$user" || fail 'The command folder has a foreign owner.'
    }
    enter "$parent"
    umask 022
    if ! exists ./bin; then /bin/mkdir ./bin || exit 1; fi
    enter ./bin
    /bin/test ! -L "$parent" && /bin/test ! -L "$parent/bin" || fail 'The command folder changed.'
    /bin/test "$(identity "$parent/bin")" = "$(identity .)" || fail 'The command folder changed.'
    if exists ./pensieve; then
        actual=$(identity ./pensieve) || exit 1
        /bin/test "$actual" = "$expected" || fail 'Something appeared or changed. The link was not changed.'
    else
        /bin/test -z "$expected" || fail 'The inspected link disappeared.'
    fi
    if /bin/test "$action" = install; then
        ! exists ./pensieve || fail 'The command path is already occupied.'
    else
        /bin/test -L ./pensieve && /bin/test -n "$app" || fail 'The path no longer holds a Pensieve link.'
        actual_target=$(/usr/bin/readlink -n ./pensieve; printf '.')
        /bin/test "$actual_target" = "$target." || fail 'The link target changed.'
        if /bin/test "$action" = repair; then
            ! exists "$app" || fail 'The app still exists. The link was not repaired.'
        fi
        /bin/test "$(identity ./pensieve)" = "$expected" || fail 'The inspected link changed.'
        /bin/rm -- ./pensieve || exit 1
    fi
    if /bin/test "$action" != uninstall; then
        # Directory-form ln uses exclusive symlink creation at the basename, even if a directory
        # races into that leaf. It never treats an existing pensieve directory as a destination.
        /bin/test "${executable##*/}" = pensieve || fail "The link wasn't made: invalid executable name."
        /bin/ln -s -- "$executable" . || fail "The link wasn't made. The command folder was kept."
    fi
    """#
}
