#!/usr/bin/env python3
"""Best-effort removal of old temporary artifacts left by Xcode and Foundation."""
import os
import re
import stat
import sys
import time

UUID = r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}"
UUID_NAME = re.compile(UUID + r"\Z")
PROCESS_NAME = re.compile(UUID + r"-[0-9]+-[0-9A-Fa-f]+\Z")
TEMPORARY_NAME = re.compile(r"TemporaryDirectory\.[A-Za-z0-9]{6}\Z")
ROOT_NAME = re.compile("|".join(pattern.pattern for pattern in (UUID_NAME, PROCESS_NAME, TEMPORARY_NAME)))
ICON_NAME = re.compile(r"Pensieve1024x1024_[A-Za-z0-9]+_" + UUID + r"-([0-9]+)-[0-9A-Fa-f]+\.png\Z")


def process_is_dead(pid):
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return True
    except (OSError, OverflowError):
        pass
    return False


def remove_artifact(parent, name, cutoff, deadline):
    descriptor = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    try:
        if os.fstat(descriptor).st_mtime >= cutoff:
            return
        with os.scandir(descriptor) as entries:
            entry = next(entries, None)
            if entry is not None and next(entries, None) is not None:
                return
        if entry is not None:
            temporary = TEMPORARY_NAME.fullmatch(name)
            if temporary:
                if entry.name != ".keep-directory":
                    return
            else:
                icon = ICON_NAME.fullmatch(entry.name)
                if icon is None or not process_is_dead(icon.group(1)):
                    return
            leaf = os.open(entry.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor)
            try:
                info = os.fstat(leaf)
                if not stat.S_ISREG(info.st_mode) or (temporary and info.st_size != 0):
                    return
                if time.monotonic() >= deadline:
                    return
                os.unlink(entry.name, dir_fd=descriptor)
            finally:
                os.close(leaf)
        if time.monotonic() < deadline:
            # An entry arriving after inspection keeps the folder: never recursively delete.
            os.rmdir(name, dir_fd=parent)
    finally:
        os.close(descriptor)


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
                            if UUID_NAME.fullmatch(entry.name) or TEMPORARY_NAME.fullmatch(entry.name):
                                remove_artifact(descriptor, entry.name, cutoff, deadline)
                            else:
                                # Process folders are eligible only when rmdir proves them empty.
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
    sweep_directory(directory, ROOT_NAME, cutoff, started + 0.25)


if __name__ == "__main__":
    sweep(sys.argv[1])
