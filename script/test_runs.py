#!/usr/bin/env python3
"""Prune idle TestRuns under test.sh's machine lock; retain the five newest interrupted runs.

Each new builder has a BSD flock held by lockf until xcodebuild exits, even if its wrapper dies.
Never break that lock. Also preserve directories named by live commands, covering older runs
without a lock and builders starting lockf. The machine lock serializes new run creation and
normal wrapper cleanup. Unknown liveness or filesystem errors preserve evidence rather than delete.
"""
import contextlib
import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import sys


def prune(directory):
    try:
        commands = subprocess.check_output(["/bin/ps", "-axo", "command="], text=True)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"TestRuns pruning skipped: cannot check live commands: {error}", file=sys.stderr)
        return
    with contextlib.ExitStack() as locks:
        idle = []
        for path in directory.glob("run.*"):
            if path.is_symlink() or not path.is_dir():
                continue
            if str(path.absolute()) in commands or str(path.resolve()) in commands:
                continue
            try:
                modified = path.stat().st_mtime_ns
                lock = path / ".active.lock"
                if lock.exists():
                    descriptor = os.open(lock, os.O_RDONLY | os.O_NOFOLLOW)
                    locks.callback(os.close, descriptor)
                    try:
                        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    except BlockingIOError:
                        continue
                if not any(child.name != ".active.lock" for child in path.iterdir()):
                    lock.unlink(missing_ok=True)
                    path.rmdir()
                else:
                    idle.append((modified, path))
            except OSError as error:
                print(f"TestRuns pruning preserved {path}: {error}", file=sys.stderr)
        for _, path in sorted(idle, reverse=True)[5:]:
            try:
                # A killed host may leave mode-0 fixtures. Physical traversal preserves linked targets.
                subprocess.run(["/bin/chmod", "-R", "-P", "u+rwx", str(path)], check=False, stderr=subprocess.DEVNULL)
                shutil.rmtree(path)
            except OSError as error:
                print(f"TestRuns pruning preserved {path}: {error}", file=sys.stderr)


if __name__ == "__main__":
    prune(Path(sys.argv[1]))
