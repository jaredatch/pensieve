#!/usr/bin/env python3
"""Black-box pensieve contract tests; the binary and a local protocol peer are the only interfaces."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import tempfile
import threading
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

    def run_cli(self, *arguments, code=0, json_output=True, invocation="absolute"):
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
        args = [executable, *arguments, "--app-support", str(self.root)]
        if json_output:
            args.append("--json")
        result = subprocess.run(args, input="", text=True, capture_output=True,
            env=environment, cwd=self.root, timeout=15)
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

    def peer(self, *, reply=None, bundle=None, protocol=1):
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
                        "protocolVersion": protocol, "appVersion": self.info["CFBundleShortVersionString"]}).encode() + b"\n")
                    line = connection.makefile("rb").readline(65537)
                    if line:
                        observed.append(json.loads(line))
                        response = reply or {"envelope": {"schema": 1, "ok": True, "changed": False,
                            "data": [{"slug": "review", "name": "Review"}], "next": []}, "exitCode": 0}
                        connection.sendall(json.dumps(response).encode() + b"\n")
            except Exception as error:
                failures.append(error)

        worker = threading.Thread(target=serve, daemon=True)
        worker.start()

        def finish():
            worker.join(15)
            self.assertFalse(worker.is_alive(), "Stub peer did not finish")
            self.assertEqual(failures, [])
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
        self.run_cli("skill", "show", "review", "--content")
        finish()
        self.assertTrue(observed[0]["content"])

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
                    "commands", "completion", "version", "help"}
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
                           if code not in (10, 27, 0x90, 0x98, 0x9b, 0x9d, 0x9e, 0x9f))
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
