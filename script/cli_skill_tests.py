"""Check shipped eval commands against the built CLI's own discovery response."""
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
            # Only discovery runs. Expected writes are parsed as data, never executed. A fake
            # home also prevents auto-launch if a future change accidentally requests app data.
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

    def check_command(self, command, catalog):
        """Validate eval syntax from discovery, without a second command/flag inventory.

        Eval examples use separate option values and canonical command-first spelling.
        This is not a shell runner or a replacement for the CLI's semantic validation.
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
