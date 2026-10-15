"""Check shipped eval commands against the built CLI's parser and validation."""
import copy
import json
import re
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


class CLISkillTests(unittest.TestCase):
    binary = None

    def test_public_docs_explain_command_and_installation(self):
        root = Path(__file__).resolve().parent.parent
        for name in ["README.md", "CHANGELOG.md", "docs/SPEC.md"]:
            with self.subTest(document=name):
                prose = (root / name).read_text().lower()
                for term in ["pensieve", "doctor", "settings", "install", "homebrew"]:
                    self.assertIn(term, prose, f"{name} must describe command setup ({term})")

    def test_eval_commands_and_flags_exist_in_built_cli(self):
        source = Path(__file__).resolve().parent.parent / "skills/pensieve-evals.json"
        evals = json.loads(source.read_text())["evals"]
        self.assertTrue(evals, "The skill must ship nonempty evals")
        self.assertEqual(len({case["id"] for case in evals}), len(evals), "Eval IDs must be unique")
        temporary = tempfile.TemporaryDirectory(prefix="skill-evals-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.support = self.home / "support"
        self.support.mkdir()
        self.project = self.home / "Demo project"
        self.project.mkdir()
        self.results = {}
        for case in evals:
            with self.subTest(eval=case["id"]):
                self.check_eval(case)

        # The binary owns option syntax and commands answered without an app.
        for command in [
            "pensieve commands --json",
            "pensieve deploy --help --json",
            "pensieve version --json",
            "pensieve status --json",
            "pensieve deploy review --agent=claude -g --json",
            "pensieve deploy review -ga claude --json",
        ]:
            with self.subTest(accepted_command=command):
                self.check_command(command, "command-control")

        for command, message in [
            ("pensieve deploy review -g --json", "Name an agent with -a"),
            ("pensieve deploy review -a grok -m {mini_id} --json", "-m requires -g"),
            ("pensieve deploy review -a claude -g -p . --json", "Choose -g or -p, one scope at a time"),
            ("pensieve install {repository_url} --rename --skip --json", "Choose --rename or --skip"),
        ]:
            with self.subTest(rejected_command=command):
                with self.assertRaisesRegex(AssertionError, "Built CLI rejected eval command.*" + re.escape(message)):
                    self.check_command(command, "command-control")

        for value in ["{unknown}", "{", "}"]:
            with self.subTest(placeholder=value):
                with self.assertRaisesRegex(AssertionError, "Unresolved placeholder.*placeholder-control"):
                    self.check_command(f"pensieve skill show '{value}' --json", "placeholder-control")

        approved = next(case for case in evals if case["id"] == "delete-with-approval")
        for fault, message in [
            ("preview", "must follow a matching --dry-run"),
            ("different-preview", "must follow a matching --dry-run"),
            ("token", "must carry --confirm-plan"),
            ("approval", "must have approval"),
            ("report", "must have a report"),
        ]:
            case = copy.deepcopy(approved)
            case["id"] = fault
            if fault == "preview":
                case["commands"].pop(-2)
            elif fault == "different-preview":
                case["commands"][-2]["run"] = case["commands"][-2]["run"].replace("review", "other")
            elif fault == "token":
                case["commands"][-1]["run"] = case["commands"][-1]["run"].replace(
                    " --confirm-plan {confirmation_token}", "")
            elif fault == "approval":
                case["commands"][-1].pop("approval")
            else:
                case.pop("report")
            with self.subTest(safety=fault):
                with self.assertRaisesRegex(AssertionError, message):
                    self.check_eval(case)

    def check_eval(self, case):
        context = case["id"]
        self.assertTrue(case["prompt"].strip(), context)
        self.assertTrue(case["context"].strip(), context)
        self.assertTrue(case["commands"], context)
        self.assertTrue(case.get("report", "").strip(), f"{context} must have a report")
        previews = set()
        for step in case["commands"]:
            tokens = self.eval_tokens(step["run"], context)
            options = tokens[:tokens.index("--")] if "--" in tokens else tokens
            # Compare the requested operation, removing only preview/approval metadata.
            operation, confirmation = [], None
            iterator = iter(tokens)
            for token in iterator:
                if token == "--confirm-plan":
                    confirmation = next(iterator, None)
                elif token.startswith("--confirm-plan="):
                    confirmation = token.split("=", 1)[1]
                elif token not in ["--dry-run", "--yes", "--json"]:
                    operation.append(token)
            if "--yes" in options:
                self.assertEqual(confirmation, "{confirmation_token}",
                                 f"{context}: --yes must carry --confirm-plan {{confirmation_token}}")
                self.assertTrue(step.get("approval", "").strip(), f"{context}: --yes must have approval")
                self.assertIn(tuple(operation), previews, f"{context}: --yes must follow a matching --dry-run")
            if "--dry-run" in options:
                previews.add(tuple(operation))
            self.check_command(step["run"], context)

    def eval_tokens(self, command, context):
        try:
            tokens = shlex.split(command)
        except ValueError as error:
            self.fail(f"{context}: invalid shell quoting in {command!r}: {error}")
        self.assertTrue(tokens, f"{context}: empty eval command")
        self.assertEqual(tokens[0], "pensieve", f"{context}: eval must invoke pensieve")
        options = tokens[:tokens.index("--")] if "--" in tokens else tokens
        self.assertIn("--json", options, f"{context}: eval commands must request --json: {command}")
        return tokens

    def check_command(self, command, context):
        """Check CLI parsing and validation, not the app's checks or execution of writes."""
        placeholders = {
            "mini_id": "11111111-2222-4333-8444-555555555555",
            "repository_url": "https://github.com/example/skills",
            "confirmation_token": "0123456789abcdef" * 4,
            "project_path": str(self.project),
        }
        arguments = self.eval_tokens(command, context)[1:]
        for index, token in enumerate(arguments):
            for name, value in placeholders.items():
                token = token.replace("{" + name + "}", value)
            self.assertFalse("{" in token or "}" in token,
                             f"Unresolved placeholder in {context}: {token!r} ({command})")
            arguments[index] = token
        self.assertFalse(any(arg.split("=", 1)[0] == "--app-support" for arg in arguments),
                         f"{context}: evals cannot override isolated App Support")
        end = arguments.index("--") if "--" in arguments else len(arguments)
        arguments[end:end] = ["--app-support", str(self.support)]
        key = tuple(arguments)
        if key not in self.results:
            # Long temporary socket paths fail with pathTooLong before launch refusal.
            # On shorter paths, alternate App Support disables launch. There is no app
            # socket in this empty folder, so neither path can execute an eval's writes.
            self.results[key] = subprocess.run([str(self.binary), *arguments],
                env=dict(os.environ, HOME=str(self.home), CFFIXED_USER_HOME=str(self.home), PENSIEVE_NO_INPUT="1"),
                cwd=self.project, stdin=subprocess.DEVNULL, text=True, capture_output=True, timeout=15)
        result = self.results[key]
        detail = f"{context}: {command!r}: exit={result.returncode}, stderr={result.stderr!r}"
        self.assertIn(result.returncode, [0, 2, 3, 64], f"Unexpected CLI outcome for {detail}")
        try:
            envelope = json.loads(result.stdout)
        except json.JSONDecodeError:
            self.fail(f"Non-JSON CLI outcome for {detail}; stdout={result.stdout!r}")
        error = (envelope.get("error") or {}).get("code")
        message = (envelope.get("error") or {}).get("message", "")
        if (result.returncode, error) == (64, "usage"):
            self.fail(f"Built CLI rejected eval command {detail}; error=usage; {message}")
        self.assertIn((result.returncode, error), [(0, None), (2, "state_unreadable"), (3, "app_unavailable")],
                      f"Unexpected CLI outcome for {detail}; error={error}; {message}")
