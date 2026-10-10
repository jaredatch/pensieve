#!/usr/bin/env python3
"""Check shipped Mach-O files and preserve matching crash symbols."""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


# Fixed tools, replaced only in the release tests' disposable checkout.
TOOLS = ("/usr/bin/lipo", "/usr/bin/otool", "/usr/bin/nm", "/usr/bin/strip", "/usr/bin/dwarfdump")
BINARIES = {"Pensieve": "Pensieve.app.dSYM", "pensieve-daemon": "pensieve-daemon.dSYM"}
ARCHITECTURES = {"arm64", "x86_64"}


class SymbolsMismatch(ValueError):
    """A readable symbols archive belongs to a different build."""


def require(condition, message):
    if not condition:
        raise ValueError(message)


def command(tool, *args):
    return subprocess.run([TOOLS[tool], *map(str, args)], capture_output=True, text=True,
                          check=True, timeout=60).stdout


def check_binary(binary):
    architectures = command(0, "-archs", binary).split()
    require(len(architectures) == 2 and set(architectures) == ARCHITECTURES,
            f"{binary.name}: expected arm64 and x86_64")
    for architecture in architectures:
        label = f"{binary.name} [{architecture}]"
        load_commands = command(1, "-arch", architecture, "-l", binary)
        symbols = command(2, "-arch", architecture, binary)
        require(not re.search(r"__llvm_prf_|__llvm_cov|__LLVM_COV", load_commands),
                f"{label}: coverage sections present")
        require("__llvm_profile" not in symbols,
                f"{label}: profile runtime file-writing code present")
        # Compare the actual symbol table with strip's result, not a size heuristic.
        with tempfile.TemporaryDirectory(prefix="pensieve-strip-check-") as directory:
            stripped = Path(directory) / binary.name
            shutil.copy2(binary, stripped)
            command(3, "-rSTx", stripped)
            remaining = command(2, "-arch", architecture, stripped)
        require(len(symbols.splitlines()) <= len(remaining.splitlines()),
                f"{label}: unstripped symbols present")
    require(b".profraw" not in binary.read_bytes(),
            f"{binary.name}: profile runtime file-writing code present")


def check_app(app):
    for name in BINARIES:
        check_binary(app / "Contents/MacOS" / name)


def uuids(path):
    output = command(4, "--uuid", path)
    matches = re.findall(r"(?m)^UUID: ([0-9A-Fa-f-]{36}) \(([^)]+)\)", output)
    require(len(matches) == 2 and {arch for _, arch in matches} == ARCHITECTURES,
            f"{path.name}: expected UUIDs for arm64 and x86_64")
    return {arch: uuid.upper() for uuid, arch in matches}


def check_symbols(app, archive):
    with zipfile.ZipFile(archive) as zipped, tempfile.TemporaryDirectory(prefix="pensieve-symbols-") as directory:
        names = zipped.namelist()
        require(len(names) == len(set(names)), "dSYMs zip has duplicate entries")
        require({name.split('/')[0] for name in names} == set(BINARIES.values()),
                "dSYMs zip must contain the app and daemon dSYMs alone")
        for name, bundle in BINARIES.items():
            member = f"{bundle}/Contents/Resources/DWARF/{name}"
            dwarf = Path(directory) / name
            # Read only the two named files, never extract archive-controlled paths.
            dwarf.write_bytes(zipped.read(member))
            if uuids(dwarf) != uuids(app / "Contents/MacOS" / name):
                raise SymbolsMismatch(f"{name}: dSYMs UUIDs do not match packaged binary")


def zip_symbols(app, products, archive):
    archive.unlink(missing_ok=True)
    try:
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as zipped:
            for bundle in BINARIES.values():
                root = products / bundle
                require(root.is_dir(), f"missing dSYM: {bundle}")
                for path in sorted(root.rglob('*')):
                    require(not path.is_symlink(), f"linked dSYM entry: {path.name}")
                    if path.is_file():
                        zipped.write(path, path.relative_to(products))
        check_symbols(app, archive)
    except Exception:
        archive.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--check-symbols", type=Path)
    mode.add_argument("--zip-symbols", type=Path)
    parser.add_argument("--products", type=Path)
    args = parser.parse_args()
    if args.check:
        check_app(args.app)
    elif args.check_symbols:
        check_symbols(args.app, args.check_symbols)
    else:
        require(args.products is not None, "--zip-symbols requires --products")
        zip_symbols(args.app, args.products, args.zip_symbols)


if __name__ == "__main__":
    try:
        main()
    except SymbolsMismatch as error:
        print("package: " + str(error), file=sys.stderr)
        sys.exit(2)
    except (ValueError, KeyError, OSError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
        sys.exit("package: " + ascii(str(error))[1:-1])
