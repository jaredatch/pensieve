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
            let kind = entry.kind == .symlink ? "Symbolic Link" : "Other"
            return "\(kind):\(entry.owner):\(UInt32(bitPattern: entry.device)):\(entry.inode)"
        } ?? ""
        let arguments = [folder.deletingLastPathComponent().path, request.executable, String(request.user),
                         request.action.rawValue, identity, expected?.target ?? ""]
            .map { Data($0.utf8).base64EncodedString() }
        return (["/bin/sh", "-c", program, "pensieve-command-link"] + arguments).map(quote).joined(separator: " ")
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static let program = #"""
    set -eu
    exec 3>&2 2>/dev/null
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export PATH
    fail() { printf '%s\n' "$1" >&3; exit 1; }
    decode() { printf '%s' "$1" | /usr/bin/base64 -D || exit 1; printf '.'; }
    parent=$(decode "$1") || fail 'Invalid command link argument.'; parent=${parent%.}
    executable=$(decode "$2") || fail 'Invalid command link argument.'; executable=${executable%.}
    user=$(decode "$3") || fail 'Invalid command link argument.'; user=${user%.}
    action=$(decode "$4") || fail 'Invalid command link argument.'; action=${action%.}
    expected=$(decode "$5") || fail 'Invalid command link argument.'; expected=${expected%.}
    target=$(decode "$6") || fail 'Invalid command link argument.'; target=${target%.}
    exists() { /bin/test -e "$1" || /bin/test -L "$1"; }
    identity() { /usr/bin/stat -f '%HT:%u:%d:%i' "$1"; }
    enter() {
        /bin/test ! -L "$1" && /bin/test -d "$1" || fail 'The command folder must be a directory, not a link.'
        before=$(identity "$1") || fail 'The command folder could not be inspected.'
        cd -P -- "$1" || fail 'The command folder could not be opened.'
        /bin/test "$(identity .)" = "$before" || fail 'The command folder changed.'
        owner=$(/usr/bin/stat -f '%u' .) || fail 'The command folder owner could not be read.'
        /bin/test "$owner" = 0 || /bin/test "$owner" = "$user" || fail 'The command folder has a foreign owner.'
    }
    case "$action" in install|uninstall|repair) ;; *) fail 'Invalid command link action.' ;; esac
    app_path() {
        case "$1" in /*.app/Contents/Helpers/pensieve) ;; *) return 1 ;; esac
        case "$1" in *//*|*/./*|*/../*|*/.app/Contents/Helpers/pensieve|*'
    '*) return 1 ;; esac
        printf '%s' "${1%/Contents/Helpers/pensieve}"
    }
    app_path "$executable" >/dev/null || fail 'The executable must be an absolute app helper.'
    app=''
    if /bin/test "$action" != install; then
        app=$(app_path "$target") || fail 'The target must be an absolute app helper.'
    fi
    umask 022
    ancestor=${parent%/*}
    enter "$ancestor"
    /bin/test "$(/usr/bin/stat -f '%u' .)" = "$(/usr/bin/id -u)" || fail 'The ancestor must be owned by the administrator.'
    if ! exists "$parent"; then
        /bin/mkdir "./${parent##*/}" || fail 'The command parent folder could not be created.'
    fi
    enter "$parent"
    if ! exists ./bin; then /bin/mkdir ./bin || fail 'The command folder could not be created.'; fi
    enter ./bin
    /bin/test ! -L "$parent" && /bin/test ! -L "$parent/bin" || fail 'The command folder changed.'
    /bin/test "$(identity "$parent/bin")" = "$(identity .)" || fail 'The command folder changed.'
    if exists ./pensieve; then
        actual=$(identity ./pensieve) || fail 'The command link could not be inspected.'
        /bin/test "$actual" = "$expected" || fail 'Something appeared or changed. The link was not changed.'
    else
        /bin/test -z "$expected" || fail 'The inspected link disappeared.'
    fi
    if /bin/test "$action" = install; then
        ! exists ./pensieve || fail 'The command path is already occupied.'
    else
        /bin/test -L ./pensieve && /bin/test -n "$app" || fail 'The path no longer holds a Pensieve link.'
        actual_target=$(/usr/bin/readlink -n ./pensieve || exit 1; printf '.') ||
            fail 'The command link target could not be read.'
        /bin/test "$actual_target" = "$target." || fail 'The link target changed.'
        if /bin/test "$action" = repair; then
            ! exists "$app" || fail 'The app still exists. The link was not repaired.'
        fi
        /bin/test "$(identity ./pensieve)" = "$expected" || fail 'The inspected link changed.'
        /bin/rm -- ./pensieve || fail 'The command link could not be removed.'
    fi
    if /bin/test "$action" != uninstall; then
        # Directory-form ln uses exclusive symlink creation at the basename, even if a directory
        # races into that leaf. It never treats an existing pensieve directory as a destination.
        /bin/test "${executable##*/}" = pensieve || fail "The link wasn't made: invalid executable name."
        /bin/ln -s -- "$executable" . || fail "The link wasn't made. The command folder was kept."
    fi
    """#
}
