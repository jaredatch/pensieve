#!/usr/bin/env python3
"""Relay timeout reports once and retain five complete, inactive report pairs.

Only regular, non-symlink files with the host's PID/UUID/state-or-threads naming
pattern participate. Unknown process liveness preserves evidence. The wrapper
waits for the relay's ready file before starting Xcode, avoiding a startup race
between the initial report snapshot and the first timeout publication.
"""
import argparse
import os
from pathlib import Path
import re
import signal
import sys
import time

REPORT_NAME = re.compile(
    r"([1-9][0-9]*)-([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})-(state|threads)\.txt\Z")
KEEP_PAIRS = 5


def reports(directory):
    for path in sorted(directory.glob("*.txt")):
        match = REPORT_NAME.fullmatch(path.name)
        if match and not path.is_symlink() and path.is_file():
            yield path, match


def process_finished(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except OSError:
        pass
    return False


def prune(directory):
    pairs = {}
    for path, match in reports(directory):
        pid, identifier, kind = match.groups()
        pairs.setdefault((int(pid), identifier), {})[kind] = path
    inactive = []
    for (pid, identifier), pair in pairs.items():
        if set(pair) != {"state", "threads"} or not process_finished(pid):
            continue
        try:
            newest = max(path.stat().st_mtime_ns for path in pair.values())
        except OSError as error:
            print(f"TestDiagnostics pruning preserved {identifier}: {error}", file=sys.stderr)
            continue
        inactive.append((newest, identifier, pid, pair))
    for _, identifier, pid, pair in sorted(inactive, key=lambda item: item[:2], reverse=True)[KEEP_PAIRS:]:
        if not process_finished(pid):
            continue
        try:
            for path in pair.values():
                path.unlink()
        except OSError as error:
            print(f"TestDiagnostics pruning preserved {identifier}: {error}", file=sys.stderr)


def relay(directory, parent_pid, ready=None):
    running = True
    seen = {path for path, _ in reports(directory)}

    def stop(_signum, _frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    if ready:
        ready.write_text("ready\n")
    while os.getppid() == parent_pid:
        for path, _ in reports(directory):
            if path in seen:
                continue
            try:
                report = path.read_text()
            except OSError as error:
                print(f"Timeout diagnostic relay could not read {path}: {error}", flush=True)
                seen.add(path)
                continue
            print(f"BEGIN TIMEOUT DIAGNOSTIC {path.name}\n{report}\nEND TIMEOUT DIAGNOSTIC {path.name}", flush=True)
            seen.add(path)
        if not running:
            return
        time.sleep(0.25)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("parent_pid", nargs="?", type=int)
    parser.add_argument("--ready", type=Path)
    parser.add_argument("--prune", action="store_true")
    args = parser.parse_args()
    if args.prune:
        prune(args.directory)
    elif args.parent_pid is None:
        parser.error("relay requires the wrapper PID")
    else:
        relay(args.directory, args.parent_pid, args.ready)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        # Also silence Python's final stdout flush after the consumer closes.
        sys.stdout = open(os.devnull, "w")
