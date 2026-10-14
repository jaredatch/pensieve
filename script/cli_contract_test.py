#!/usr/bin/env python3
"""Black-box pensieve contract tests; the binary and a local protocol peer are the only interfaces."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
import pty
import signal
import socket
import subprocess
import tempfile
import threading
import time
import unicodedata
import unittest

BINARY = None


class CLIContractTests(unittest.TestCase):
    def setUp(self):
        # A short random basename keeps the endpoint below Darwin's limit inside the runner's TMPDIR.
        self.temporary = tempfile.TemporaryDirectory(prefix="c")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.app = BINARY.parent.parent.parent.resolve()
        self.info = plistlib.loads((self.app / "Contents/Info.plist").read_bytes())
        self.endpoint = self.root / (self.info["CFBundleIdentifier"] + ".sock")
        self.environment = dict(os.environ, CFFIXED_USER_HOME=str(self.root), HOME=str(self.root), NO_COLOR="1")

    def run_cli(self, *arguments, code=0, json_output=True, invocation="absolute", app_support=True,
                input_text="", timeout=15):
        environment = self.environment.copy()
        executable = str(BINARY)
        if invocation != "absolute":
            directory = BINARY.parent
            if invocation == "symlink":
                directory = self.root / "bin"
                directory.mkdir(exist_ok=True)
                link = directory / "pensieve"
                if not link.is_symlink():
                    link.symlink_to(BINARY)
            environment["PATH"] = str(directory) + os.pathsep + environment.get("PATH", "")
            executable = "pensieve"
        args = [executable, *arguments]
        if app_support:
            args += ["--app-support", str(self.root)]
        if json_output:
            args.append("--json")
        result = subprocess.run(args, input=input_text, text=True, capture_output=True,
            env=environment, cwd=self.root, timeout=timeout)
        self.assertNotIn("Scope", result.stderr, "Piped input must never receive a scope prompt")
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        self.assertNotIn("\x1b", result.stdout + result.stderr)
        if not json_output:
            return result
        envelope = json.loads(result.stdout)  # rejects a second value or any extra text
        self.assertEqual(envelope["schema"], 1)
        self.assertEqual(envelope["ok"], code == 0)
        if code:
            self.assertIsInstance(envelope["error"]["code"], str)
            self.assertTrue(envelope["error"]["hint"])
            self.assertIsInstance(envelope["error"]["retryable"], bool)
        return envelope

    def peer(self, *, reply=None, bundle=None, protocol=1, commit=False, drop_reply=False,
             reply_delay=0, release_reply=None):
        listener = socket.socket(socket.AF_UNIX)
        self.addCleanup(listener.close)
        listener.bind(str(self.endpoint))
        listener.listen(1)
        listener.settimeout(10)
        observed, failures = [], []

        def serve():
            try:
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(10)
                    connection.sendall(json.dumps({"bundlePath": str(bundle or self.app),
                        "protocolVersion": protocol, "appVersion": self.info["CFBundleShortVersionString"],
                        "supportsReadiness": commit, "supportsCommit": commit}).encode() + b"\n")
                    reader = connection.makefile("rb")
                    line = reader.readline(65537)
                    if line:
                        observed.append(json.loads(line))
                        if commit:
                            connection.sendall(b'{"ready":true}\n')
                            self.assertTrue(observed[-1]["requiresCommit"])
                            self.assertEqual(json.loads(reader.readline(65537)), {"commit": True})
                        if drop_reply:
                            return
                        if release_reply is not None:
                            release_reply.wait(10)
                            return
                        if reply_delay:
                            time.sleep(reply_delay)
                        response = reply or {"envelope": {"schema": 1, "ok": True, "changed": False,
                            "data": [{"slug": "review", "name": "Review"}], "next": []}, "exitCode": 0}
                        connection.sendall(json.dumps(response).encode() + b"\n")
            except (BrokenPipeError, ConnectionResetError) as error:
                if not reply_delay:
                    failures.append(error)
            except Exception as error:
                failures.append(error)

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()

        def finish():
            if release_reply is not None:
                release_reply.set()
            try:
                worker.join(15)
                self.assertFalse(worker.is_alive(), "Stub peer did not finish")
                self.assertEqual(failures, [])
            finally:
                listener.close()
                self.endpoint.unlink(missing_ok=True)

        return observed, finish

    def test_version_matches_containing_app_and_cli_has_no_ui_or_database_link(self):
        for invocation in ("absolute", "path", "symlink"):
            for command in ("version", "--version"):
                with self.subTest(command=command, invocation=invocation):
                    data = self.run_cli(command, invocation=invocation)["data"]
                    self.assertEqual(data["version"], self.info["CFBundleShortVersionString"])
        output = subprocess.check_output(["/usr/bin/otool", "-L", str(BINARY)], text=True, timeout=30)
        self.assertNotIn("SwiftData", output)
        self.assertNotIn("SwiftUI", output)

    def test_app_requests_and_aliases_carry_exact_commands_and_content_opt_in(self):
        # A failed stub must release its endpoint before another subtest starts.
        with self.subTest(command="failed peer cleanup"):
            _, finish = self.peer()
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(str(self.endpoint))
                client.recv(4096)
                client.sendall(b"not-json\n")
            with self.assertRaises(AssertionError):
                finish()
            self.assertFalse(self.endpoint.exists())
        cases = [("skill list", "skill list"), ("skill ls", "skill list"), ("skills", "skill list"),
                 ("skill show review", "skill show"), ("agent list", "agent list"),
                 ("machine list", "machine list"), ("project list", "project list")]
        cases += [("skill list", "skill list", "path"), ("skill list", "skill list", "symlink")]
        for case in cases:
            command, expected = case[:2]
            invocation = case[2] if len(case) == 3 else "absolute"
            with self.subTest(command=command, invocation=invocation):
                observed, finish = self.peer()
                try:
                    result = self.run_cli(*command.split(), invocation=invocation)
                finally:
                    finish()
                self.assertEqual(result["data"], [{"slug": "review", "name": "Review"}])
                self.assertEqual(observed[0]["command"], expected)
                self.assertEqual(observed[0]["protocolVersion"], 1)
                self.assertFalse(observed[0]["content"])
                self.assertEqual(observed[0]["arguments"], ["review"] if expected == "skill show" else [])
        observed, finish = self.peer()
        try:
            self.run_cli("skill", "show", "review", "--content")
        finally:
            finish()
        self.assertTrue(observed[0]["content"])

    def test_write_commands_carry_targets_json_and_app_support(self):
        cases = [("deploy", "review", "other", "-a", "claude-code", "-a", "codex", "-g", "-m", "Mini", "-m", "Laptop"),
                 ("undeploy", "review", "-a", "*", "-p", ".", "--dry-run"), ("sync",)]
        for command in cases:
            with self.subTest(command=command):
                observed, finish = self.peer(commit=True)
                try:
                    result = self.run_cli(*command)
                finally:
                    finish()
                self.assertTrue(result["ok"])
                self.assertEqual(observed[0]["command"], command[0])
                if command[0] != "sync":
                    targets = observed[0]["deployment"]
                    self.assertEqual(targets["workingDirectory"], str(self.root.resolve()))
                    if command[0] == "deploy":
                        self.assertEqual(observed[0]["arguments"], ["review", "other"])
                        self.assertEqual(targets["agents"], ["claude-code", "codex"])
                        self.assertTrue(targets["global"])
                        self.assertEqual(targets["machines"], ["Mini", "Laptop"])
                    else:
                        self.assertEqual(targets["project"], ".")
                        self.assertTrue(targets["dryRun"])

        for prompted in (False, True):
            with self.subTest(project="tilde", prompted=prompted):
                observed, finish = self.peer(commit=True)
                try:
                    if not prompted:
                        self.run_cli("deploy", "review", "-a", "claude", "--project=~/code/app")
                    else:
                        master, slave = pty.openpty()
                        try:
                            os.write(master, b"~/code/app\n")
                            result = subprocess.run([str(BINARY), "deploy", "review", "-a", "claude", "--json",
                                "--app-support", str(self.root)], stdin=slave, text=True, capture_output=True,
                                env=self.environment, cwd=self.root, timeout=10)
                            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        finally:
                            os.close(slave)
                            os.close(master)
                    self.assertEqual(observed[0]["deployment"]["project"], str(self.root / "code/app"))
                finally:
                    finish()

    def test_lost_reply_after_commit_never_reports_retryable_refusal(self):
        observed, finish = self.peer(commit=True, drop_reply=True)
        try:
            result = self.run_cli("deploy", "review", "-a", "claude", "-g", code=3)
        finally:
            finish()
        self.assertEqual(len(observed), 1)
        self.assertFalse(result["error"]["retryable"])
        self.assertIn("Check", result["error"]["hint"])

    def test_interrupt_after_commit_exits_130(self):
        listener = socket.socket(socket.AF_UNIX)
        self.addCleanup(listener.close)
        listener.bind(str(self.endpoint))
        listener.listen(1)
        listener.settimeout(10)
        accepted, release = threading.Event(), threading.Event()
        failures = []

        def serve():
            try:
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(10)
                    connection.sendall(json.dumps({"bundlePath": str(self.app), "protocolVersion": 1,
                        "appVersion": "fixture", "supportsCommit": True}).encode() + b"\n")
                    reader = connection.makefile("rb")
                    self.assertEqual(json.loads(reader.readline())["command"], "sync")
                    connection.sendall(b'{"ready":true}\n')
                    self.assertEqual(json.loads(reader.readline()), {"commit": True})
                    accepted.set()
                    self.assertTrue(release.wait(10), "Test did not release its accepted peer")
            except Exception as error:
                failures.append(error)

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()
        client = subprocess.Popen([str(BINARY), "sync", "--json", "--app-support", str(self.root)],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.environment)
        try:
            self.assertTrue(accepted.wait(10), "Client never committed its command")
            client.send_signal(signal.SIGINT)
            stdout, stderr = client.communicate(timeout=5)
            self.assertEqual(client.returncode, 130, stdout + stderr)
            envelope = json.loads(stdout)
            self.assertEqual(envelope["error"]["code"], "interrupted")
            self.assertFalse(envelope["error"]["retryable"])
        finally:
            release.set()
            if client.poll() is None:
                client.kill()
                client.communicate(timeout=5)
            worker.join(10)
            self.assertFalse(worker.is_alive())
            self.assertEqual(failures, [])

        listener.close()
        self.endpoint.unlink()
        self.assert_reply_wins_after_print()

    def assert_reply_wins_after_print(self):
        # Pause only the CLI worker's final libc exit. SIGINT then reaches the main signal
        # handler after a complete reply, without adding a production timing hook.
        source = self.root / "exit.c"
        library = self.root / "exit.dylib"
        receipt, release = self.root / "exit-entered", self.root / "exit-release"
        source.write_text(r'''
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static _Atomic int held_exit = 0;
static void wait_worker_exit(int status) {
    if (!atomic_exchange(&held_exit, 1)) {
        FILE *receipt = fopen(getenv("PENSIEVE_EXIT_RECEIPT"), "w");
        if (receipt) { fprintf(receipt, "%d", status); fclose(receipt); }
        for (int i = 0; i < 10000 && access(getenv("PENSIEVE_EXIT_RELEASE"), F_OK); i++) usleep(1000);
    }
    exit(status);
}
__attribute__((used)) static struct { const void *replacement; const void *original; }
interpose_exit __attribute__((section("__DATA,__interpose"))) = { (void *)wait_worker_exit, (void *)exit };
''')
        subprocess.run(["/usr/bin/clang", "-dynamiclib", str(source), "-o", str(library)],
                       check=True, capture_output=True, timeout=30)
        environment = dict(self.environment, DYLD_INSERT_LIBRARIES=str(library),
            PENSIEVE_EXIT_RECEIPT=str(receipt), PENSIEVE_EXIT_RELEASE=str(release))
        for code in (0, 4):
            receipt.unlink(missing_ok=True)
            release.unlink(missing_ok=True)
            envelope = {"schema": 1, "ok": code == 0, "changed": False, "data": {"result": "own reply"}}
            if code:
                envelope["error"] = {"code": "skill_not_found", "message": "Missing", "hint": "List skills", "retryable": False}
            observed, finish = self.peer(commit=True, reply={"envelope": envelope, "exitCode": code})
            client = subprocess.Popen([str(BINARY), "sync", "--json", "--app-support", str(self.root)],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
            try:
                deadline = time.monotonic() + 10
                while not receipt.exists() and client.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(receipt.exists(), "Worker never reached exit after printing its reply")
                self.assertEqual(int(receipt.read_text()), code)
                client.send_signal(signal.SIGINT)
                stdout, stderr = client.communicate(timeout=5)
                self.assertEqual(json.loads(stdout), envelope)
                self.assertEqual(client.returncode, code, "A printed reply owns the exit code after SIGINT: " + stderr)
            finally:
                release.touch()
                if client.poll() is None:
                    client.kill()
                    client.communicate(timeout=5)
                finish()

    def test_missing_scope_and_invalid_machine_scope_refuse_without_sending(self):
        for command in ("deploy", "undeploy"):
            for options in ((), ("-m", "Mini"), ("-p", ".", "-m", "Mini")):
                with self.subTest(command=command, options=options):
                    result = self.run_cli(command, "review", "-a", "claude", *options, code=64, input_text="g\n")
                    self.assertEqual(result["error"]["code"], "usage")
                    self.assertIn("-g", result["error"]["message"])
            listener = socket.socket(socket.AF_UNIX)
            try:
                listener.bind(str(self.endpoint))
                listener.listen(1)
                listener.settimeout(.1)
                for scope in ("g\n", str(self.root) + "\n"):
                    self.run_cli(command, "review", "-a", "codex", code=64, input_text=scope)
                    with self.assertRaises(socket.timeout):
                        listener.accept()
            finally:
                listener.close()
                self.endpoint.unlink()
            for no_input in ("flag", "environment"):
                master, slave = pty.openpty()
                try:
                    environment = self.environment.copy()
                    args = [str(BINARY), command, "review", "-a", "claude", "--json", "--app-support", str(self.root)]
                    if no_input == "flag":
                        args.append("--no-input")
                    else:
                        environment["PENSIEVE_NO_INPUT"] = "1"
                    result = subprocess.run(args, stdin=slave, text=True, capture_output=True, env=environment, timeout=5)
                    self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
                    self.assertEqual(json.loads(result.stdout)["error"]["code"], "usage")
                finally:
                    os.close(slave)
                    os.close(master)

    def test_sync_waits_for_its_cycle_and_reports_still_running_after_deadline(self):
        expected = {"schema": 1, "ok": True, "changed": True,
                    "data": {"result": "synced", "pushed": False, "pulled": True, "warnings": ["own cycle"]}}
        with self.subTest(wait="cycle longer than 30 seconds"):
            observed, finish = self.peer(commit=True, reply_delay=31,
                reply={"envelope": expected, "exitCode": 0})
            try:
                self.assertEqual(self.run_cli("sync", timeout=40), expected)
            finally:
                finish()
            self.assertEqual(observed[0]["command"], "sync")

        # Interpose only long poll waits in this child. The real client selects and passes its
        # production deadline; a kernel timeout is returned early so this case stays bounded.
        source = self.root / "poll.c"
        library = self.root / "poll.dylib"
        receipt = self.root / "poll-timeout"
        source.write_text(r'''
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
static int expire_poll(struct pollfd *fds, nfds_t count, int milliseconds) {
    if (milliseconds > 25000 && count == 1 && (fds[0].events & POLLIN)) {
        FILE *receipt = fopen(getenv("PENSIEVE_POLL_RECEIPT"), "w");
        if (receipt) { fprintf(receipt, "%d", milliseconds); fclose(receipt); }
        return poll(fds, count, 100);
    }
    return poll(fds, count, milliseconds);
}
__attribute__((used)) static struct { const void *replacement; const void *original; }
interpose_poll __attribute__((section("__DATA,__interpose"))) = { (void *)expire_poll, (void *)poll };
''')
        subprocess.run(["/usr/bin/clang", "-dynamiclib", str(source), "-o", str(library)],
                       check=True, capture_output=True, timeout=30)
        self.environment.update(DYLD_INSERT_LIBRARIES=str(library), PENSIEVE_POLL_RECEIPT=str(receipt))
        for command, seconds, code in [("sync", 600, "sync_still_running"), ("skill", 30, "app_unavailable")]:
            release = threading.Event()
            observed, finish = self.peer(commit=True, release_reply=release)
            try:
                args = (command,) if command == "sync" else (command, "list")
                result = self.run_cli(*args, code=3)
                requested = int(receipt.read_text())
                self.assertGreaterEqual(requested, seconds * 1000 - 100)
                self.assertLessEqual(requested, seconds * 1000 + 1)
                self.assertEqual(result["error"]["code"], code)
                self.assertFalse(result["error"]["retryable"])
                if command == "sync":
                    self.assertIn("still running in Pensieve", result["error"]["message"])
                    self.assertIn("pensieve status", result["error"]["hint"])
                    self.assertNotIn("failed", result["error"]["message"].lower())
                self.assertEqual(len(observed), 1)
            finally:
                finish()

    def test_wrong_copy_and_protocol_are_refused_before_sending_a_command(self):
        cases = [(self.root / "Other.app", 1, "wrong_app", invocation)
                 for invocation in ("absolute", "path", "symlink")]
        cases.append((self.app, 999, "protocol_mismatch", "absolute"))
        for bundle, protocol, error, invocation in cases:
            with self.subTest(error=error, invocation=invocation):
                observed, finish = self.peer(bundle=bundle, protocol=protocol)
                try:
                    self.assertEqual(self.run_cli("skill", "list", code=3, invocation=invocation)["error"]["code"], error)
                finally:
                    finish()
                self.assertEqual(observed, [], "A refused handshake must receive no command")

    def test_envelope_and_exit_codes_survive_transport(self):
        for code, error in [(0, None), (1, "partial"), (2, "store_unreadable"), (3, "app_starting"),
                            (4, "skill_not_found"), (5, "ambiguous"), (64, "usage"), (130, "interrupted")]:
            with self.subTest(code=code):
                envelope = {"schema": 1, "ok": code == 0}
                if error:
                    envelope["error"] = {"code": error, "message": "Fixture failure", "hint": "Try the app", "retryable": False}
                else:
                    envelope.update(changed=False, data={"answer": "current", "futureFraction": 1.5, "nested": [True, None, 42]}, next=["pensieve status"])
                observed, finish = self.peer(reply={"envelope": envelope, "exitCode": code})
                try:
                    self.assertEqual(self.run_cli("skill", "list", code=code), envelope)
                finally:
                    finish()
                self.assertEqual(len(observed), 1)

    def test_unavailable_stale_and_overlong_endpoints_are_never_removed(self):
        self.assertEqual(self.run_cli("skill", "list", "--no-input", code=3)["error"]["code"], "app_unavailable")
        stale = socket.socket(socket.AF_UNIX)
        stale.bind(str(self.endpoint))
        stale.close()
        inode = self.endpoint.lstat().st_ino
        self.run_cli("skill", "list", code=3)
        self.assertEqual(self.endpoint.lstat().st_ino, inode)
        self.environment["PENSIEVE_NO_INPUT"] = "1"
        long = str(self.root / ("é" * 80))
        result = subprocess.run([str(BINARY), "skill", "list", "--json", "--app-support", long],
            input="", text=True, capture_output=True, env=self.environment, timeout=15)
        self.assertEqual(result.returncode, 3)
        self.assertIn(long, json.loads(result.stdout)["error"]["message"])

    def test_disk_readers_work_without_app_and_reject_missing_or_unreadable_state(self):
        cases = [("status",), ("log",), ("deployment", "list"), ("deployed",)]
        for command in cases:
            self.assertEqual(self.run_cli(*command, code=2)["error"]["code"], "state_unreadable")
        (self.root / "daemon-status.json").write_text(json.dumps({"timestamp": "2026-10-13T10:00:00Z",
            "result": "synced", "detail": "upToDate"}))
        (self.root / "daemon.log").write_text("first\nsecond\n")
        (self.root / "daemon.log.1").write_text("older\n")
        (self.root / "deploy-state.json").write_text(json.dumps({"schema_version": 1, "records": [{
            "slug": "review", "platform": "claudeCode", "scope": "user", "artifact_path": "/fixture/review",
            "recorded_at": "2026-10-13T10:00:00Z"}]}))
        self.assertEqual(self.run_cli("status")["data"]["result"], "synced")
        self.assertEqual(self.run_cli("log", "--lines", "2")["data"]["lines"], ["first", "second"])
        (self.root / "daemon.log").write_text("first\n\nsecond\n\n")
        self.assertEqual(self.run_cli("log", "--lines", "4")["data"]["lines"], ["first", "", "second", ""])
        human = self.run_cli("log", "--lines", "4", json_output=False).stdout
        self.assertEqual(sum(not line.strip() for line in human.splitlines()), 2)
        for args in [("--app-support", str(self.root), "--json", "status"),
                     ("status", "--app-support=" + str(self.root))]:
            self.assertEqual(self.run_cli(*args, app_support=False)["data"]["result"], "synced")
        for command in cases[2:]:
            self.assertEqual(self.run_cli(*command)["data"]["records"][0]["platform"], "claude")
        for name in ("daemon-status.json", "daemon.log", "deploy-state.json"):
            (self.root / name).write_bytes(b"\xff")
        for command in cases:
            self.run_cli(*command, code=2)

    def test_help_catalog_completion_and_usage_are_machine_readable(self):
        root = self.run_cli("commands")["data"]["command"]
        commands = {command["commandName"]: command for command in root["subcommands"]}
        expected = {"skill", "skills", "agent", "machine", "project", "deployment", "deployed", "status", "log",
                    "commands", "completion", "version", "help", "deploy", "undeploy", "sync", "install"}
        self.assertEqual(set(commands), expected)
        skill_commands = {command["commandName"]: command for command in commands["skill"]["subcommands"]}
        self.assertIn("ls", skill_commands["list"]["aliases"])
        self.assertIn("--version", commands["version"]["aliases"])
        help_data = self.run_cli("skill", "show", "--help")["data"]["command"]
        self.assertEqual(help_data["commandName"], "show")
        self.assertIn("skill", {argument["valueName"] for argument in help_data["arguments"]})
        self.assertIn("content", {name["name"] for arg in help_data["arguments"] for name in arg.get("names", [])})
        for shell in ("bash", "zsh", "fish"):
            self.assertIn("pensieve", self.run_cli("completion", shell)["data"]["script"])
        for noun in ("skill", "agent", "machine", "project", "deployment"):
            self.assertIn("USAGE:", self.run_cli(noun, json_output=False).stdout)
        for args in [("sk",), ("skill", "li"), ("log", "--lines", "0"), ("skill", "list", "--bogus")]:
            self.assertEqual(self.run_cli(*args, code=64)["error"]["code"], "usage")
        for args in [("--app-support", "--json", "status"), ("status", "--app-support"),
                     ("skill", "list", "--app-support"), ("--app-support", "--version")]:
            with self.subTest(arguments=args):
                self.assertEqual(self.run_cli(*args, code=64, app_support=False)["error"]["code"], "usage")
        self.assertEqual(self.run_cli("--json", "--version")["data"]["version"], self.info["CFBundleShortVersionString"])

    def test_piped_human_output_stays_human_and_untruncated(self):
        rows = [{"slug": "skill-" + str(index), "name": "Full skill " + str(index)} for index in range(200)]
        rows[0].update(tags=["one", "two"], installed=True, count=42, ratio=1.5, metadata={"optional": None}, empty=[])
        for command in [("skill", "list"), ("agent", "list"), ("machine", "list"), ("project", "list")]:
            with self.subTest(command=command):
                observed, finish = self.peer(reply={"envelope": {"schema": 1, "ok": True, "data": rows}, "exitCode": 0})
                try:
                    result = self.run_cli(*command, json_output=False)
                finally:
                    finish()
                self.assertIn("skill-199", result.stdout)
                self.assertNotIn('"schema"', result.stdout)
                self.assertEqual(result.stderr, "")
                self.assertEqual(len(observed), 1)
                for field in ["tags:", "installed: true", "count: 42", "ratio: 1.5", "metadata:", "optional: null", "[]"]:
                    self.assertIn(field, [line.strip() for line in result.stdout.splitlines()])

        escapes = "\x1b[31m\x90ignored\x9c\x98ignored\x9c\x9b31m\x9dignored\x07\x9eignored\x9c\x9fignored\x9c"
        controls = "".join(chr(code) for code in [*range(32), *range(127, 160)]
                           if code not in (9, 10, 13, 27, 0x90, 0x98, 0x9b, 0x9d, 0x9e, 0x9f))
        body = "---\nname: Review\n---\n\n# Review\nFirst line\nSecond" + controls + " line" + escapes + "\n"
        clean_lines = ["---", "name: Review", "---", "", "# Review", "First line", "Second line"]
        observed, finish = self.peer(reply={"envelope": {"schema": 1, "ok": True,
            "data": {"slug": "review", "content": body, "tags": ["one", "two"]}}, "exitCode": 0})
        try:
            result = self.run_cli("skill", "show", "review", "--content", json_output=False)
        finally:
            finish()
        with self.subTest(command="skill show --content"):
            lines = [line.strip() for line in result.stdout.splitlines()]
            start = lines.index("---") if "---" in lines else -1
            self.assertGreaterEqual(start, 0, result.stdout)
            self.assertEqual(lines[start:start + len(clean_lines)], clean_lines)
            self.assertFalse(any(unicodedata.category(char) == "Cc" and char != "\n" for char in result.stdout))
            self.assertTrue(observed[0]["content"])

        for ending in ("\n", "\r\n", "\r"):
            with self.subTest(line_ending=repr(ending)):
                body = ending.join(["# Body", "slug: spoofed", "\tkey\tvalue"])
                observed, finish = self.peer(reply={"envelope": {"schema": 1, "ok": True,
                    "data": {"slug": "review", "content": body}}, "exitCode": 0})
                try:
                    result = self.run_cli("skill", "show", "review", "--content", json_output=False)
                finally:
                    finish()
                self.assertIn("content:\n  # Body\n  slug: spoofed\n      key    value\nslug: review\n", result.stdout)

        records = [{"slug": slug, "platform": platform, "scope": "user", "artifact_path": "/fixture/" + slug,
                    "recorded_at": "2026-10-13T10:00:00Z"}
                   for slug, platform in [("review", "claudeCode"), ("other", "codex")]]
        (self.root / "deploy-state.json").write_text(json.dumps({"schema_version": 1, "records": records}))
        for command in [("deployment", "list"), ("deployed",)]:
            with self.subTest(command=command):
                result = self.run_cli(*command, json_output=False)
                lines = [line.strip() for line in result.stdout.splitlines()]
                self.assertIn("records:", lines)
                self.assertIn("schema_version: 1", lines)
                for record in records:
                    for key, value in record.items():
                        value = "claude" if value == "claudeCode" else value
                        self.assertIn(f"{key}: {value}", lines)
                self.assertEqual(lines.count("scope: user"), 2)

        for outcome, code in [("synced", 0), ("failed", 1)]:
            with self.subTest(command="status", outcome=outcome):
                status = {"timestamp": "2026-10-13T10:00:00Z", "result": outcome, "detail": "Fixture result"}
                (self.root / "daemon-status.json").write_text(json.dumps(status))
                result = self.run_cli("status", code=code, json_output=False)
                for key, value in status.items():
                    self.assertIn(f"{key}: {value}", [line.strip() for line in result.stdout.splitlines()])
                self.assertRegex(result.stdout, r"last cycle .* \(.* ago\): " + outcome)
                self.assertIn("stale: daemon may be disabled or the Mac was asleep", result.stdout)
        status["timestamp"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        status["result"] = "synced"
        (self.root / "daemon-status.json").write_text(json.dumps(status))
        fresh = self.run_cli("status", json_output=False).stdout
        self.assertRegex(fresh, r"last cycle .* \(.* ago\): synced")
        self.assertNotIn("stale:", fresh)
        (self.root / "daemon.log").write_text("first\nsecond\x07\x1b[31m\n")
        result = self.run_cli("log", json_output=False)
        self.assertIn("lines:", result.stdout)
        self.assertIn("first", result.stdout)
        self.assertIn("second", result.stdout)
        self.assertNotIn("\x07", result.stdout)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    BINARY = args.binary.resolve(strict=True)
    from cli_launch_tests import CLILaunchTests
    CLILaunchTests.binary = BINARY
    unittest.main(argv=[__file__, *remaining])
