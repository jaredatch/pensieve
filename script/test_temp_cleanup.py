#!/usr/bin/env python3
"""Best-effort removal of old, empty directories left by Xcode and Foundation."""
import os
import re
import sys
import time

UUID = r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}"
UUID_NAME = re.compile(UUID + r"\Z")
PROCESS_NAME = re.compile(UUID + r"-[0-9]+-[0-9A-Fa-f]+\Z")


def sweep_directory(directory, name_pattern, cutoff, deadline):
    try:
        # Bind removals to this directory and never follow a linked debug temp folder.
        descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            with os.scandir(descriptor) as entries:
                for entry in entries:
                    if time.monotonic() >= deadline:
                        break
                    if not name_pattern.fullmatch(entry.name):
                        continue
                    try:
                        if entry.is_dir(follow_symlinks=False) and entry.stat(follow_symlinks=False).st_mtime < cutoff:
                            # rmdir is the emptiness check: a populated directory is never removed.
                            os.rmdir(entry.name, dir_fd=descriptor)
                    except OSError:
                        pass
        finally:
            os.close(descriptor)
    except OSError:
        pass


def sweep(directory):
    cutoff = time.time() - 60 * 60
    started = time.monotonic()
    # Share the existing 250 ms budget so a large debug folder cannot starve the root sweep.
    sweep_directory(os.path.join(directory, "com.jaredatch.Pensieve.debug"), PROCESS_NAME, cutoff, started + 0.125)
    sweep_directory(directory, UUID_NAME, cutoff, started + 0.25)


if __name__ == "__main__":
    sweep(sys.argv[1])
