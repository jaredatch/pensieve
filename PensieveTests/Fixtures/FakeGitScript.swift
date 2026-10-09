/// Shared argv normalization for fake git dispatch. Insert inside a shell function when native git
/// must receive the original argv. A terminal query has no subcommand and keeps its own spelling.
enum FakeGitScript {
    static let skipGlobalOptions = """
        while [ "$#" -gt 0 ]; do
            case "$1" in
              -c) shift 2 ;;
              -C) repository="$2"; shift 2 ;;
              --version|--help)
                if [ "$#" -eq 1 ]; then break; fi
                shift ;;
              -*) shift ;;
              *) break ;;
            esac
        done
        """
}
