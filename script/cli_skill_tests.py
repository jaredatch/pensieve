"""Check shipped eval commands against the built CLI's discovery and validation."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


class CLISkillTests(unittest.TestCase):
    binary = None

    def test_eval_commands_and_flags_exist_in_built_cli(self):
        source = Path(__file__).resolve().parent.parent / "skills/pensieve/evals.json"
        evals = json.loads(source.read_text())["evals"]
        self.assertTrue(evals, "The skill must ship nonempty evals")
        self.assertEqual(len({case["id"] for case in evals}), len(evals), "Eval IDs must be unique")
        with tempfile.TemporaryDirectory(prefix="skill-evals-") as home:
            # Discovery needs no app. Command acceptance below also isolates App Support.
            result = subprocess.run([str(self.binary), "commands", "--json"],
                env=dict(os.environ, HOME=home, CFFIXED_USER_HOME=home), cwd=home,
                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        envelope = json.loads(result.stdout)
        self.assertTrue(envelope["ok"], envelope)
        catalog = envelope["data"]["command"]
        for case in evals:
            self.assertTrue(case["prompt"].strip(), case["id"])
            self.assertTrue(case["context"].strip(), case["id"])
            self.assertTrue(case["commands"], case["id"])
            for step in case["commands"]:
                with self.subTest(eval=case["id"], command=step["run"]):
                    self.check_command(step["run"], catalog)

        # Known commands and flags can still violate the CLI's validation rules.
        for command in [
            "pensieve deploy review -m {mini_id} --json",
            "pensieve deploy review -a claude -g -p . --json",
            "pensieve install {repository_url} --rename --skip --json",
        ]:
            with self.subTest(rejected_command=command):
                with self.assertRaisesRegex(AssertionError,
                                            "Built CLI rejected eval command.*exit=64, error=usage"):
                    self.check_command(command, catalog)

    def check_command(self, command, catalog):
        """Use discovery for diagnostics, then require the binary to accept the command.

        Eval examples use separate option values and canonical command-first spelling.
        The CLI's parser and validation run, but no app is available to handle requests.
        """
        tokens = shlex.split(command)
        self.assertTrue(tokens, "Empty eval command")
        self.assertEqual(tokens.pop(0), "pensieve")
        node = catalog
        while node.get("subcommands"):
            self.assertTrue(tokens, "Eval must name a runnable command")
            name = tokens.pop(0)
            matches = [child for child in node["subcommands"]
                       if name in [child["commandName"], *child.get("aliases", [])]]
            self.assertEqual(len(matches), 1, f"Unknown eval command: {name}")
            node = matches[0]
        options = {}
        positionals = []
        for argument in node.get("arguments", []):
            if argument["kind"] == "positional":
                positionals.append(argument)
            for name in argument.get("names", []):
                prefix = "--" if name["kind"] == "long" else "-"
                options[prefix + name["name"]] = argument
        seen, values = [], []
        index = 0
        while index < len(tokens):
            token = tokens[index]
            index += 1
            if token == "--":
                values.extend(tokens[index:])
                break
            if not token.startswith("-"):
                values.append(token)
                continue
            self.assertIn(token, options, f"Unknown eval flag for {node['commandName']}: {token}")
            option = options[token]
            identity = option["valueName"]
            if not option.get("isRepeating", False):
                self.assertNotIn(identity, seen, f"Repeated eval option: {token}")
            seen.append(identity)
            if option["kind"] == "option":
                self.assertLess(index, len(tokens), f"Missing eval option value: {token}")
                self.assertFalse(tokens[index].startswith("-"), f"Missing eval option value: {token}")
                index += 1
        self.assertIn("json", seen, "Eval commands must request JSON")
        minimum = sum(not item.get("isOptional", False) for item in positionals)
        self.assertGreaterEqual(len(values), minimum, "Missing eval positional argument")
        if not any(item.get("isRepeating", False) for item in positionals):
            self.assertLessEqual(len(values), len(positionals), "Unexpected eval positional argument")

        with tempfile.TemporaryDirectory(prefix="skill-eval-") as home:
            support = Path(home) / "support"
            support.mkdir()
            project = Path(home) / "Demo project"
            project.mkdir()
            placeholders = {
                "mini_id": "11111111-2222-4333-8444-555555555555",
                "repository_url": "https://github.com/example/skills",
                "confirmation_token": "0123456789abcdef" * 4,
                "project_path": str(project),
            }
            # Substitute after tokenizing so a quoted path remains one argument. Unknown
            # placeholders fail here instead of silently testing a literal brace string.
            arguments = [token.format_map(placeholders) for token in shlex.split(command)[1:]]
            self.assertNotIn("--app-support", arguments, "Evals cannot override the isolated App Support")
            end = arguments.index("--") if "--" in arguments else len(arguments)
            arguments[end:end] = ["--app-support", str(support)]
            # An empty, unique support folder has no socket. Its explicit override disables
            # auto-launch, so even accepted install/deploy commands cannot reach an app.
            result = subprocess.run([str(self.binary), *arguments],
                env=dict(os.environ, HOME=home, CFFIXED_USER_HOME=home, PENSIEVE_NO_INPUT="1"),
                cwd=project, stdin=subprocess.DEVNULL, text=True, capture_output=True, timeout=15)
        envelope = json.loads(result.stdout)
        error = (envelope.get("error") or {}).get("code")
        self.assertEqual((result.returncode, error), (3, "app_unavailable"),
                         f"Built CLI rejected eval command {command!r}: exit={result.returncode}, "
                         f"error={error}; stdout={result.stdout!r}; stderr={result.stderr!r}")
        self.assertFalse(envelope["ok"], envelope)
