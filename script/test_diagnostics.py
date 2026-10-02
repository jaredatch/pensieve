#!/usr/bin/env python3
"""Relay new, atomically written timeout reports despite xcodebuild's stdout buffering."""
import os
import pathlib
import signal
import sys
import time


def relay(directory, parent_pid):
    running = True
    seen = set(directory.glob("*.txt"))

    def stop(_signum, _frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while os.getppid() == parent_pid:
        for path in sorted(directory.glob("*.txt")):
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


if __name__ == "__main__":
    relay(pathlib.Path(sys.argv[1]), int(sys.argv[2]))
