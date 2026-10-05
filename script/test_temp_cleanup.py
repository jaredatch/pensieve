#!/usr/bin/env python3
"""Best-effort removal of old, empty UUID directories left by Apple's Xcode tools."""
import os
import re
import sys
import time

UUID_NAME = re.compile(r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\Z")


def sweep(directory):
    cutoff = time.time() - 60 * 60
    deadline = time.monotonic() + 0.25
    try:
        with os.scandir(directory) as entries:
            for entry in entries:
                if time.monotonic() >= deadline:
                    break
                if not UUID_NAME.fullmatch(entry.name):
                    continue
                try:
                    if entry.is_dir(follow_symlinks=False) and entry.stat(follow_symlinks=False).st_mtime < cutoff:
                        # rmdir is the emptiness check: a populated directory is never removed.
                        os.rmdir(entry.path)
                except OSError:
                    pass
    except OSError:
        pass


if __name__ == "__main__":
    sweep(sys.argv[1])
