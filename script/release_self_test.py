#!/usr/bin/env python3
"""Exercise release.sh in an isolated checkout; all external commands are stubs."""
import base64
import importlib.util
import itertools
import json
import os
import plistlib
import re
import select
import time
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
STATE_SPEC = importlib.util.spec_from_file_location("release_state", ROOT / "script/release_state.py")
STATE_TOOL = importlib.util.module_from_spec(STATE_SPEC)
STATE_SPEC.loader.exec_module(STATE_TOOL)
MINIMUM_SPEC = importlib.util.spec_from_file_location("minimum_self_test", ROOT / "script/minimum_system_self_test.py")
MINIMUM_TOOL = importlib.util.module_from_spec(MINIMUM_SPEC)
MINIMUM_SPEC.loader.exec_module(MINIMUM_TOOL)
VERSION = "1.0.0"
SHA = "a" * 40
DMG = b"fresh built DMG"
SIGNATURE = base64.b64encode(b"s" * 64).decode()
DOWNLOAD_PREFIX = "https://github.com/jaredatch/pensieve/releases/download"
# Empty-cache swiftc: verifier 1.292 s, generator 1.184 s; binaries 0.151/0.129 s.
# Allow slow CI startup while bounding compilation separately from release I/O.
SWIFT_COMPILE_TIMEOUT = 120
CRYPTO_RUN_TIMEOUT = 30
RELEASE_RUN_TIMEOUT = 60
DEFAULT_SWIFT_RELEASE_TIMEOUT = 120  # Fresh-cache /usr/bin/swift: 1.190 s; includes all cask I/O.
KEY_GENERATOR = '''import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let data = Data("fresh built DMG".utf8)
print(key.publicKey.rawRepresentation.base64EncodedString())
print(try key.signature(for: data).base64EncodedString())
'''

# Shared literal oracle; neither suite derives channels from production code.
PUBLICATION_CASES = json.loads((ROOT / "PensieveTests/Fixtures/release-versions.json").read_text())
POISON_TEXTS = ("x\n::error::fixture", "x\r\t\x1b\x7f", "x\u0085::warning::fixture", "##[error]fixture")


def assert_safe_diagnostic(test, text):
    test.assertFalse(any(line.startswith("::") for line in text.splitlines()), "untrusted text must not become an Actions workflow command")
    test.assertIsNone(re.search(r"[\x00-\x09\x0b-\x1f\x7f-\x9f]", text), "diagnostics must escape raw control characters")
    test.assertNotIn("##[", text, "legacy Actions command markers must be escaped wherever they appear")


_DEFAULT_MINIMUM = object()


def feed(version=VERSION, signature=SIGNATURE, length=len(DMG), prefix=DOWNLOAD_PREFIX, channel=None, minimum=_DEFAULT_MINIMUM):
    if minimum is _DEFAULT_MINIMUM:
        minimum = "26.0" if version == VERSION else "14.0"
    channel = PUBLICATION_CASES[version][0] if channel is None else channel
    return (f'<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            f'<channel><title>Pensieve</title><item><title>{version}</title><pubDate>Sun, 04 Oct 2026 00:00:00 +0000</pubDate>'
            f'<sparkle:version>999</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString>'
            + (f'<sparkle:channel>{channel}</sparkle:channel>' if channel else '') +
            (f'<sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>' if minimum is not None else '') +
            f'<enclosure url="{prefix}/v{version}/'
            f'Pensieve-{version}.dmg" length="{length}" sparkle:edSignature="{signature}"/>'
            '</item></channel></rss>')


def cask(version="0.9.0", sha="0" * 64):
    return f'cask "pensieve" do\n  version "{version}"\n  sha256 "{sha}"\nend\n'


def feeds(*versions, publication_version=VERSION):
    items = ''.join('<item>' + feed(v, minimum="26.0" if v == publication_version else _DEFAULT_MINIMUM).split('<item>')[1].split('</item>')[0] + '</item>' for v in versions)
    return feed().split('<channel>')[0] + '<channel><title>Pensieve</title>' + items + '</channel></rss>'


# The stub only handles the command shapes used by production. An unexpected
# call fails rather than reaching a real network, compiler, or signing service.
STUB = r'''#!/usr/bin/env python3
import base64, json, os, pathlib, sys
p = pathlib.Path(os.environ["RELEASE_TEST_STATE"])
s = json.loads(p.read_text())
cmd, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
def save(): p.write_text(json.dumps(s))
def fail(message):
    print(message + s.get("error_tail", ""), file=sys.stderr); save(); sys.exit(1)
s["calls"].append([cmd] + args)
s.setdefault("child_credentials", []).append([cmd, os.environ.get("TAP_GH_TOKEN"),
    os.environ.get("CASK_TAP_TOKEN"), os.environ.get("GH_TOKEN")])
save()
if cmd == "gh":
    if args[0] == "api":
        path = next(a for a in args if a.startswith("repos/"))
        s.setdefault("credential_calls", []).append([path, os.environ.get("GH_TOKEN", "")])
        save()
        method = args[args.index("-X") + 1] if "-X" in args else "GET"
        kind = "appcast" if "appcast.xml" in path else "cask" if "pensieve.rb" in path else "release" if "/releases/tags/" in path else "tag" if "/git/ref/" in path else "repo"
        if method == "PUT":
            fields = dict(a.split("=", 1) for i, a in enumerate(args) if i and args[i-1] == "-f")
            if s.get("race") == kind:
                s[kind] = s.get("race_content", s[kind]); s[kind + "_sha"] = "b" * 40
                print('HTTP/2.0 409 Conflict\n\n{}' + s.get('response_tail', '')); fail("lost write race")
            if fields.get("sha", "") != s[kind + "_sha"]: fail("unguarded PUT")
            s[kind] = base64.b64decode(fields["content"]).decode()
            s[kind + "_sha"] = "b" * 40
            s["writes"].append(kind)
            if kind == "appcast" and s.get("break_template_after_appcast"):
                pathlib.Path(s["break_template_after_appcast"]).write_text("def broken(")
            save()
            print('HTTP/2.0 200 OK\n\n{}'); sys.exit(0)
        if s.get("fail_read") == kind:
            print('HTTP/2.0 ' + s.get('fail_status', '503') + ' Failed\n\n{}' + s.get('response_tail', '')); fail("failed " + kind + " read")
        if s.get("malformed") == kind:
            print('HTTP/2.0 200 OK\n\n{"bad":'); sys.exit(0)
        if kind == "appcast":
            s["appcast_reads"] = s.get("appcast_reads", 0) + 1
            if s["appcast_reads"] > 1 and "recheck_content" in s:
                s[kind] = s["recheck_content"]; s[kind + "_sha"] = s.get("recheck_sha", "b" * 40)
            save()
        if kind == "release":
            s["release_reads"] = s.get("release_reads", 0) + 1
            if s["release_reads"] > 1 and "recheck_release" in s:
                s["release"] = s["recheck_release"]
            save()
        if kind == "repo": print(s.get("branch", "master")); sys.exit(0)
        if kind == "tag": value = {"object": {"type": "commit", "sha": s.get("target", "a" * 40)}}
        elif kind == "release": value = s["release"]
        else:
            value = None if s[kind] is None else {"sha": s[kind + "_sha"], "encoding": "base64", "content": base64.b64encode(s[kind].encode()).decode()}
            if s.get("null_content") == kind: value["content"] = None
        if value is None:
            print('HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}'); sys.exit(1)
        print('HTTP/2.0 200 OK\n\n' + json.dumps(value)); sys.exit(0)
    if args[:2] == ["release", "create"]:
        if s["release"] is not None: fail("second release creation")
        s["release"] = s["expected_release"]; s["asset"] = pathlib.Path(next(a for a in args if a.endswith(".dmg"))).read_text()
        s["writes"].append("create"); save(); sys.exit(0)
    if args[:2] == ["release", "upload"]:
        if "--clobber" not in args: fail("no replacement requested")
        interruption = s.pop("interrupt_upload", None)
        if interruption:
            s["release"]["assets"] = [] if interruption == "missing" else [dict(s["expected_release"]["assets"][0], state=interruption, size=0)]
            fail("upload interrupted after deleting the old DMG")
        s["release"] = s["expected_release"]
        s["asset"] = pathlib.Path(next(a for a in args if a.endswith(".dmg"))).read_text()
        s["writes"].append("replace"); save(); sys.exit(0)
    if args[:2] == ["release", "download"]:
        dest = pathlib.Path(args[args.index("--dir") + 1]); dest.mkdir(parents=True, exist_ok=True)
        (dest / args[args.index("--pattern") + 1]).write_text(s["asset"])
        sys.exit(0)
elif cmd == "git": print("a" * 40 if args[-2:] == ["rev-parse", "HEAD"] else "1"); sys.exit(0)
elif cmd == "xcodegen": sys.exit(0)
elif cmd == "xcodebuild":
    dest = pathlib.Path(args[args.index("-derivedDataPath") + 1]) / "Build/Products/Release/Pensieve.app"
    if dest.exists(): s["stale_survived"] = True
    for name in ["MacOS/Pensieve", "MacOS/pensieve-daemon", "Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/file", "Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/file", "Frameworks/Sparkle.framework/Versions/B/Autoupdate", "Frameworks/Sparkle.framework/Versions/B/Updater.app/file"]:
        f = dest / "Contents" / name; f.parent.mkdir(parents=True, exist_ok=True); f.write_text("built")
    minimum = s.get("built_minimum", "26.0")
    (dest / "Contents/Info.plist").write_text('<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Pensieve</string><key>CFBundleShortVersionString</key><string>' + s["version"] + '</string>' + ('<key>LSMinimumSystemVersion</key><string>' + minimum + '</string>' if minimum is not None else '') + '</dict></plist>')
    s["builds"] += 1; save(); sys.exit(0)
elif cmd == "codesign": sys.exit(0)  # models a valid Developer ID signature
elif cmd in ["notary", "stapler", "spctl"]: sys.exit(0)
elif cmd == "ditto":
    import shutil
    if "-c" in args: pathlib.Path(args[-1]).write_text("zip")
    elif pathlib.Path(args[-2]).is_dir(): shutil.copytree(args[-2], args[-1], dirs_exist_ok=True)
    else: shutil.copyfile(args[-2], args[-1])
    sys.exit(0)
elif cmd == "hdiutil":
    if args[0] == "create":
        import shutil
        source = pathlib.Path(args[args.index("-srcfolder") + 1])
        s["packaged_stale"] = (source / "Pensieve.app/Contents/stale-proof").exists()
        payload = p.parent / "dmg-payload"
        if payload.exists(): shutil.rmtree(payload)
        shutil.copytree(source / "Pensieve.app", payload)
        pathlib.Path(args[-1]).write_text("fresh built DMG"); save()
    elif args[0] == "attach":
        import plistlib, shutil
        mounted = pathlib.Path(args[args.index("-mountpoint") + 1]) / "Pensieve.app"
        source = p.parent / "dmg-payload"
        if not source.exists(): source = p.parent / "build/dist/dmg-root/Pensieve.app"
        shutil.copytree(source, mounted)
        info_path = mounted / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        if "dmg_minimum" in s:
            if s["dmg_minimum"] is None: info.pop("LSMinimumSystemVersion", None)
            else: info["LSMinimumSystemVersion"] = s["dmg_minimum"]
        info_path.write_bytes(plistlib.dumps(info))
    elif args[0] == "detach":
        import shutil; shutil.rmtree(pathlib.Path(args[1]) / "Pensieve.app")
    else: fail("unexpected hdiutil")
    sys.exit(0)
elif cmd in ["lipo", "otool"]:
    import plistlib
    binary = pathlib.Path(args[-1])
    if cmd == "lipo": print("arm64 x86_64"); sys.exit(0)
    info = plistlib.loads((binary.parent.parent / "Info.plist").read_bytes())
    minimum = info.get("LSMinimumSystemVersion", "26.0")
    kind = "daemon" if binary.name == "pensieve-daemon" else "app"
    for arch in ["arm64", "x86_64"]:
        value = s.get(kind + "_minimum_by_arch", {}).get(arch, s.get(kind + "_minimum", minimum))
        print(str(binary) + " (architecture " + arch + "):")
        print("Load command 0\n      cmd LC_BUILD_VERSION\n  cmdsize 32\n platform 1\n    minos " + value + "\n      sdk 26.0")
    sys.exit(0)
elif cmd == "generate":
    dest = pathlib.Path(args[-1])
    archives = sorted(f.name for f in dest.glob("*.dmg"))
    if archives != ["Pensieve-" + s["version"] + ".dmg"]: fail("signing folder contains other archives")
    if (dest / archives[0]).read_text() != "fresh built DMG": fail("signing folder contains downloaded bytes")
    s["signing_inputs"].append(archives); save()
    (dest / "appcast.xml").write_text(s["new_feed"]); sys.exit(0)
elif cmd == "verify":
    if pathlib.Path(args[0]).read_text() != "fresh built DMG" or args[1:3] != ["15", s["signature"]]: fail("EdDSA or length mismatch")
    sys.exit(0)
fail("unexpected stub call " + cmd + " " + repr(args))
'''


class MinimumParserTests(unittest.TestCase):
    def check_output(self, output):
        def command(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, "arm64 x86_64\n" if "lipo" in args[0] else output, "")
        with mock.patch.object(MINIMUM_TOOL.subprocess, "run", side_effect=command):
            MINIMUM_TOOL.MinimumSystemTests().assert_binary_minimum(Path("/fixture/pensieve-daemon"))

    @staticmethod
    def slice(arch, command="LC_BUILD_VERSION", platform="1", minimum="26.0"):
        entry = "    minos " + minimum + "\n" if minimum is not None else ""
        return f"/fixture/pensieve-daemon (architecture {arch}):\nLoad command 0\n      cmd {command}\n platform {platform}\n" + entry

    def test_each_architecture_requires_a_minimum(self):
        output = self.slice("arm64") + "/fixture/pensieve-daemon (architecture x86_64):\nLoad command 0\n cmd LC_UUID\n"
        with self.assertRaisesRegex(AssertionError, "missing or duplicated minimum load command"):
            self.check_output(output)

    def test_build_version_requires_the_macos_platform(self):
        for platform in ("6", "2", "MACCATALYST", ""):
            with self.subTest(platform=platform), self.assertRaisesRegex(AssertionError, "platform must be macOS"):
                self.check_output(self.slice("arm64") + self.slice("x86_64", platform=platform))

    def test_malformed_minimum_is_a_named_failure(self):
        with self.assertRaisesRegex(AssertionError, "missing or malformed minos"):
            self.check_output(self.slice("arm64") + self.slice("x86_64", minimum=None))


class ReleaseSequenceTests(unittest.TestCase):
    tool = STATE_TOOL

    @classmethod
    def setUpClass(cls):
        cls.crypto_tools = None

    @classmethod
    def fixture_crypto_tools(cls):
        if cls.crypto_tools is None:
            scratch = tempfile.TemporaryDirectory(prefix="pensieve-crypto-tools-", dir="/tmp")
            cls.addClassCleanup(scratch.cleanup)
            tools = Path(scratch.name)
            generator = tools / "key-generator.swift"
            generator.write_text(KEY_GENERATOR)
            binaries = (tools / "key-generator", tools / "verify-update")
            for source, binary in zip((generator, ROOT / "script/verify_update.swift"), binaries):
                started = time.monotonic()
                result = subprocess.run(["/usr/bin/swiftc", "-module-cache-path", str(tools / "module-cache"),
                                         str(source), "-o", str(binary)], capture_output=True, text=True,
                                        timeout=SWIFT_COMPILE_TIMEOUT)
                if result.returncode != 0:
                    raise AssertionError("fixture compilation failed: " + result.stderr)
                print(f"release fixture: compiled {binary.name} in {time.monotonic() - started:.3f}s", flush=True)
            cls.crypto_tools = binaries
        return cls.crypto_tools

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pensieve-release test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "script").mkdir()
        for name in ("release.sh", "release_recovery.sh", "package.sh", "build-number.sh", "release_state.py", "verify_update.swift", "minimum_system.py", "minimum_system_self_test.py"):
            if (ROOT / "script" / name).exists(): shutil.copy2(ROOT / "script" / name, self.root / "script" / name)
        shutil.copytree(ROOT / "release/homebrew", self.root / "release/homebrew")
        shutil.copytree(ROOT / "Pensieve", self.root / "Pensieve", ignore=shutil.ignore_patterns("*.swift", "Resources"))
        (self.root / "VERSION").write_text(VERSION)
        (self.root / "BUILD_NUMBER_OFFSET").write_text("00")
        (self.root / "project.yml").write_text('MARKETING_VERSION: "1.0.0"\n')
        (self.root / "CHANGELOG.md").write_text("## [1.0.0]\nRelease fixture.\n")
        (self.root / "fixture-key").write_text("not a signing key")
        bin_dir = self.root / "bin"; bin_dir.mkdir()
        for name in ("gh", "git", "xcodegen", "xcodebuild", "codesign", "ditto", "hdiutil", "spctl", "notary", "stapler", "generate", "verify", "lipo", "otool"):
            f = bin_dir / name; f.write_text(STUB); f.chmod(0o755)
        self.state_path = self.root / "state.json"
        release = {"id": 1, "tag_name": "v" + VERSION, "draft": False, "prerelease": PUBLICATION_CASES[VERSION][1],
                   "assets": [{"id": 2, "name": "Pensieve-1.0.0.dmg", "size": len(DMG), "state": "uploaded"}]}
        self.state = dict(version=VERSION, release=None, expected_release=release, asset=DMG.decode(),
                          appcast=feed("0.9.0"), cask=cask(), appcast_sha=SHA, cask_sha=SHA,
                          calls=[], writes=[], builds=0, signing_inputs=[], new_feed=feed(), signature=SIGNATURE)
        self.env = dict(os.environ, PATH=str(bin_dir) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        RELEASE_TEST_STATE=str(self.state_path), GH_CMD="gh",
                        NOTARY_CMD="notary", STAPLER_CMD="stapler",
                        GENERATE_APPCAST_CMD=str(bin_dir / "generate"), VERIFY_UPDATE_CMD="verify",
                        GH_TOKEN="fixture-public-token", TAP_GH_TOKEN="fixture-tap-token",
                        SPARKLE_PRIVATE_KEY_FILE=str(self.root / "fixture-key"))

    def run_release(self, cask_only=False, expected=0, first=False):
        self.state_path.write_text(json.dumps(self.state))
        args = ["/bin/bash", str(self.root / "script/release.sh")]
        args += ["--publish-cask-only"] if cask_only else ["--publish", "--sign", "Developer ID Application: Fixture", "--notary-key", "fixture", "--notary-key-id", "fixture", "--notary-issuer", "fixture"]
        if first: args += ["--first-release"]
        # PlistBuddy is an absolute system command in package.sh; its input is a real fixture plist.
        product = self.root / "build/package-dd/Build/Products/Release/Pensieve.app/Contents/Info.plist"
        product.parent.mkdir(parents=True, exist_ok=True)
        product.write_text('<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>' + self.state["version"] + '</string></dict></plist>')
        # ditto's stub adds the plist that a real build produces after the product was cleaned.
        result = subprocess.run(args, env=self.env, text=True, capture_output=True, timeout=RELEASE_RUN_TIMEOUT)
        self.state = json.loads(self.state_path.read_text())
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def run_function(self, body, before_source="trap cleanup_appcast_base EXIT"):
        self.state_path.write_text(json.dumps(self.state))
        result = subprocess.run(["/bin/bash", "-c", before_source + '\nsource "$1" --inspect-functions\n' + body,
                                 "release-test", str(self.root / "script/release.sh")],
                                env=self.env, text=True, capture_output=True, timeout=30)
        self.state = json.loads(self.state_path.read_text())
        return result

    def set_version(self, version):
        self.state["version"] = version
        self.state["expected_release"] = dict(self.state["expected_release"], tag_name="v" + version,
                                             prerelease=PUBLICATION_CASES[version][1],
                                             assets=[dict(self.state["expected_release"]["assets"][0], name="Pensieve-" + version + ".dmg")])
        self.state["new_feed"] = feed(version, minimum="26.0")
        (self.root / "VERSION").write_text(version)
        (self.root / "project.yml").write_text('MARKETING_VERSION: "' + version + '"\n')
        (self.root / "CHANGELOG.md").write_text("## [" + version + "]\nRelease fixture.\n")

    def test_fresh_release_and_second_run(self):
        self.run_release(); self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], ["create", "appcast", "cask"])
        self.assertEqual(self.state["builds"], 1)
        self.assertEqual(self.state["signing_inputs"], [["Pensieve-1.0.0.dmg"]])
        self.run_release(); self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], ["create", "appcast", "cask"])
        self.assertEqual(self.state["builds"], 1)

    def test_invalid_version_stops_in_every_mode_before_work(self):
        invalid = "1.0.0+build-1"
        (self.root / "VERSION").write_text(invalid)
        self.state_path.write_text(json.dumps(self.state))
        modes = ([], ["--dry-run"], ["--dry-run-local"], ["--publish"], ["--publish", "--first-release"],
                 ["--publish-cask-only"],
                 ["--notes-for", invalid], ["--print-release-args", invalid], ["--print-cask-action", invalid])
        for arguments in modes:
            with self.subTest(arguments=arguments):
                result = subprocess.run(["/bin/bash", str(self.root / "script/release.sh"), *arguments],
                                        env=self.env, text=True, capture_output=True, timeout=30)
                self.assertNotEqual(result.returncode, 0, "invalid VERSION must fail before work in this mode")
                first_error = result.stderr.splitlines()[0] if result.stderr else ""
                self.assertIn("invalid publication version", first_error, "VERSION validation must be the first error")
                self.assertIn(invalid, first_error)
                state = json.loads(self.state_path.read_text())
                self.assertEqual(state["calls"], [], "invalid VERSION must not reach external commands")
                self.assertEqual(state["builds"], 0); self.assertEqual(state["writes"], [])

        # Inspect arguments select their own version even when it is empty.
        (self.root / "VERSION").write_text(VERSION)
        for option in ("--notes-for", "--print-release-args", "--print-cask-action"):
            with self.subTest(empty_inspect_argument=option):
                result = subprocess.run(["/bin/bash", str(self.root / "script/release.sh"), option, ""],
                                        env=self.env, text=True, capture_output=True, timeout=30)
                self.assertNotEqual(result.returncode, 0, "an empty inspect version must not fall back to VERSION")
                self.assertIn(option + " version argument must not be empty", result.stderr.splitlines()[0] if result.stderr else "")
                self.assertEqual(json.loads(self.state_path.read_text())["calls"], [])

    def test_first_release_names_invalid_version_before_release_flags(self):
        invalid = "1.0.0+build-1"
        (self.root / "VERSION").write_text(invalid)
        self.state.update(appcast=None, appcast_sha="", release=dict(self.state["expected_release"], prerelease=False))
        output = self.run_release(expected=1, first=True)
        errors = [line for line in output.splitlines() if "release:" in line]
        self.assertTrue(errors)
        self.assertIn("invalid publication version", errors[0], "the first error must name VERSION before judging release flags")
        self.assertIn(invalid, errors[0])
        self.assertEqual(self.state["calls"], []); self.assertEqual(self.state["builds"], 0); self.assertEqual(self.state["writes"], [])

    def test_release_exists_rebuilds_and_replaces_before_signing_feed(self):
        original = json.loads(json.dumps(self.state))
        for interruption in (None, "missing", "starter", "open"):
            with self.subTest(interruption=interruption):
                self.state = json.loads(json.dumps(original))
                self.state["release"] = self.state["expected_release"]
                self.state["asset"] = "old unpublished bytes"
                if interruption:
                    self.state["interrupt_upload"] = interruption
                    self.assertIn("upload interrupted", self.run_release(expected=1))
                    self.assertEqual(self.state["writes"], [])
                self.run_release(); self.run_release(cask_only=True)
                self.assertEqual(self.state["writes"], ["replace", "appcast", "cask"])
                self.assertEqual(self.state["asset"], DMG.decode())
                self.assertEqual(self.state["builds"], 2 if interruption else 1)
                self.assertEqual(self.state["signing_inputs"], [["Pensieve-1.0.0.dmg"]] * (2 if interruption else 1))
                self.assertFalse(any(c[:3] == ["gh", "release", "download"] for c in self.state["calls"]))

    def test_live_appcast_verifies_without_rebuild_or_asset_write(self):
        self.state.update(release=self.state["expected_release"], appcast=feed())
        self.run_release(); self.run_release(cask_only=True)
        self.assertEqual(self.state["builds"], 0)
        self.assertEqual(self.state["writes"], ["cask"])
        self.assertEqual(self.state["signing_inputs"], [])
        self.assertTrue(any(c[0] == "verify" for c in self.state["calls"]))

    def test_bad_release_shapes_stop_before_any_changes(self):
        for change in ({"draft": True}, {"assets": None}, {"assets": [None]}, {"assets": self.state["expected_release"]["assets"] * 2}, {"tag_name": "v9.0.0"}, {"prerelease": True}, {"assets": [{"name": "extra"}]}, {"assets": [dict(self.state["expected_release"]["assets"][0], id=0)]}, {"assets": [dict(self.state["expected_release"]["assets"][0], size=0)]}):
            with self.subTest(change=change):
                self.state["release"] = dict(self.state["expected_release"], **change)
                output = self.run_release(expected=1)
                self.assertIn("release", output)
                self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)
        for assets in ([], *([dict(self.state["expected_release"]["assets"][0], state=state, size=0)] for state in ("starter", "open", "processing"))):
            with self.subTest(live_assets=assets):
                self.state.update(appcast=feed(), release=dict(self.state["expected_release"], assets=assets))
                self.assertIn("DMG", self.run_release(expected=1))
                self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)
        self.state["release"] = self.state["expected_release"]; self.state["target"] = "b" * 40
        self.assertIn("target", self.run_release(expected=1))

    def test_inconsistent_appcast_and_cask_stop_without_publication(self):
        self.state["appcast"] = feed()
        self.assertIn("missing", self.run_release(expected=1))
        self.state["release"] = self.state["expected_release"]
        self.state["appcast"] = feed().replace("v1.0.0/", "v9.0.0/")
        self.assertIn("URL", self.run_release(expected=1))
        self.state.update(appcast=feed(), cask=cask(VERSION))
        self.assertIn("verified published DMG", self.run_release())
        self.assertIn("sha256", self.run_release(cask_only=True, expected=1))
        self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)

    def test_valid_developer_id_does_not_replace_eddsa_verification(self):
        self.state.update(release=self.state["expected_release"], appcast=feed(), asset="other bytes")
        self.assertIn("EdDSA", self.run_release(expected=1))
        self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)

    def install_fixture_public_key(self):
        generator, verifier = self.fixture_crypto_tools()
        keys = subprocess.run([str(generator)], capture_output=True, text=True, timeout=CRYPTO_RUN_TIMEOUT)
        self.assertEqual(keys.returncode, 0, keys.stderr)
        public, signature = keys.stdout.splitlines()
        plist = self.root / "Pensieve/Info.plist"
        properties = plistlib.loads(plist.read_bytes())
        properties["SUPublicEDKey"] = public
        plist.write_bytes(plistlib.dumps(properties))
        self.env["VERIFY_UPDATE_CMD"] = str(verifier)  # Real verifier, compiled once for this suite.
        return signature

    def test_real_public_key_verification_accepts_only_matching_bytes(self):
        signature = self.install_fixture_public_key()
        self.state.update(release=self.state["expected_release"], appcast=feed(signature=signature))
        self.run_release()
        self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)
        for bad in ("wrong built DMG", "short"):
            self.state["asset"] = bad
            self.assertIn("does not match appcast", self.run_release(expected=1))
            self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)

    def cask_artifact(self, data=DMG):
        artifact = self.root / "build/dist" / ("Pensieve-" + self.state["version"] + ".dmg")
        artifact.parent.mkdir(parents=True, exist_ok=True)
        artifact.write_bytes(data)
        return artifact

    def assert_cask_refused_without_writes(self, message):
        self.assertIn(message, self.run_release(cask_only=True, expected=1))
        self.assertEqual(self.state["writes"], [], "unverified artifacts must not reach the tap")
        self.assertEqual(self.state["builds"], 0)
        self.assertEqual(self.state["signing_inputs"], [])
        self.assertFalse(any("pensieve.rb" in arg for call in self.state["calls"] for arg in call),
                         "verification must precede even the tap read")

    def test_cask_artifact_requires_live_appcast_item(self):
        self.cask_artifact()
        original = json.loads(json.dumps(self.state))
        for appcast, message in ((feed("0.9.0"), "cask requires a live appcast item for " + VERSION),
                                 (None, "cask appcast read failed (HTTP '404')")):
            with self.subTest(appcast=appcast):
                self.state = dict(json.loads(json.dumps(original)), appcast=appcast,
                                  appcast_sha=SHA if appcast else "")
                self.assert_cask_refused_without_writes(message)

    def test_cask_artifact_rejects_length_and_signature_mismatches(self):
        self.cask_artifact()
        original = json.loads(json.dumps(self.state))
        for appcast in (feed(length=len(DMG) + 1), feed(signature=base64.b64encode(b"x" * 64).decode())):
            with self.subTest(appcast=appcast):
                self.state = dict(json.loads(json.dumps(original)), appcast=appcast)
                self.assert_cask_refused_without_writes("length or EdDSA signature")

    def test_cask_artifact_uses_real_public_key_before_tap_write(self):
        signature = self.install_fixture_public_key()
        self.state["appcast"] = feed(signature=signature)
        original = json.loads(json.dumps(self.state))
        for bad in (b"wrong built DMG", b"short"):
            with self.subTest(data=bad):
                self.state = json.loads(json.dumps(original))
                self.cask_artifact(bad)
                self.assert_cask_refused_without_writes("does not match appcast")
        self.state = json.loads(json.dumps(original))
        self.cask_artifact()
        self.assertIn("cask done", self.run_release(cask_only=True))
        self.assertEqual(self.state["writes"], ["cask"])
        self.assertEqual(self.state["builds"], 0)
        self.assertEqual(self.state["signing_inputs"], [])
        self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], ["cask"], "a cask-only retry must be a no-op")

    def test_cask_artifact_refuses_failed_and_malformed_appcast_reads(self):
        self.cask_artifact()
        original = json.loads(json.dumps(self.state))
        original["appcast"] = feed()
        cases = (({"fail_read": "appcast"}, "cask appcast read failed (HTTP '503')"),
                 ({"malformed": "appcast"}, "invalid cask appcast contents response"),
                 ({"null_content": "appcast"}, "contents response has no text content"),
                 ({"appcast": "<invalid"}, "invalid 'appcast' state: 'unclosed token: line 1, column 0'"),
                 ({"appcast": feed().replace('length="15"', 'length="0"')}, "appcast has invalid DMG length"))
        for problem, message in cases:
            with self.subTest(problem=problem):
                self.state = dict(json.loads(json.dumps(original)), **problem)
                self.assert_cask_refused_without_writes(message)

    def test_cask_feed_cleanup_failure_stops_before_tap(self):
        self.cask_artifact()
        self.state["appcast"] = feed()
        failure = self.root / "bin/rm"
        failure.write_text('#!/bin/bash\ncase "$*" in\n *appcast-response.*) echo "fixture appcast cleanup failed" >&2; exit 1 ;;\nesac\nexec /bin/rm "$@"\n')
        failure.chmod(0o755)
        self.assert_cask_refused_without_writes("fixture appcast cleanup failed")

    def test_cask_verification_leaves_signing_folder_untouched(self):
        self.cask_artifact()
        self.state["appcast"] = feed()
        signing = self.root / "build/dist/appcast-input"
        signing.mkdir()
        (signing / "sentinel.dmg").write_bytes(b"owned signing bytes")
        (signing / "appcast.xml").write_text("owned signing feed")
        before = {file.name: file.read_bytes() for file in signing.iterdir()}
        self.run_release(cask_only=True)
        self.assertEqual({file.name: file.read_bytes() for file in signing.iterdir()}, before,
                         "cask verification must leave signing inputs byte-identical")
        self.assertEqual(self.state["writes"], ["cask"])

    def test_cask_public_reads_and_tap_access_use_their_own_credentials(self):
        self.cask_artifact()
        self.state["appcast"] = feed()
        self.env.update(GH_TOKEN="fixture-public-token", TAP_GH_TOKEN="fixture-tap-token")
        self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], ["cask"])
        expected = [["repos/jaredatch/pensieve", "fixture-public-token"],
                    ["repos/jaredatch/pensieve/contents/appcast.xml", "fixture-public-token"],
                    ["repos/jaredatch/homebrew-tap/contents/Casks/pensieve.rb", "fixture-tap-token"],
                    ["repos/jaredatch/homebrew-tap/contents/Casks/pensieve.rb", "fixture-tap-token"]]
        self.assertEqual(self.state["credential_calls"], expected)

    def test_tap_credential_is_absent_from_children_except_tap_gh(self):
        self.cask_artifact()
        self.state["appcast"] = feed()
        # An inherited export attribute must not turn the captured shell variable into an export.
        self.env["CASK_TAP_TOKEN"] = "inherited-export-fixture"
        # Probe the environment inherited by state_tool's Python, in addition to gh/verifier stubs.
        python = self.root / "bin/python3"
        python.write_text('#!/usr/bin/python3\nimport os,json,sys\n'
                          'p=os.environ["RELEASE_TEST_STATE"]\ns=json.load(open(p))\n'
                          'child = "gh-python" if sys.argv[1].endswith("/gh") else "state-python" if sys.argv[1].endswith("release_state.py") else "verifier-python"\n'
                          's.setdefault("child_credentials", []).append([child, os.environ.get("TAP_GH_TOKEN"), os.environ.get("CASK_TAP_TOKEN"), os.environ.get("GH_TOKEN")])\n'
                          'open(p,"w").write(json.dumps(s))\nos.execv("/usr/bin/python3", ["python3"]+sys.argv[1:])\n')
        python.chmod(0o755)
        # DEBUG with functrace observes export flags at the absolute PlistBuddy
        # invocation and the first dirname child; it records only fixture tokens.
        trace = self.root / "child-export-flags"
        startup = self.root / "export-probe.sh"
        startup.write_text('set -T\ntrap \'case "$BASH_COMMAND" in /usr/libexec/PlistBuddy*|dirname*) printf "command=%s\\n" "$BASH_COMMAND" >> "$RELEASE_EXPORT_TRACE"; declare -p TAP_GH_TOKEN CASK_TAP_TOKEN >> "$RELEASE_EXPORT_TRACE" 2>/dev/null || true ;; esac\' DEBUG\n')
        self.env.update(BASH_ENV=str(startup), RELEASE_EXPORT_TRACE=str(trace))
        self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], ["cask"])
        exports = trace.read_text()
        self.assertIn('/usr/libexec/PlistBuddy', exports)
        self.assertIn('command=dirname', exports)
        self.assertNotRegex(exports, r'declare -x (?:TAP_GH_TOKEN|CASK_TAP_TOKEN)',
                            "absolute system children must not inherit the tap token")
        for child, exported, captured, credential in self.state["child_credentials"]:
            with self.subTest(child=child):
                self.assertIsNone(exported, "no child may inherit TAP_GH_TOKEN")
                self.assertIsNone(captured, "the captured tap token must stay unexported")
                if child not in ("gh", "gh-python"):
                    self.assertEqual(credential, "fixture-public-token", "only tap gh may receive the tap credential")
        self.assertTrue(any(row[0] == "state-python" for row in self.state["child_credentials"]))
        self.assertTrue(any(row[0] == "verify" for row in self.state["child_credentials"]))
        self.assertEqual([token for _, token in self.state["credential_calls"]],
                         ["fixture-public-token"] * 2 + ["fixture-tap-token"] * 2)

    def test_signer_tag_check_precedes_secret_files_and_keychain(self):
        runner = self.root / "runner temp"; runner.mkdir()
        security = self.root / "bin/security"
        security.write_text('#!/bin/bash\nprintf "security called\\n" >> "$RUNNER_TEMP/security-calls"\nexit 1\n')
        security.chmod(0o755)
        step = subprocess.run(["/usr/bin/ruby", "-ryaml", "-e",
                               'puts YAML.load_file(ARGV[0]).fetch("jobs").fetch("release").fetch("steps").find { |s| s["name"] == "Sign, notarize, and publish" }.fetch("run")',
                               str(ROOT / ".github/workflows/release.yml")], capture_output=True, text=True, timeout=30)
        self.assertEqual(step.returncode, 0, step.stderr)
        self.state_path.write_text(json.dumps(self.state))
        env = dict(self.env, RUNNER_TEMP=str(runner), GITHUB_REF_NAME="v9.9.9",
                   DEVELOPER_ID_P12=base64.b64encode(b"fixture-p12").decode(),
                   DEVELOPER_ID_P12_PASSWORD="fixture-password", NOTARY_API_KEY_P8="fixture-p8",
                   NOTARY_ISSUER_ID="fixture-issuer", NOTARY_KEY_ID="fixture-id", SPARKLE_PRIVATE_KEY="fixture-key")
        result = subprocess.run(["/bin/bash", "-c", step.stdout], cwd=self.root, env=env,
                                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tag 'v9.9.9' does not match VERSION v" + VERSION, result.stderr)
        self.assertEqual(list(runner.iterdir()), [], "tag mismatch must precede secret files and keychain commands")
        self.assertEqual(json.loads(self.state_path.read_text())["calls"], [])

    def test_check_tag_mode_has_no_release_work_for_matching_or_mismatched_tags(self):
        self.state_path.write_text(json.dumps(self.state))
        for tag, expected in (("v" + VERSION, 0), ("v9.9.9", 1)):
            with self.subTest(tag=tag):
                result = subprocess.run(["/bin/bash", str(self.root / "script/release.sh"), "--check-tag", tag],
                                        env=self.env, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                if expected:
                    self.assertIn("does not match VERSION", result.stderr)
                self.assertEqual(json.loads(self.state_path.read_text())["calls"], [])
                self.assertFalse((self.root / "build").exists(), "check-only must not prepare a release")

    def test_check_tag_rejects_combined_modes_before_work(self):
        self.state_path.write_text(json.dumps(self.state))
        modes = (("--inspect-functions",), ("--verify-appcast", "missing", "", "Pensieve-1.0.0.dmg", DOWNLOAD_PREFIX, VERSION, "26.0"),
                 ("--publish",), ("--publish-cask-only",), ("--dry-run",), ("--first-release",))
        for mode, tag, check_first in itertools.product(modes, ("v" + VERSION, "v9.9.9"), (False, True)):
            with self.subTest(mode=mode, tag=tag, check_first=check_first):
                check = ("--check-tag", tag)
                args = (*check, *mode) if check_first else (*mode, *check)
                result = subprocess.run(["/bin/bash", str(self.root / "script/release.sh"), *args], env=self.env,
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 64, "combined check-only mode must refuse before tag validation")
                self.assertIn("usage:", result.stderr)
                self.assertEqual(json.loads(self.state_path.read_text())["calls"], [])
                self.assertFalse((self.root / "build").exists())

    def test_feed_consumers_fail_closed_when_called_from_if(self):
        original = json.loads(json.dumps(self.state))
        for consumer in ("release_preflight", "verify_appcast_unchanged", "verify_cask_artifact"):
            for failure in ("read", "parse", "temporary-file"):
                with self.subTest(consumer=consumer, failure=failure):
                    self.state = json.loads(json.dumps(original))
                    self.state["fail_read" if failure == "read" else "malformed"] = "appcast"
                    prefix = 'mkdir -p "$DIST_DIR"; VERSION="1.0.0"; VERSION_CHANNEL=""; FIRST_RELEASE=1; PUBLIC_BRANCH=master; '
                    if failure == "temporary-file":
                        prefix += 'mktemp() { echo "fixture temporary-file refusal" >&2; return 1; }; '
                    result = self.run_function(prefix + 'if ' + consumer + '; then echo "fixture admitted failed read"; exit 9; fi; '
                                               '[ "$APPCAST_PREFLIGHT" -eq 0 ]')
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertNotIn("fixture admitted failed read", result.stdout)
                    self.assertEqual(self.state["writes"], [])

    def test_missing_tap_token_fails_before_live_reads_or_verification(self):
        self.env.pop("TAP_GH_TOKEN")
        self.cask_artifact(); self.state["appcast"] = feed()
        self.assertIn("TAP_GH_TOKEN is required for cask publication", self.run_release(cask_only=True, expected=1))
        self.assertEqual(self.state["calls"], [], "missing token must stop before public reads and verification")
        self.assertEqual(self.state["writes"], [])

    def test_prerelease_cask_exits_before_token_validation_and_publication(self):
        self.set_version("1.0.0-beta.1")
        self.env.pop("TAP_GH_TOKEN")
        script = self.root / "script/release.sh"
        original = script.read_text()
        script.write_text(original.replace('if [ "${CASK_ONLY:-0}" -eq 1 ]; then',
            'verify_cask_artifact() { echo "fixture reached verifier" >&2; return 1; }\nbump_cask() { echo "fixture reached bump_cask" >&2; return 1; }\nif [ "${CASK_ONLY:-0}" -eq 1 ]; then'))
        self.state_path.write_text(json.dumps(self.state))
        result = subprocess.run(["/bin/bash", str(script), "--publish-cask-only"], env=self.env,
                                capture_output=True, text=True, timeout=30)
        self.state = json.loads(self.state_path.read_text())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("cask skipped for prerelease 1.0.0-beta.1", result.stdout)
        self.assertNotIn("fixture reached", result.stderr)
        self.assertEqual(self.state["calls"], [])

    def test_all_feed_consumers_use_the_same_read_helper(self):
        self.cask_artifact(); self.state["appcast"] = feed()
        for consumer in ("release_preflight", "verify_appcast_unchanged", "verify_cask_artifact"):
            with self.subTest(consumer=consumer):
                self.state["calls"] = []
                result = self.run_function('VERSION="1.0.0"; VERSION_CHANNEL=""; PUBLIC_BRANCH=master; DMG_PATH="$DIST_DIR/Pensieve-$VERSION.dmg"; read_live_appcast() { echo "fixture shared feed refusal" >&2; return 1; }; ' + consumer)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("fixture shared feed refusal", result.stderr)
                self.assertFalse(any("appcast.xml" in arg for call in self.state["calls"] for arg in call),
                                 "consumers must not bypass the common fetch policy")

    def test_preflight_preserves_callers_exit_trap_and_defers_signing_copy(self):
        (self.root / "build/dist").mkdir(parents=True)
        result = self.run_function('trap \'echo "fixture caller exit trap"\' EXIT; release_preflight; '
                                   '[ ! -e "$APPCAST_INPUT_DIR/appcast.xml" ] || exit 9')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("fixture caller exit trap", result.stdout)

    def test_contents_response_is_cleaned_when_logging_fails(self):
        directory = self.root / "response temporary files"; directory.mkdir()
        self.env["TMPDIR"] = str(directory)
        (self.root / "contents.rb").write_text(cask())
        result = self.run_function('log_response() { echo "fixture log refusal" >&2; return 7; }; '
                                   'publish_contents_file "$TAP_REPO" Casks/pensieve.rb "$REPO/contents.rb" fixture "" "' + SHA + '"')
        self.assertEqual(result.returncode, 0, "a landed PUT must remain successful when logging fails")
        self.assertIn("fixture log refusal", result.stderr)
        self.assertEqual(list(directory.glob("pensieve-contents-response.*")), [], "response must not leak on a logging refusal")

    def test_contents_put_result_survives_logging_failure(self):
        (self.root / "contents.rb").write_text(cask())
        for status in (200, 409, 503):
            with self.subTest(status=status):
                result = self.run_function('contents_api() { printf "HTTP/1.1 ' + str(status) + ' Fixture\r\n\r\n{}"; return ' + ('0' if status == 200 else '1') + '; }; '
                    'log_response() { echo "fixture log refusal" >&2; return 7; }; '
                    'publish_contents_file "$TAP_REPO" Casks/pensieve.rb "$REPO/contents.rb" fixture "" "' + SHA + '"')
                self.assertEqual(result.returncode, 0 if status == 200 else 1, "only the PUT decides publication success")
                if status == 409:
                    self.assertIn("contents changed since preflight (HTTP 409)", result.stderr)
                elif status == 503:
                    self.assertIn("contents write failed", result.stderr)

    def test_failed_feed_reads_always_print_the_callers_context(self):
        self.state["fail_read"] = "appcast"
        for context in ("appcast base read failed", "appcast recheck failed", "cask appcast read failed"):
            for helper in ("http_status", "log_response"):
                with self.subTest(context=context, helper=helper):
                    result = self.run_function(helper + '() { echo "fixture helper refusal" >&2; return 7; }; '
                        'if read_live_appcast master "" "' + context + '" "invalid fixture"; then exit 9; fi')
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('release: ' + context + ' (HTTP ', result.stderr)
                    self.assertIn("unknown" if helper == "http_status" else "503", result.stderr)

    def test_source_preserves_an_already_installed_exit_trap(self):
        (self.root / "build/dist").mkdir(parents=True)
        result = self.run_function('release_preflight; [ -f "$APPCAST_BASE" ]',
            before_source='trap \'echo "fixture prior caller trap"; cleanup_appcast_base\' EXIT')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("fixture prior caller trap", result.stdout)
        self.assertEqual(list((self.root / "build/dist").glob("appcast-base.*")), [])

    def test_inspection_and_publication_modes_are_exclusive(self):
        self.state_path.write_text(json.dumps(self.state))
        inspections = (("--inspect-functions",), ("--print-cask-action", VERSION),
            ("--notes-for", VERSION), ("--print-release-args", VERSION),
            ("--verify-appcast", "missing", "", "Pensieve-1.0.0.dmg", DOWNLOAD_PREFIX, VERSION, "26.0"))
        for mode in ("--publish", "--first-release", "--publish-cask-only", "--dry-run", "--dry-run-local"):
            for inspect in inspections:
                with self.subTest(mode=mode, inspect=inspect):
                    result = subprocess.run(["/bin/bash", str(self.root / "script/release.sh"), mode, *inspect],
                        env=self.env, capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 64, "mixed inspection/publication must refuse before any work")
                    self.assertIn("usage:", result.stderr)
                    self.assertEqual(json.loads(self.state_path.read_text())["calls"], [])
                    self.assertFalse((self.root / "build").exists())

    def test_non_crypto_focused_run_does_not_compile_swift(self):
        code = '''import sys, unittest
from unittest import mock
import release_self_test as suite
run = suite.subprocess.run
def no_compilation(args, *positional, **keywords):
    if args[0] == "/usr/bin/swiftc":
        raise AssertionError("non-crypto focused run compiled Swift")
    return run(args, *positional, **keywords)
with mock.patch.object(suite.subprocess, "run", side_effect=no_compilation):
    result = unittest.TextTestRunner().run(unittest.TestLoader().loadTestsFromName(
        "ReleaseSequenceTests.test_check_tag_mode_has_no_release_work_for_matching_or_mismatched_tags", suite))
sys.exit(not result.wasSuccessful())
'''
        result = subprocess.run(["python3", "-B", "-c", code], cwd=ROOT / "script",
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_default_swift_verifier_in_spaced_checkout_and_cold_cache(self):
        signature = self.install_fixture_public_key()
        self.env.pop("VERIFY_UPDATE_CMD")
        self.state["appcast"] = feed(signature=signature)
        self.assertIn(" ", str(self.root))
        cache = self.root / "cold swift module cache"
        self.assertFalse(cache.exists())
        self.env.update(SWIFT_MODULECACHE_PATH=str(cache), CLANG_MODULE_CACHE_PATH=str(cache))
        # Observe the actual default Swift child's credential boundary, without replacing its verifier.
        source = self.root / "script/verify_update.swift"
        source.write_text(source.read_text() + '\nlet env = ProcessInfo.processInfo.environment\n'
                          'if env["TAP_GH_TOKEN"] != nil || env["CASK_TAP_TOKEN"] != nil || env["GH_TOKEN"] == "fixture-tap-token" { fputs("fixture verifier inherited tap credential\\n", stderr); exit(1) }\n')
        self.cask_artifact()
        self.state_path.write_text(json.dumps(self.state))
        command = ["/bin/bash", str(self.root / "script/release.sh"), "--publish-cask-only"]
        result = subprocess.run(command, env=self.env, capture_output=True, text=True, timeout=DEFAULT_SWIFT_RELEASE_TIMEOUT)
        self.state = json.loads(self.state_path.read_text())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.state["writes"], ["cask"])
        self.assertTrue(any(cache.rglob("*.swiftmodule")), "the production Swift branch must use the cold cache")
        self.cask_artifact(b"wrong built DMG")
        result = subprocess.run(command, env=self.env, capture_output=True, text=True, timeout=DEFAULT_SWIFT_RELEASE_TIMEOUT)
        self.assertNotEqual(result.returncode, 0, "the default Swift verifier must reject tampered bytes")
        self.assertIn("Published DMG EdDSA signature does not match appcast", result.stderr)
        self.assertEqual(json.loads(self.state_path.read_text())["writes"], ["cask"])

    def test_cask_verification_supports_tmpdir_with_spaces(self):
        scratch = self.root / "TMPDIR with spaces"; scratch.mkdir()
        self.env["TMPDIR"] = str(scratch) + "/"
        signature = self.install_fixture_public_key()
        self.state["appcast"] = feed(signature=signature)
        self.cask_artifact()
        self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], ["cask"])
        self.assertEqual(list(scratch.iterdir()), [], "cask response files must be cleaned from the spaced TMPDIR")

    def test_expected_tag_is_checked_by_release_script_before_work(self):
        self.cask_artifact()
        self.state["appcast"] = feed()
        self.state_path.write_text(json.dumps(self.state))
        for mode in ("--publish", "--publish-cask-only", "--dry-run"):
            with self.subTest(mode=mode):
                result = subprocess.run(["/bin/bash", str(self.root / "script/release.sh"),
                                         "--expect-tag", "v9.9.9", mode], env=self.env,
                                        text=True, capture_output=True, timeout=30)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("release: tag 'v9.9.9' does not match VERSION v" + VERSION, result.stderr)
                self.assertEqual(json.loads(self.state_path.read_text())["calls"], [])
        result = subprocess.run(["/bin/bash", str(self.root / "script/release.sh"),
                                 "--expect-tag", "v" + VERSION, "--publish-cask-only"],
                                env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.state_path.read_text())["writes"], ["cask"])

    def test_crypto_fixtures_reuse_binaries_without_swift_sources(self):
        self.install_fixture_public_key()
        original_run = subprocess.run

        def without_compilation(args, *positional, **keywords):
            self.assertNotIn(args[0], ("/usr/bin/swift", "/usr/bin/swiftc"),
                             "warm fixture use must not compile Swift again")
            return original_run(args, *positional, **keywords)

        with mock.patch.object(subprocess, "run", side_effect=without_compilation):
            signature = self.install_fixture_public_key()
            (self.root / "script/verify_update.swift").unlink()
            self.state["appcast"] = feed(signature=signature)
            self.cask_artifact()
            self.run_release(cask_only=True)
            self.assertEqual(self.state["writes"], ["cask"])
            self.cask_artifact(b"wrong built DMG")
            self.assertIn("EdDSA", self.run_release(cask_only=True, expected=1))

    def test_sparse_cask_job_verifies_artifact_and_retries_without_build_tools(self):
        signature = self.install_fixture_public_key()
        self.state["appcast"] = feed(signature=signature)
        job_result = subprocess.run(["/usr/bin/ruby", "-ryaml", "-rjson", "-e",
                                     'puts JSON.generate(YAML.load_file(ARGV[0]).fetch("jobs").fetch("cask"))',
                                     str(ROOT / ".github/workflows/release.yml")],
                                    capture_output=True, text=True, timeout=30)
        self.assertEqual(job_result.returncode, 0, job_result.stderr)
        job = json.loads(job_result.stdout)
        checkout = self.root / "sparse cask checkout"; checkout.mkdir()
        inputs = job["steps"][0]["with"]["sparse-checkout"].splitlines()
        for pattern in inputs:
            relative = pattern.lstrip("/")
            dest = checkout / relative; dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(self.root / relative, dest)
        self.assertFalse((checkout / "project.yml").exists())
        self.assertFalse((checkout / "script/package.sh").exists())
        artifact_dir = checkout / job["steps"][1]["with"]["path"]
        artifact_dir.mkdir(parents=True)
        artifact = artifact_dir / ("Pensieve-" + VERSION + ".dmg")
        artifact.write_bytes(DMG)
        command = job["steps"][-1]["run"]
        credentials = {"${{ github.token }}": "fixture-public-token",
                       "${{ secrets.RELEASE_REPO_TOKEN }}": "fixture-tap-token"}
        env = dict(self.env, GITHUB_REF_NAME="v" + VERSION,
                   **{key: credentials[value] for key, value in job["steps"][-1]["env"].items()})
        env.pop("SPARKLE_PRIVATE_KEY_FILE")
        self.state_path.write_text(json.dumps(self.state))

        def invoke(expected, tag="v" + VERSION):
            result = subprocess.run(["/bin/bash", "-c", command], cwd=checkout,
                                    env=dict(env, GITHUB_REF_NAME=tag), capture_output=True, text=True,
                                    timeout=RELEASE_RUN_TIMEOUT)
            self.state = json.loads(self.state_path.read_text())
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            self.assertEqual(self.state["builds"], 0)
            self.assertEqual(self.state["signing_inputs"], [])
            forbidden = {"xcodegen", "xcodebuild", "codesign", "hdiutil", "notary", "stapler", "generate"}
            self.assertFalse(any(call[0] in forbidden for call in self.state["calls"]))
            return result.stdout + result.stderr

        self.assertIn("does not match VERSION", invoke(1, "v9.9.9"))
        self.assertEqual(self.state["calls"], [])
        artifact.write_bytes(b"wrong built DMG")
        self.assertIn("EdDSA", invoke(1))
        self.assertEqual(self.state["writes"], [])
        self.assertFalse(any("pensieve.rb" in arg for call in self.state["calls"] for arg in call))
        artifact.write_bytes(DMG)
        self.assertIn("cask done", invoke(0))
        self.assertEqual(self.state["writes"], ["cask"])
        self.assertIn("cask done", invoke(0))
        self.assertEqual(self.state["writes"], ["cask"], "rerunning only the cask job must write once")
        for endpoint, token in self.state["credential_calls"]:
            expected_token = "fixture-tap-token" if "/homebrew-tap/" in endpoint else "fixture-public-token"
            self.assertEqual(token, expected_token, endpoint)

    def test_failed_and_malformed_reads_are_unknown(self):
        original = json.loads(json.dumps(self.state))
        cases = list(itertools.product(("fail_read", "malformed"), ("release", "appcast", "cask", "tag")))
        cases += [("null_content", "appcast"), ("null_content", "cask")]
        for mode, kind in cases:
            with self.subTest(mode=mode, kind=kind):
                self.state = json.loads(json.dumps(original))
                self.state[mode] = kind
                output = self.run_release(expected=1)
                self.assertIn(kind, output)
                self.assertNotIn("Traceback", output)
                if mode == "null_content": self.assertIn("invalid 'contents' state", output)
                self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)

        for state in ("missing", None, "processing", "", 1):
            with self.subTest(unknown_asset_state=state):
                self.state = json.loads(json.dumps(original))
                asset = dict(self.state["expected_release"]["assets"][0], state=state)
                if state == "missing": asset.pop("state")
                self.state["release"] = dict(self.state["expected_release"], assets=[asset])
                output = self.run_release(expected=1)
                self.assertIn("unknown upload state", output)
                self.assertNotIn("Traceback", output)
                self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)

    def test_appcast_race_stops_and_recovery_reads_new_state(self):
        self.state.update(race="appcast", race_content=feed())
        self.assertIn("409", self.run_release(expected=1))
        self.assertEqual(self.state["writes"], ["create"])
        self.state.pop("race")
        self.run_release(); self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], ["create", "cask"])
        self.assertEqual(self.state["builds"], 1)

    def test_cask_race_stops_and_second_run_is_done(self):
        self.run_release()
        result = self.run_function('VERSION=1.0.0; DMG_PATH="$DIST_DIR/Pensieve-$VERSION.dmg"; write_bumped_cask "$DIST_DIR/homebrew/pensieve.rb" "$(shasum -a 256 "$DMG_PATH" | awk \'{print $1}\')"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.state.update(race="cask", race_content=(self.root / "build/dist/homebrew/pensieve.rb").read_text())
        self.assertIn("409", self.run_release(cask_only=True, expected=1))
        self.state.pop("race")
        self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], ["create", "appcast"])

    def test_prerelease_recovery_skips_cask(self):
        version = "1.0.0-beta.1"
        self.set_version(version)
        original = json.loads(json.dumps(self.state))
        for problem in ({"fail_read": "cask"}, {"malformed": "cask"}, {"cask": "def broken("}, {"cask": None, "cask_sha": ""}):
            with self.subTest(problem=problem):
                self.state = dict(json.loads(json.dumps(original)), **problem)
                self.state.update(appcast=feed(version), release=self.state["expected_release"])
                self.run_release(); self.run_release(cask_only=True)
                self.assertEqual(self.state["writes"], [])
                self.assertFalse(any("pensieve.rb" in arg for call in self.state["calls"] for arg in call))

    def test_older_version_cannot_move_publications_back(self):
        self.run_release(); self.run_release(cask_only=True)
        self.set_version("1.1.0")
        self.state.update(release=None, new_feed=feeds("1.1.0", VERSION, publication_version="1.1.0"))
        self.run_release(); self.run_release(cask_only=True)
        published_feed, published_cask = self.state["appcast"], self.state["cask"]
        self.set_version(VERSION)
        self.state.update(release=self.state["expected_release"], writes=[], calls=[], builds=0, signing_inputs=[])
        output = self.run_release() + self.run_release(cask_only=True)
        self.assertEqual(self.state["cask"], published_cask, "old workflow must not downgrade the cask")
        self.assertEqual(self.state["appcast"], published_feed, "old workflow must not downgrade the appcast")
        self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)
        self.assertIn("newer version '1.1.0'", output)

    def test_older_appcast_publication_stops_before_build(self):
        original = json.loads(json.dumps(self.state))
        for older, newer in (("1.0.0", "1.1.0"), ("1.9.0", "1.10.0"), ("1.0.0-beta.1", "1.1.0-beta.1"), ("1.0.0-beta.2", "1.0.0-beta.11"), ("1.0.0-beta.2", "1.0.0"), ("1.0.0-beta.1", "1.1.0")):
            with self.subTest(older=older, newer=newer):
                self.state = json.loads(json.dumps(original)); self.set_version(older)
                self.state["appcast"] = feed(newer)
                self.assertIn("newer version " + repr(newer), self.run_release(expected=1))
                self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)
        # Stable clients ignore beta; beta clients also receive the default channel.
        for version, other, channel in (("1.0.1", "1.1.0-beta.1", "beta"), ("1.0.0-beta.1", "1.1.0-alpha.1", "alpha")):
            with self.subTest(version=version, other_channel=channel):
                self.state = json.loads(json.dumps(original)); self.set_version(version)
                self.state["appcast"] = feed(other, channel=channel)
                self.state["new_feed"] = feed(version, minimum="26.0").replace("</channel>", "<item>" + feed(other, channel=channel).split("<item>")[1].split("</item>")[0] + "</item>" + "</channel>")
                output = self.run_release() + self.run_release(cask_only=True)
                self.assertNotIn("refusing older appcast", output)
                self.assertIn(other, self.state["appcast"])
                self.assertEqual(self.state["writes"], ["create", "appcast"] + (["cask"] if not PUBLICATION_CASES[version][1] else []))
                self.assertEqual(self.state["builds"], 1)

    def test_cask_template_changes_reach_tap_and_repeat_is_noop(self):
        import hashlib
        self.run_release()
        self.state["cask"] = cask(VERSION, hashlib.sha256(DMG).hexdigest())
        template = self.root / "release/homebrew/pensieve.rb"
        stanza = '  auto_updates true\n'
        template.write_text(template.read_text().replace('  app "Pensieve.app"\n', stanza + '  app "Pensieve.app"\n'))
        self.run_release(cask_only=True)
        self.assertIn(stanza, self.state["cask"], "repo template stanza must reach the tap")
        self.assertIn('  version "1.0.0"', self.state["cask"])
        self.assertIn(hashlib.sha256(DMG).hexdigest(), self.state["cask"])
        self.assertEqual(self.state["writes"], ["create", "appcast", "cask"])
        self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], ["create", "appcast", "cask"])

    def test_changed_malformed_appcast_reports_race_and_cleans_up(self):
        temporary = self.root / "temporary"; temporary.mkdir()
        self.env["TMPDIR"] = str(temporary)
        original = json.loads(json.dumps(self.state))
        for sha in ("b" * 40, SHA):
            with self.subTest(sha=sha):
                self.state = dict(json.loads(json.dumps(original)), recheck_content="<invalid/>", recheck_sha=sha)
                output = self.run_release(expected=1 if sha != SHA else 0)
                if sha != SHA: self.assertIn("appcast changed since preflight", output)
                self.assertEqual(list(temporary.glob("pensieve-appcast-response.*")), [], "appcast response must be cleaned up")
                self.assertFalse((self.root / "build/dist/recheck-appcast.xml").exists())
                self.assertEqual(self.state["writes"], [] if sha != SHA else ["create", "appcast"])

    def test_appcast_recheck_reads_only_sha(self):
        self.state.update(null_content="appcast")
        result = self.run_function('''APPCAST_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PUBLIC_BRANCH=master
verify_appcast_unchanged''')
        self.assertEqual(result.returncode, 0, "matching blob SHA needs no content decode: " + result.stderr)
        self.assertFalse((self.root / "build/dist/recheck-appcast.xml").exists())

    def test_cask_status_reports_publication_progress(self):
        self.assertIn("cask step runs next", self.run_release(), "fresh publication must explain the next step without deciding cask status")
        recovery = self.run_release()
        self.assertIn("cask step runs next", recovery)
        publication = self.run_release(cask_only=True)
        self.assertNotIn("cask pending", publication, "the cask publisher must not direct itself to publish again")
        self.assertIn("cask done", publication)
        self.assertEqual(self.state["writes"], ["create", "appcast", "cask"])
        recovered = self.run_release()
        self.assertIn("cask step runs next", recovered)
        self.assertNotIn("cask done", recovered, "recovery must leave current cask status to its step")
        self.assertIn("cask done", self.run_release(cask_only=True))
        self.assertEqual(self.state["writes"], ["create", "appcast", "cask"])

    def test_prerelease_channel_controls_publication(self):
        original = json.loads(json.dumps(self.state))
        for version, channel in ((VERSION, ""), ("1.0.0-alpha.1", "beta"), ("1.0.0-beta.2", "beta"), ("1.0.0-rc.1", "beta")):
            with self.subTest(version=version):
                self.state = json.loads(json.dumps(original)); self.set_version(version)
                action = subprocess.run(["/bin/bash", str(self.root / "script/release.sh"), "--print-cask-action", version], env=self.env, text=True, capture_output=True, timeout=30)
                self.assertEqual(action.returncode, 0, action.stderr)
                self.assertEqual(action.stdout.strip(), "skip" if PUBLICATION_CASES[version][1] else "bump")
                self.run_release(); self.run_release(cask_only=True)
                generate = next(call for call in self.state["calls"] if call[0] == "generate")
                create = next(call for call in self.state["calls"] if call[:3] == ["gh", "release", "create"])
                self.assertEqual("--prerelease" in create, bool(channel))
                if channel: self.assertEqual(generate[generate.index("--channel") + 1], channel)
                else: self.assertNotIn("--channel", generate)
                self.assertEqual(self.state["writes"], ["create", "appcast"] + ([] if channel else ["cask"]))
                self.run_release()
                self.assertEqual(self.state["builds"], 1)
        for invalid in ("1.0", "01.0.0", "1.0.0-beta.01"):
            with self.subTest(invalid_version=invalid):
                result = subprocess.run(["/bin/bash", str(self.root / "script/release.sh"), "--print-cask-action", invalid],
                                        env=self.env, text=True, capture_output=True, timeout=30)
                self.assertNotEqual(result.returncode, 0, "unknown publication version must not select a cask action")
                self.assertIn("invalid publication version" if invalid == "1.0" else "leading zeros", result.stderr)

    def test_release_recheck_compares_action_state(self):
        original = json.loads(json.dumps(self.state))
        for state in ("uploaded", "open", "starter"):
            with self.subTest(asset_state=state):
                self.state = json.loads(json.dumps(original))
                initial = dict(self.state["expected_release"], assets=[dict(self.state["expected_release"]["assets"][0], state=state)])
                reread = dict(initial, assets=[dict(initial["assets"][0], id=99, size=100, state=("starter" if state == "open" else "open") if state != "uploaded" else state)])
                self.state.update(release=initial, recheck_release=reread)
                self.run_release()
                self.assertEqual(self.state["writes"], ["replace", "appcast"], "transient asset metadata must not waste the rebuilt DMG")
                self.assertEqual(self.state["builds"], 1)
        for change in ({"id": 99}, {"assets": []}, {"draft": True}, {"prerelease": True}, {"tag_name": "v9.0.0"}):
            with self.subTest(action_change=change):
                self.state = json.loads(json.dumps(original))
                self.state.update(release=self.state["expected_release"], recheck_release=dict(self.state["expected_release"], **change))
                self.run_release(expected=1)
                self.assertEqual(self.state["writes"], [], "identity or action category changes must stop")

    def test_contents_write_requires_explicit_preflight_sha(self):
        source = self.root / "source.xml"; source.write_text(feed())
        result = self.run_function('publish_contents_file fixture/public appcast.xml "$REPO/source.xml" fixture master')
        self.assertEqual(self.state["calls"], [], "a write must never discover a new SHA after preflight")
        self.assertNotEqual(result.returncode, 0)

    def test_appcast_uses_release_download_prefix(self):
        prefix = "https://github.com/fixture/public/releases/download"
        script = self.root / "script/release.sh"
        self.assertEqual(script.read_text().count('PUBLIC_REPO="jaredatch/pensieve"'), 1)
        script.write_text(script.read_text().replace('PUBLIC_REPO="jaredatch/pensieve"', 'PUBLIC_REPO="fixture/public"'))
        self.state.update(release=self.state["expected_release"], appcast=feed(prefix=prefix))
        self.run_release()
        self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)
        self.state.update(release=None, appcast=feed("0.9.0", prefix=prefix), new_feed=feed(prefix=prefix))
        self.run_release()
        command = next(call for call in self.state["calls"] if call[0] == "generate")
        self.assertEqual(command[command.index("--download-url-prefix") + 1], prefix + "/v1.0.0/")

    def test_package_removes_stale_product_before_build(self):
        stale = self.root / "build/package-dd/Build/Products/Release/Pensieve.app/Contents/stale-proof"
        stale.parent.mkdir(parents=True, exist_ok=True); stale.write_text("retired")
        self.run_release()
        self.assertFalse(self.state.get("stale_survived", False))
        self.assertFalse(self.state["packaged_stale"])

    def test_first_release_and_missing_cask_are_create_only(self):
        self.state.update(appcast=None, appcast_sha="", cask=None, cask_sha="")
        self.run_release(first=True); self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], ["create", "appcast", "cask"])

    def test_malformed_published_text_stops_before_build(self):
        for kind, value in (("appcast", ""), ("appcast", "<invalid/>"), ("appcast", feed() + feed()), ("cask", ""), ("cask", cask() + '  version "1.0.0"\n'), ("cask", cask() + "def broken(\n")):
            with self.subTest(kind=kind, value=value):
                original = self.state[kind]; self.state[kind] = value
                self.run_release(expected=1)
                self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)
                self.state[kind] = original

        for element in ("<sparkle:channel/>", "<sparkle:channel></sparkle:channel>"):
            self.state.update(appcast=feed().replace("<enclosure", element + "<enclosure"), release=self.state["expected_release"])
            self.assertIn("empty appcast channel", self.run_release(expected=1))
            self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)

        for version, channel in ((VERSION, "beta"), ("1.0.0-beta.2", ""), ("1.0.0-beta.2", "alpha")):
            with self.subTest(version=version, wrong_live_channel=channel):
                self.set_version(version)
                self.state.update(appcast=feed(version, channel=channel), release=self.state["expected_release"])
                self.assertIn("wrong channel", self.run_release(expected=1))
                self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)
                self.assertFalse(any(call[:3] == ["gh", "release", "download"] for call in self.state["calls"]))

        for channel in ("\n  beta\n", " beta", "beta ", "\t", "BETA", "nightly"):
            with self.subTest(malformed_newer_channel=channel):
                self.set_version("1.0.0-beta.2")
                self.state.update(appcast=feed("1.1.0-beta.1", channel=channel), release=None)
                self.assertIn("malformed appcast channel", self.run_release(expected=1))
                self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)
                self.assertFalse(any(call[:3] == ["gh", "release", "download"] for call in self.state["calls"]))


    def test_inspect_modes_validate_only_their_version_arguments(self):
        for file_version in (None, "", "not-a-publication-version"):
            with self.subTest(file_version=file_version):
                version_file = self.root / "VERSION"
                if file_version is None: version_file.unlink(missing_ok=True)
                else: version_file.write_text(file_version)
                inspected = self.run_function('printf "inspected\\n"')
                self.assertEqual(inspected.returncode, 0, "function inspection must not depend on VERSION: " + inspected.stderr)
                base = self.root / "base.xml"; base.write_text(feed("0.9.0"))
                appcast = self.root / "inspect.xml"; appcast.write_text(feed())
                result = subprocess.run(["/bin/bash", str(self.root / "script/release.sh"), "--verify-appcast", str(appcast), str(base), "Pensieve-1.0.0.dmg", DOWNLOAD_PREFIX, VERSION, "26.0"], env=self.env, text=True, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, "provenance inspection must not depend on VERSION: " + result.stderr)
                for option in ("--notes-for", "--print-release-args", "--print-cask-action"):
                    printed = subprocess.run(["/bin/bash", str(self.root / "script/release.sh"), option, VERSION], env=self.env, text=True, capture_output=True, timeout=30)
                    self.assertEqual(printed.returncode, 0, printed.stderr)

    def test_fresh_cask_cue_cannot_fail_after_publication(self):
        self.state["break_template_after_appcast"] = str(self.root / "release/homebrew/pensieve.rb")
        output = self.run_release()
        self.assertIn("cask step runs next", output)
        self.assertNotIn("cask done", output, "fresh publication must not report stale cask status")
        self.assertEqual(self.state["writes"], ["create", "appcast"])
        self.assertEqual(sum("pensieve.rb" in arg for call in self.state["calls"] for arg in call), 1, "fresh reporting must not re-read the tap")
        self.assertFalse((self.root / "build/dist/homebrew/pensieve.rb").exists(), "fresh reporting must not render or compare a cask")
        self.assertIn("invalid 'rewrite-cask' state", self.run_release(cask_only=True, expected=1))

    def test_refusal_logs_escape_parsed_response_text(self):
        original = json.loads(json.dumps(self.state))
        bodies = ('resolve_public_branch', 'verify_public_branch_unchanged', 'release_preflight',
                  'PUBLIC_BRANCH=master; verify_appcast_unchanged', 'read_release_state', 'cask_preflight',
                  'publish_contents_file fixture/public appcast.xml "$REPO/source.xml" fixture master aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                  f'verify_appcast_provenance "$REPO/provenance.xml" "" Pensieve-{VERSION}.dmg {DOWNLOAD_PREFIX} {VERSION} 26.0')
        (self.root / "source.xml").write_text(feed())
        for poison, body in itertools.product(POISON_TEXTS, bodies):
            with self.subTest(poison=poison, body=body):
                self.state = dict(json.loads(json.dumps(original)), response_tail="\n" + poison,
                                  fail_status=poison.replace("\n", ""), fail_read="appcast")
                if body in ('resolve_public_branch', 'verify_public_branch_unchanged'): self.state["branch"] = poison
                if body == 'read_release_state': self.state["fail_read"] = "release"
                if body == 'cask_preflight': self.state["fail_read"] = "cask"
                if body.startswith('publish_contents_file'): self.state["race"] = "appcast"
                archive = poison + ".dmg"
                root = ET.fromstring(feed())
                ET.SubElement(root.find("channel/item"), "enclosure", url="https://fixture/" + archive)
                (self.root / "provenance.xml").write_text(ET.tostring(root, encoding="unicode"))
                result = self.run_function(body)
                self.assertNotEqual(result.returncode, 0, "the parsed-input guard must exercise a refusal")
                self.assertTrue(result.stderr)
                assert_safe_diagnostic(self, result.stderr)
                assert_safe_diagnostic(self, result.stdout)

    def test_appcast_provenance_parses_enclosures_and_requires_built_dmg(self):
        source = self.root / "provenance.xml"; base = self.root / "base.xml"
        base.write_text(feed("0.9.0"))
        def inspect(text):
            source.write_text(text)
            return subprocess.run(["/bin/bash", str(self.root / "script/release.sh"), "--verify-appcast",
                                   str(source), str(base), "Pensieve-1.0.0.dmg", DOWNLOAD_PREFIX, VERSION, "26.0"],
                                  env=self.env, text=True, capture_output=True, timeout=30)
        for text in (feed("0.9.0"), '<rss><channel/></rss>'):
            with self.subTest(missing_built=text):
                result = inspect(text)
                self.assertEqual(result.returncode, 1, "provenance must require this run's built DMG")
                self.assertIn("no item for the publication version", result.stderr)
        for text in ("<rss><channel>", "not XML", '<!DOCTYPE rss><rss><channel/></rss>'):
            with self.subTest(malformed=text):
                result = inspect(text)
                self.assertEqual(result.returncode, 1, "provenance must fail closed on invalid XML")
                self.assertIn("invalid 'provenance' state", result.stderr)
        for url in (f"{DOWNLOAD_PREFIX}/v0.9.0/Pensieve-0.9.0.dmg?download=1&amp;source=release",
                    f"{DOWNLOAD_PREFIX}/v0.9.0/Pensieve-0.9.0.&#100;mg",
                    f"{DOWNLOAD_PREFIX}/v0.9.0/Pensieve-0.9.0.%64mg"):
            with self.subTest(trusted_base_url=url):
                old_url = 'url="' + DOWNLOAD_PREFIX + '/v0.9.0/Pensieve-0.9.0.dmg"'
                base.write_text(feed("0.9.0").replace(old_url, "url='" + url + "'"))
                text = feeds("0.9.0", VERSION).replace(old_url, "url='" + url + "'")
                self.assertEqual(inspect(text).returncode, 0, "carried full URLs must preserve trusted XML quoting/entities/query strings")
        base.write_text(feed("0.9.0"))
        canonical = 'url="' + DOWNLOAD_PREFIX + '/v1.0.0/Pensieve-1.0.0.dmg"'
        self.assertEqual(inspect(feed().replace(canonical, "url='" + DOWNLOAD_PREFIX + "/v1.0.0/Pensieve-1.0.0.&#100;mg'")).returncode, 0)
        for url in (DOWNLOAD_PREFIX + "/v1.0.0/Pensieve-1.0.0.dmg?download=1", DOWNLOAD_PREFIX + "/v1.0.0/Pensieve-1.0.0.%64mg"):
            self.assertEqual(inspect(feed().replace(canonical, 'url="' + url + '"')).returncode, 1, "this run's URL must match exactly")
        for enclosure in ("<enclosure url='https://fixture/Pensieve-9.9.9.dmg'/>",
                          '<enclosure url="https://fixture/Pensieve-9.9.9.&#100;mg"/>',
                          '<enclosure url="https://fixture/Pensieve-9.9.9.%64mg"/>',
                          '<enclosure url="https://fixture/Pensieve-9.9.9.dmg?download=1&amp;source=release"/>'):
            for before in (False, True):
                with self.subTest(untrusted=enclosure, before=before):
                    text = feed().replace('<enclosure', enclosure + '<enclosure', 1) if before else feed().replace('</item>', enclosure + '</item>')
                    result = inspect(text)
                    self.assertEqual(result.returncode, 1, "every parsed DMG enclosure must have trusted provenance")
                    self.assertIn("duplicated appcast enclosure", result.stderr)
        source.unlink(); source.mkdir()
        result = subprocess.run(["/bin/bash", str(self.root / "script/release.sh"), "--verify-appcast",
                                 str(source), str(base), "Pensieve-1.0.0.dmg", DOWNLOAD_PREFIX, VERSION, "26.0"],
                                env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 1, "provenance must refuse read errors")

    def test_generated_appcast_provenance_failure_prevents_publication(self):
        original = json.loads(json.dumps(self.state))
        for text in (feed("0.9.0"), '<rss><channel>',
                     feed().replace('</item>', "<enclosure url='https://fixture/Pensieve-9.9.9.dmg'/></item>"),
                     feeds("0.9.0", VERSION).replace('</item>', "<sparkle:deltas><enclosure url='https://fixture/other.zip'/></sparkle:deltas></item>", 1),
                     feed().replace(DOWNLOAD_PREFIX, "https://evil/x")):
            with self.subTest(generated=text):
                self.state = json.loads(json.dumps(original)); self.state["new_feed"] = text
                self.run_release(expected=1)
                self.assertEqual(self.state["writes"], [], "unproven generated enclosures must stop before release or appcast publication")

    def run_appcast_generation(self):
        version = self.state["version"]
        input_dir = self.root / "build/dist/appcast-input"
        shutil.rmtree(input_dir, ignore_errors=True); input_dir.mkdir(parents=True)
        (input_dir.parent / ("Pensieve-" + version + ".dmg")).write_bytes(DMG)
        info = input_dir.parent / "dmg-root/Pensieve.app/Contents/Info.plist"
        info.parent.mkdir(parents=True, exist_ok=True)
        info.write_bytes(plistlib.dumps({"LSMinimumSystemVersion": "26.0", "CFBundleExecutable": "Pensieve"}))
        for name in ("Pensieve", "pensieve-daemon"):
            binary = info.parent / "MacOS" / name
            binary.parent.mkdir(parents=True, exist_ok=True); binary.write_text("fixture Mach-O")
        return self.run_function('VERSION="' + version + '"; VERSION_CHANNEL="' + PUBLICATION_CASES[version][0] + '"; DMG_PATH="$DIST_DIR/Pensieve-$VERSION.dmg"; verify_dmg_app_ticket; release_preflight; generate_appcast')

    def test_release_checks_app_and_daemon_slices_before_publication(self):
        original = json.loads(json.dumps(self.state))
        for fault in ({"daemon_minimum": "14.0"}, {"daemon_minimum_by_arch": {"x86_64": "14.0"}},
                      {"app_minimum_by_arch": {"arm64": "14.0"}}):
            with self.subTest(fault=fault):
                self.state = dict(json.loads(json.dumps(original)), **fault)
                output = self.run_release(expected=1)
                self.assertIn("must require macOS 26.0", output)
                self.assertIn("14.0", output)
                self.assertEqual(self.state["writes"], [], "invalid app or daemon slices must stop before publication")

    def test_release_reads_minimum_from_the_dmg_app(self):
        original = json.loads(json.dumps(self.state))
        for staged, mounted in (("26.0", "27.2"), ("14.0", "26.0")):
            with self.subTest(staged=staged, mounted=mounted):
                self.state = dict(json.loads(json.dumps(original)), built_minimum=staged,
                                  dmg_minimum=mounted, new_feed=feed(minimum=mounted))
                self.run_release()
                self.assertEqual(self.state["writes"], ["create", "appcast"])
        self.state = dict(json.loads(json.dumps(original)), dmg_minimum="14.0")
        output = self.run_release(expected=1)
        self.assertIn("generated appcast minimum 26.0 differs from built app minimum 14.0", output)
        self.assertEqual(self.state["writes"], [])
        self.state = dict(json.loads(json.dumps(original)), dmg_minimum=None)
        self.assertIn("built app has no minimum system version", self.run_release(expected=1))
        self.assertEqual(self.state["writes"], [])

    def test_appcast_verification_requires_a_minimum(self):
        source = self.root / "inspect.xml"; source.write_text(feed())
        base = self.root / "base.xml"; base.write_text(feed("0.9.0"))
        command = ["/bin/bash", str(self.root / "script/release.sh"), "--verify-appcast", str(source),
                   str(base), "Pensieve-1.0.0.dmg", DOWNLOAD_PREFIX, VERSION]
        self.assertEqual(subprocess.run(command, env=self.env, capture_output=True, timeout=30).returncode, 64,
                         "inspection must refuse an omitted built minimum")
        source.write_text(feed(minimum="14.0"))
        result = subprocess.run(command + ["26.0"], env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 1)
        self.assertIn("generated appcast minimum 14.0 differs from built app minimum 26.0", result.stderr)
        with self.assertRaises(TypeError, msg="the Python provenance API requires a minimum too"):
            self.tool.appcast_provenance(feed(), feed("0.9.0"), "Pensieve-1.0.0.dmg", DOWNLOAD_PREFIX, VERSION)
        for minimum in (None, ""):
            with self.subTest(minimum=minimum), self.assertRaisesRegex(ValueError, "built app minimum is required"):
                self.tool.appcast_provenance(feed(), feed("0.9.0"), "Pensieve-1.0.0.dmg", DOWNLOAD_PREFIX, VERSION, minimum)

    def test_fixture_history_defaults_to_macos_14(self):
        for version in ("0.9.0", "1.0.0-alpha.1"):
            self.assertEqual(ET.fromstring(feed(version)).findtext("channel/item/" + self.tool.SPARKLE + "minimumSystemVersion"), "14.0")
        self.assertEqual(ET.fromstring(feed()).findtext("channel/item/" + self.tool.SPARKLE + "minimumSystemVersion"), "26.0")

    def test_generated_appcast_minimum_matches_built_app_and_preserves_history(self):
        original = json.loads(json.dumps(self.state))
        for version, minimum in ((VERSION, "26.0"), ("1.0.0-beta.2", "27.2")):
            with self.subTest(version=version, minimum=minimum):
                self.state = json.loads(json.dumps(original)); self.set_version(version)
                old = ET.fromstring(feed("0.9.0"))
                self.assertEqual(old.findtext("channel/item/" + self.tool.SPARKLE + "minimumSystemVersion"), "14.0",
                                 "the historical fixture must keep its actual macOS 14 minimum")
                self.state["appcast"] = ET.tostring(old, encoding="unicode")
                root = ET.fromstring(ET.tostring(old))
                root.find("channel").append(ET.fromstring(feed(version, minimum=minimum)).find("channel/item"))
                self.state.update(built_minimum=minimum, new_feed=ET.tostring(root, encoding="unicode"))
                self.run_release()
                published = ET.fromstring(self.state["appcast"]).findall("channel/item")
                self.assertEqual(published[-1].findtext(self.tool.SPARKLE + "minimumSystemVersion"), minimum)
                self.assertEqual(ET.tostring(published[0]), ET.tostring(old.find("channel/item")), "earlier release items must remain unchanged")
                self.assertEqual(self.state["writes"], ["create", "appcast"])

    def test_generated_appcast_minimum_mismatch_stops_before_publication(self):
        original = json.loads(json.dumps(self.state))
        for built, generated in (("26.0", "14.0"), ("27.2", "26.0")):
            with self.subTest(built=built, generated=generated):
                self.state = dict(json.loads(json.dumps(original)), built_minimum=built, new_feed=feed(minimum=generated))
                output = self.run_release(expected=1)
                self.assertIn(f"generated appcast minimum {generated} differs from built app minimum {built}", output)
                self.assertEqual(self.state["writes"], [], "a minimum mismatch must stop before release or feed publication")

    def test_generated_appcast_minimum_requires_one_value(self):
        original = json.loads(json.dumps(self.state))
        for minimum in (None, "", "duplicate"):
            with self.subTest(minimum=minimum):
                root = ET.fromstring(feed(minimum="26.0" if minimum == "duplicate" else minimum))
                if minimum == "duplicate":
                    ET.SubElement(root.find("channel/item"), self.tool.SPARKLE + "minimumSystemVersion").text = "26.0"
                self.state = dict(json.loads(json.dumps(original)), new_feed=ET.tostring(root, encoding="unicode"))
                output = self.run_release(expected=1)
                self.assertIn("generated appcast has missing, empty or duplicated minimum system version", output)
                self.assertEqual(self.state["writes"], [])

    def test_generated_appcast_requires_built_app_minimum(self):
        self.state["built_minimum"] = None
        output = self.run_release(expected=1)
        self.assertIn("built app has no minimum system version", output)
        self.assertEqual(self.state["writes"], [])

    def test_cask_declares_macos_26_and_rendering_preserves_it(self):
        stanza = '  depends_on macos: :tahoe\n'
        self.assertIn(stanza, (self.root / "release/homebrew/pensieve.rb").read_text())
        self.run_release(); self.run_release(cask_only=True)
        self.assertIn(stanza, self.state["cask"], "the macOS requirement must reach the tap through template rendering")
        self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], ["create", "appcast", "cask"])

    def test_whole_feed_provenance_stops_untrusted_urls_before_publication(self):
        original = json.loads(json.dumps(self.state))
        unknown_urls = ("https://fixture/other.zip", "https://fixture/other.DMG",
                        "https://fixture/other.dmg;x", "https://fixture/archive/",
                        "https://evil/x/Pensieve-1.0.0.dmg")
        for url in unknown_urls:
            for placement in ("enclosure", "delta", "metadata", "namespaced", "root", "current"):
                with self.subTest(url=url, placement=placement):
                    root = ET.fromstring(feeds("0.9.0", VERSION)); item = root.find("channel/item")
                    if placement == "current": root.find("channel").findall("item")[-1].find("enclosure").set("url", url)
                    elif placement == "root": root.set("url", url)
                    elif placement == "metadata": ET.SubElement(root.find("channel"), "metadata", url=url)
                    elif placement == "namespaced": ET.SubElement(root.find("channel"), "metadata").set(self.tool.SPARKLE + "url", url)
                    else:
                        parent = item if placement == "enclosure" else ET.SubElement(item, self.tool.SPARKLE + "deltas")
                        ET.SubElement(parent, "enclosure", url=url)
                    self.state = json.loads(json.dumps(original)); self.state["new_feed"] = ET.tostring(root, encoding="unicode")
                    result = self.run_appcast_generation()
                    self.assertEqual(result.returncode, 1, "an untrusted URL anywhere must stop generation")
                    message = "wrong DMG URL" if placement == "current" else "channel or feed metadata" if placement in ("metadata", "namespaced", "root") else "another item" if placement == "delta" else "duplicated appcast enclosure"
                    self.assertIn(message, result.stderr)

    def test_generated_item_requires_one_current_url_and_valid_metadata(self):
        original = json.loads(json.dumps(self.state)); expected_url = f"{DOWNLOAD_PREFIX}/v{VERSION}/Pensieve-{VERSION}.dmg"
        for failure in ("wrong-version", "wrong-channel", "empty-channel", "zero-length", "bad-signature", "duplicate-url", "duplicate-item", "url-outside-current-item", "no-current-item"):
            with self.subTest(failure=failure):
                root = ET.fromstring(feed()); item = root.find("channel/item")
                if failure == "wrong-version": item.find(self.tool.SPARKLE + "shortVersionString").text = "0.9.0"
                elif failure in ("wrong-channel", "empty-channel"): ET.SubElement(item, self.tool.SPARKLE + "channel").text = "beta" if failure == "wrong-channel" else ""
                elif failure == "zero-length": item.find("enclosure").set("length", "0")
                elif failure == "bad-signature": item.find("enclosure").set(self.tool.SPARKLE + "edSignature", base64.b64encode(b"short").decode())
                elif failure == "duplicate-url": ET.SubElement(ET.SubElement(item, self.tool.SPARKLE + "deltas"), "enclosure", url=expected_url)
                elif failure == "duplicate-item": root.find("channel").append(ET.fromstring(ET.tostring(item)))
                elif failure == "no-current-item":
                    item.find(self.tool.SPARKLE + "shortVersionString").text = "0.9.0"
                    item.find("enclosure").set("url", DOWNLOAD_PREFIX + "/v0.9.0/Pensieve-0.9.0.dmg")
                else:
                    root.set("url", expected_url)
                    item.find("enclosure").set("url", DOWNLOAD_PREFIX + "/v0.9.0/Pensieve-0.9.0.dmg")
                self.state = json.loads(json.dumps(original)); self.state["new_feed"] = ET.tostring(root, encoding="unicode")
                result = self.run_appcast_generation()
                self.assertEqual(result.returncode, 1, "the current item must be valid before publishing")
                messages = {
                    "wrong-version": "names this DMG under another version", "wrong-channel": "wrong channel",
                    "empty-channel": "empty appcast channel", "zero-length": "invalid DMG length",
                    "bad-signature": "invalid EdDSA signature", "duplicate-url": "unexpected generated appcast item element",
                    "duplicate-item": "duplicated appcast item", "url-outside-current-item": "wrong DMG URL",
                    "no-current-item": "no item for the publication version",
                }
                self.assertIn(messages[failure], result.stderr, "each fixture must reach its own provenance guard")
        source = self.root / "generated.xml"; base = self.root / "base.xml"
        root = ET.fromstring(feed()); root.set("url", DOWNLOAD_PREFIX + "/v1.0.0/Other.dmg")
        source.write_text(ET.tostring(root, encoding="unicode")); base.write_text(feed())
        result = subprocess.run(["/bin/bash", str(self.root / "script/release.sh"), "--verify-appcast", str(source),
                                 str(base), "Other.dmg", DOWNLOAD_PREFIX, VERSION, "26.0"],
                                env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 1, "the supplied DMG must be the one in the VERSION item")
        self.assertIn("different built DMG", result.stderr)
        self.set_version("1.0.0-beta.1")
        self.state["new_feed"] = feed("1.0.0-beta.1", channel="")
        result = self.run_appcast_generation()
        self.assertEqual(result.returncode, 1, "a generated prerelease must be on beta")
        self.assertIn("wrong channel", result.stderr)

    def test_generated_item_matches_bundled_generator_output(self):
        root = ET.fromstring((ROOT / "PensieveTests/Fixtures/release-appcast-single-archive.xml").read_text())
        item = root.find("channel/item")
        self.set_version("1.0.0-beta.1")
        item.find(self.tool.SPARKLE + "shortVersionString").text = self.state["version"]
        item.find("enclosure").attrib.update(url=f'{DOWNLOAD_PREFIX}/v{self.state["version"]}/Pensieve-{self.state["version"]}.dmg',
                                            length=str(len(DMG)))
        item.find("enclosure").set(self.tool.SPARKLE + "edSignature", SIGNATURE)
        self.state["new_feed"] = ET.tostring(root, encoding="unicode")
        result = self.run_appcast_generation()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_generated_item_requires_the_observed_element_counts(self):
        captured = ET.fromstring((ROOT / "PensieveTests/Fixtures/release-appcast-single-archive.xml").read_text())
        item = captured.find("channel/item")
        item.find(self.tool.SPARKLE + "shortVersionString").text = VERSION
        item.remove(item.find(self.tool.SPARKLE + "channel"))
        item.find("enclosure").attrib.update(url=f"{DOWNLOAD_PREFIX}/v{VERSION}/Pensieve-{VERSION}.dmg",
                                            length=str(len(DMG)))
        item.find("enclosure").set(self.tool.SPARKLE + "edSignature", SIGNATURE)
        self.tool.appcast_provenance(ET.tostring(captured, encoding="unicode"), None,
                                    "Pensieve-1.0.0.dmg", DOWNLOAD_PREFIX, VERSION, "26.0")
        for tag in ("title", "pubDate", self.tool.SPARKLE + "version", self.tool.SPARKLE + "shortVersionString",
                    self.tool.SPARKLE + "minimumSystemVersion", "enclosure"):
            for mutation in ("duplicate", "missing"):
                with self.subTest(tag=tag, mutation=mutation):
                    altered = ET.fromstring(ET.tostring(item)); child = altered.find(tag)
                    if mutation == "duplicate": altered.append(ET.fromstring(ET.tostring(child)))
                    else: altered.remove(child)
                    root = ET.fromstring(ET.tostring(captured)); channel = root.find("channel")
                    channel.remove(channel.find("item")); channel.append(altered)
                    with self.assertRaises(ValueError, msg="generated fields require the captured one-archive counts"):
                        self.tool.appcast_provenance(ET.tostring(root, encoding="unicode"), None,
                            "Pensieve-1.0.0.dmg", DOWNLOAD_PREFIX, VERSION, "26.0")

    def test_generated_item_refuses_delta_notes_and_link_urls(self):
        original = json.loads(json.dumps(self.state))
        expected_url = f"{DOWNLOAD_PREFIX}/v{VERSION}/Pensieve-{VERSION}.dmg"
        for placement in ("delta", "release-notes", "link", "duplicate-url"):
            with self.subTest(placement=placement):
                root = ET.fromstring(feed()); item = root.find("channel/item")
                if placement in ("delta", "duplicate-url"):
                    ET.SubElement(ET.SubElement(item, self.tool.SPARKLE + "deltas"), "enclosure",
                                  url=expected_url if placement == "duplicate-url" else "https://fixture/other.delta")
                else:
                    ET.SubElement(item, self.tool.SPARKLE + "releaseNotesLink" if placement == "release-notes" else "link").text = "https://fixture/other"
                self.state = dict(json.loads(json.dumps(original)), new_feed=ET.tostring(root, encoding="unicode"))
                result = self.run_appcast_generation()
                self.assertEqual(result.returncode, 1, "the new item must contain only the generator's one-archive elements")
                self.assertIn("unexpected generated appcast item element", result.stderr)

    def test_generated_item_checks_urls_in_all_text(self):
        original = json.loads(json.dumps(self.state))
        for placement in ("title", "item-text", "tail"):
            with self.subTest(placement=placement):
                root = ET.fromstring(feed()); item = root.find("channel/item")
                if placement == "title": item.find("title").text = "https://fixture/other"
                elif placement == "item-text": item.text = "https://fixture/other"
                else: item.find("enclosure").tail = "https://fixture/other"
                self.state = dict(json.loads(json.dumps(original)), new_feed=ET.tostring(root, encoding="unicode"))
                result = self.run_appcast_generation()
                self.assertEqual(result.returncode, 1, "every URL in the new item must name this run's DMG")
                self.assertIn("generated appcast item contains another URL", result.stderr)

    def test_whole_feed_provenance_preserves_base_urls(self):
        root = ET.fromstring(feed("0.9.0"))
        for url in ("https://trusted/old.zip", "https://trusted/old.DMG", "https://trusted/old.dmg;x", "https://trusted/archive/"):
            ET.SubElement(root.find("channel"), "metadata", url=url)
        delta = ET.SubElement(root.find("channel/item"), self.tool.SPARKLE + "deltas")
        ET.SubElement(delta, "enclosure", url="https://trusted/old.delta")
        root.set(self.tool.SPARKLE + "url", "https://trusted/namespace-url")
        self.state["appcast"] = ET.tostring(root, encoding="unicode")
        root.find("channel").append(ET.fromstring(feed()).find("channel/item"))
        self.state["new_feed"] = ET.tostring(root, encoding="unicode")
        result = self.run_appcast_generation()
        self.assertEqual(result.returncode, 0, "all previously published URLs remain trusted: " + result.stderr)
        self.assertEqual(self.state["signing_inputs"], [["Pensieve-1.0.0.dmg"]])

    def test_provenance_requires_unchanged_base_content(self):
        original = json.loads(json.dumps(self.state))
        delta_url = "https://trusted/old.delta"
        base = ET.fromstring(feed("0.9.0"))
        ET.SubElement(ET.SubElement(base.find("channel/item"), self.tool.SPARKLE + "deltas"), "enclosure", url=delta_url)
        for mutation in ("length", "signature", "title", "notes", "link", "delta-promotion", "second-item", "channel-notes", "root-element", "channel-text"):
            with self.subTest(mutation=mutation):
                root = ET.fromstring(ET.tostring(base)); old = root.find("channel/item")
                root.find("channel").append(ET.fromstring(feed()).find("channel/item"))
                if mutation == "length": old.find("enclosure").set("length", "16")
                elif mutation == "signature": old.find("enclosure").set(self.tool.SPARKLE + "edSignature", base64.b64encode(b"t" * 64).decode())
                elif mutation == "title": ET.SubElement(old, "title").text = "rewritten"
                elif mutation in ("notes", "link"):
                    ET.SubElement(old, self.tool.SPARKLE + "releaseNotesLink" if mutation == "notes" else "link").text = "https://untrusted/notes"
                elif mutation == "delta-promotion": old.find("enclosure").set("url", delta_url)
                elif mutation == "second-item":
                    added = ET.fromstring(ET.tostring(old)); added.find(self.tool.SPARKLE + "shortVersionString").text = "0.8.0"
                    root.find("channel").append(added)
                elif mutation == "channel-notes": ET.SubElement(root.find("channel"), "link").text = "https://untrusted/notes"
                elif mutation == "root-element": ET.SubElement(root, "unexpected").text = "new content"
                else: root.find("channel").text = "new channel text"
                self.state = json.loads(json.dumps(original)); self.state["appcast"] = ET.tostring(base, encoding="unicode")
                self.state["new_feed"] = ET.tostring(root, encoding="unicode")
                result = self.run_appcast_generation()
                self.assertEqual(result.returncode, 1, "generation must preserve every carried item and channel field")
                self.assertIn("channel or feed metadata" if mutation in ("channel-notes", "root-element", "channel-text") else "another item", result.stderr)

    def test_provenance_allows_canonical_reordering_and_pruning(self):
        base = ET.fromstring(feeds("0.9.0", "1.0.0-alpha.1"))
        ET.SubElement(base.find("channel/item"), "description").text = "  meaningful text\nwith spacing  "
        self.state["appcast"] = ET.tostring(base, encoding="unicode")
        for prune in (False, True):
            with self.subTest(prune=prune):
                root = ET.fromstring(ET.tostring(base)); channel = root.find("channel")
                items = channel.findall("item")
                for item in items: channel.remove(item)
                for item in reversed(items[1:] if prune else items): channel.append(item)
                channel.insert(0, ET.fromstring(feed()).find("channel/item"))
                for element in root.iter():
                    element.attrib = dict(reversed(list(element.attrib.items())))
                ET.indent(root, space="  ")
                self.state["new_feed"] = ET.tostring(root, encoding="unicode")
                result = self.run_appcast_generation()
                self.assertEqual(result.returncode, 0, "formatting, attribute order and base-item reordering/pruning add no trust: " + result.stderr)

    def test_provenance_requires_a_new_publication_item(self):
        source = self.root / "generated.xml"; base = self.root / "base.xml"
        source.write_text(feed()); base.write_text(feed())
        result = subprocess.run(["/bin/bash", str(self.root / "script/release.sh"), "--verify-appcast", str(source),
                                 str(base), f"Pensieve-{VERSION}.dmg", DOWNLOAD_PREFIX, VERSION, "26.0"],
                                env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 1, "generation must add exactly one new publication item")
        self.assertIn("publication version already exists in base", result.stderr)

    def test_preflight_owns_base_outside_signing_folder(self):
        result = self.run_function('''release_preflight
printf 'SNAPSHOT=%s\n' "${APPCAST_BASE:-}"
if [ -n "${APPCAST_BASE:-}" ]; then
  cat "$APPCAST_BASE" > "$REPO/preflight-snapshot.xml"
  printf poisoned > "$APPCAST_INPUT_DIR/appcast.xml"
  DMG_PATH="$DIST_DIR/Pensieve-$VERSION.dmg"
  printf 'fresh built DMG' > "$DMG_PATH"
  prepare_appcast_inputs
  cat "$APPCAST_INPUT_DIR/appcast.xml" > "$REPO/prepared-base.xml"
fi''')
        self.assertEqual(result.returncode, 0, result.stderr)
        path = result.stdout.split("SNAPSHOT=", 1)[1].splitlines()[0]
        self.assertTrue(path, "preflight must own a decoded base before preparation runs")
        self.assertNotEqual(Path(path).parent, self.root / "build/dist/appcast-input")
        self.assertEqual((self.root / "preflight-snapshot.xml").read_text(), self.state["appcast"])
        self.assertEqual((self.root / "prepared-base.xml").read_text(), self.state["appcast"], "preparation must copy the preflight base, not trust its mutable signing copy")
        self.assertFalse(Path(path).exists(), "the preflight snapshot must be cleaned when the shell exits")

    def test_appcast_base_is_cleaned_on_success_and_failure(self):
        original = json.loads(json.dumps(self.state))
        for failure in (False, True):
            with self.subTest(failure=failure):
                self.state = json.loads(json.dumps(original))
                if failure: self.state["new_feed"] = "not XML"
                self.run_release(expected=1 if failure else 0)
                self.assertEqual(list((self.root / "build/dist").glob("appcast-base.*")), [], "a successful or refused publish must clean its base snapshot")

    def test_provenance_refuses_base_read_and_parse_errors(self):
        source = self.root / "generated.xml"; source.write_text(feed())
        base = self.root / "unreadable-base.xml"
        def inspect(base_argument):
            return subprocess.run(["/bin/bash", str(self.root / "script/release.sh"), "--verify-appcast", str(source),
                                   base_argument, "Pensieve-1.0.0.dmg", DOWNLOAD_PREFIX, VERSION, "26.0"],
                                  env=self.env, text=True, capture_output=True, timeout=30)
        self.assertEqual(inspect("").returncode, 0, "an explicitly absent base is the first-release path")
        self.assertEqual(inspect(str(base)).returncode, 1, "a named but missing base is unknown")
        base.mkdir()
        self.assertEqual(inspect(str(base)).returncode, 1, "a base read error must refuse")
        base.rmdir()
        for text in ("", "not XML", '<!DOCTYPE rss><rss><channel/></rss>'):
            with self.subTest(malformed_base=text):
                base.write_text(text)
                self.assertEqual(inspect(str(base)).returncode, 1, "a malformed base must refuse")
        base.write_text(feed("0.9.0")); base.chmod(0)
        try: self.assertEqual(inspect(str(base)).returncode, 1, "an unreadable base must refuse")
        finally: base.chmod(0o600)

    def test_cask_policy_uses_cached_prerelease_predicate(self):
        result = self.run_function('VERSION=1.0.0-beta.1; VERSION_CHANNEL=beta; cask_action_for() { printf "bump\\n"; return 9; }; cask_preflight; cask_publication_status; report_cask_publication; printf "%s %s\\n" "$CASK_PREFLIGHT" "$CASK_STATUS"')
        self.assertEqual(result.returncode, 0, "publication must use the predicate independently of the action printer")
        self.assertIn("cask skipped for prerelease", result.stdout)
        self.assertIn("1 skip", result.stdout)
        self.assertNotIn("cask step runs next", result.stdout)
        self.assertEqual(self.state["calls"], [], "cached prerelease policy must skip the tap")

    def test_cask_render_uses_the_verified_digest(self):
        import hashlib
        self.run_release()
        digest = hashlib.sha256(DMG).hexdigest()
        hasher = self.root / "bin/shasum"; reads = self.root / "digest-read"
        hasher.write_text('#!/bin/bash\nif [ -e "' + str(reads) + '" ]; then echo "second digest read refused" >&2; exit 1; fi\ntouch "' + str(reads) + '"\nexec /usr/bin/shasum "$@"\n')
        hasher.chmod(0o755)
        self.run_release(cask_only=True)
        self.assertIn('sha256 "' + digest + '"', self.state["cask"], "the rendered cask must use the digest already verified in this run")
        self.assertEqual(self.state["writes"], ["create", "appcast", "cask"])

    def test_cask_status_is_separate_from_reporting(self):
        result = self.run_function('VERSION=1.0.0-beta.1; VERSION_CHANNEL=beta; report_cask_publication() { echo unexpected-report >&2; return 9; }; cask_publication_status; printf "%s\\n" "$CASK_STATUS"')
        self.assertEqual(result.returncode, 0, "status must not depend on the cue reporter")
        self.assertEqual(result.stdout, "skip\n")
        self.assertEqual(result.stderr, "", "status must not print the publication cue")

    def test_validated_publication_branch_logs_do_not_escape(self):
        (self.root / "build/dist").mkdir(parents=True)
        (self.root / "build/dist/appcast.xml").write_text(feed())
        result = self.run_function('PUBLIC_BRANCH=master; APPCAST_PREFLIGHT=1; APPCAST_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; log_text() { echo validated-value-went-to-formatter >&2; return 9; }; publish_appcast')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("validated-value-went-to-formatter", result.stderr, "validated branch logging must not invoke the parsed-text formatter")
        self.assertIn("publish appcast.xml to jaredatch/pensieve master", result.stdout)

    def test_command_seam_streams_before_exit(self):
        command = self.root / "live.py"; gate = self.root / "finish-command"
        command.write_text('import pathlib, sys, time\nsys.stdout.write("live stdout\\n"); sys.stdout.flush()\nsys.stderr.write("live stderr\\n"); sys.stderr.flush()\nwhile not pathlib.Path(sys.argv[1]).exists(): time.sleep(0.01)\nsys.exit(7)\n')
        process = subprocess.Popen(["/bin/bash", "-c", 'source "$1" --inspect-functions; run_command_seam python3 "$2" "$3"',
                                    "release-test", str(self.root / "script/release.sh"), str(command), str(gate)],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        seen = {}; deadline = time.monotonic() + 60
        try:
            while len(seen) < 2 and time.monotonic() < deadline:
                ready, _, _ = select.select([pipe for pipe in (process.stdout, process.stderr) if pipe not in seen], [], [], max(0, deadline - time.monotonic()))
                for pipe in ready: seen[pipe] = pipe.readline()
            self.assertEqual(seen.get(process.stdout), b"live stdout\n", "stdout must stream before the test releases the command")
            self.assertEqual(seen.get(process.stderr), b"live stderr\n", "stderr must stream before the test releases the command")
            self.assertIsNone(process.poll(), "the command must still be waiting when both live lines arrive")
        finally:
            gate.touch()
            process.communicate(timeout=60)
        self.assertEqual(process.returncode, 7)

    def test_command_seam_preserves_status_without_log_formatter(self):
        result = self.run_function("log_response() { return 9; }; run_command_seam /bin/bash -c 'echo live >&2; exit 7'")
        self.assertEqual(result.returncode, 7, "a log formatter must never hide the real command status")
        self.assertEqual(result.stderr, "live\n", "tool diagnostics must retain their live output")

    def test_recovery_cask_cue_cannot_fail_after_verification(self):
        original = json.loads(json.dumps(self.state)); template = self.root / "release/homebrew/pensieve.rb"
        original_template = template.read_text()
        for failure in ("template", "digest"):
            with self.subTest(failure=failure):
                self.state = json.loads(json.dumps(original))
                self.state.update(appcast=feed(), release=self.state["expected_release"])
                template.write_text("def broken(" if failure == "template" else original_template)
                if failure == "digest": self.state["cask"] = cask(VERSION)
                output = self.run_release()
                self.assertIn("cask step runs next", output)
                self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)
                self.assertFalse((self.root / "build/dist/homebrew/pensieve.rb").exists(), "recovery reporting must not render a cask")
                self.assertIn("rewrite-cask" if failure == "template" else "sha256", self.run_release(cask_only=True, expected=1))

    def test_prerelease_cue_skips_cask_on_fresh_and_recovered_paths(self):
        self.set_version("1.0.0-beta.1")
        for output in (self.run_release(), self.run_release(), self.run_release(cask_only=True)):
            self.assertIn("cask skipped for prerelease", output)
            self.assertNotIn("cask step runs next", output)
        self.assertFalse(any("pensieve.rb" in arg for call in self.state["calls"] for arg in call))

    def test_appcast_provenance_refuses_missing_or_unreadable_file(self):
        source = self.root / "missing.xml"; base = self.root / "base.xml"; base.write_text(feed("0.9.0"))
        for unreadable in (False, True):
            with self.subTest(unreadable=unreadable):
                if unreadable: source.write_text(feed()); source.chmod(0)
                try:
                    result = subprocess.run(["/bin/bash", str(self.root / "script/release.sh"), "--verify-appcast", str(source), str(base), "Pensieve-1.0.0.dmg", DOWNLOAD_PREFIX, VERSION, "26.0"], env=self.env, text=True, capture_output=True, timeout=30)
                    self.assertEqual(result.returncode, 1, "a missing or unreadable appcast must refuse provenance verification")
                    self.assertIn("invalid 'provenance' state", result.stderr)
                finally:
                    if unreadable: source.chmod(0o600)


class PublishedTextSweepTests(unittest.TestCase):
    tool = STATE_TOOL


    def test_publication_channel_matches_literal_policy(self):
        for version, (channel, prerelease) in PUBLICATION_CASES.items():
            with self.subTest(version=version):
                self.assertEqual(self.tool.publication_channel(version), channel, "channel must match the independent release policy")
                self.assertEqual(bool(channel), prerelease)

    def test_refusal_diagnostics_escape_swept_inputs(self):
        with tempfile.TemporaryDirectory(prefix="pensieve-refusals-") as directory:
            root = Path(directory); source = root / "source"; output = root / "output"
            for poison in POISON_TEXTS:
                cases = []
                # Exercise every refusing count in the cask and appcast sweeps.
                for versions, hashes in itertools.product((0, 1, 2), repeat=2):
                    if versions == hashes == 1: continue
                    text = '\n'.join(['cask "pensieve" do'] + ['  version "0.9.0"'] * versions + ['  sha256 :no_check'] * hashes + ['end', '# ' + poison])
                    cases += [("cask", [str(source)], text), ("rewrite-cask", [str(source), str(output), VERSION, "a" * 64], text)]
                invalid = feed().replace('>1.0.0<', '>' + poison + '<')
                cases.append(("appcast", [str(source), VERSION, DOWNLOAD_PREFIX], invalid))
                for invalid in (feed() + feed(), feeds(VERSION, VERSION), feed().replace('<enclosure', '<other'), feed().replace('length="15"', 'length="bad"'), feed().replace(SIGNATURE, 'bad'), feed().replace('v1.0.0/', 'v9.0.0/'), cask() + 'def broken(\n', cask().replace('"0.9.0"', '"bad"'), cask().replace('"' + '0' * 64 + '"', '"bad"')):
                    mode = "appcast" if invalid.startswith('<') else "cask"
                    args = [str(source), VERSION, DOWNLOAD_PREFIX] if mode == "appcast" else [str(source)]
                    cases.append((mode, args, invalid + ('<!--' + poison + '-->' if mode == "appcast" else '\n# ' + poison)))
                for sha in ("", "g" * 40, "a" * 39, None, 1, poison):
                    response = 'HTTP/2.0 200 OK\n\n' + json.dumps(dict(sha=sha, encoding="base64", content=base64.b64encode(poison.encode()).decode()))
                    cases += [("contents-sha", [str(source)], response), ("contents", [str(source), str(output)], response)]
                duplicated = ET.fromstring(feed())
                item = duplicated.find("channel/item")
                item.append(ET.fromstring(ET.tostring(item.find("enclosure"))))
                cases.append(("appcast", [str(source), VERSION, DOWNLOAD_PREFIX], ET.tostring(duplicated, encoding="unicode") + "<!--" + poison + "-->"))
                for invalid in ("1.0", "01.0.0", "1.0.0-alpha..1", "1.0.0-beta.01"):
                    cases.append(("appcast", [str(source), VERSION, DOWNLOAD_PREFIX], feed().replace('>1.0.0<', '>' + invalid + '<') + "<!--" + poison + "-->"))
                cases.append(("appcast", [str(source), VERSION, DOWNLOAD_PREFIX], '<rss><channel><!DOCTYPE ' + poison + '></channel></rss>'))
                cases.append(("tag", [str(source)], 'HTTP/2.0 200 OK\n\n' + json.dumps({"object": {poison: "bad"}})))
                for mode, args, text in cases:
                    with self.subTest(poison=poison, mode=mode, text=text):
                        if text is not None: source.write_text(text)
                        result = subprocess.run(["python3", str(ROOT / "script/release_state.py"), mode, *args], text=True, capture_output=True, timeout=15)
                        self.assertEqual(result.returncode, 1, "the diagnostic guard must reach a refusal: " + result.stdout)
                        self.assertTrue(result.stderr)
                        assert_safe_diagnostic(self, result.stderr)

    def test_parsed_diagnostics_escape_once(self):
        with tempfile.TemporaryDirectory(prefix="pensieve-once-") as directory:
            source = Path(directory) / "appcast.xml"
            # XML rejects ESC before version parsing; the refusal sweep covers it.
            cases = (("x\n::error::fixture", r"'invalid publication version: x\n::error::fixture'"),
                     ("x\t::error::fixture", r"'invalid publication version: x\t::error::fixture'"),
                     ("x\u0085::warning::fixture", r"'invalid publication version: x\x85::warning::fixture'"),
                     ("##[error]fixture", r"'invalid publication version: \x23\x23[error]fixture'"))
            for poison, escaped in cases:
                with self.subTest(poison=poison):
                    source.write_text(feed().replace('>1.0.0<', '>' + poison + '<'))
                    result = subprocess.run(["python3", str(ROOT / "script/release_state.py"), "appcast", str(source), VERSION, DOWNLOAD_PREFIX], text=True, capture_output=True, timeout=15)
                    self.assertEqual(result.returncode, 1)
                    expected = "release: invalid 'appcast' state: " + escaped + "\n"
                    self.assertEqual(result.stderr, expected, "parsed text must be escaped exactly once at the outer handler")
                    assert_safe_diagnostic(self, result.stderr)

    def test_version_order_cross_product(self):
        ordered = ("0.9.0", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
                   "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.1.0", "1.9.0", "1.10.0", "2.0.0", "10.0.0")
        for (i, left), (j, right) in itertools.product(enumerate(ordered), repeat=2):
            with self.subTest(left=left, right=right):
                self.assertEqual(self.tool.compare_versions(left, right), (i > j) - (i < j))
        for invalid in ("1.0", "01.0.0", "1.0.0-alpha..1", "1.0.0-beta.01"):
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError): self.tool.compare_versions(invalid, VERSION)

    def test_cask_shape_cross_product_and_fixed_point(self):
        count = 0
        for ending, trailing, versions, hashes in itertools.product(("\n", "\r\n"), (False, True), (0, 1, 2), (0, 1, 2)):
            text = ending.join(['cask "pensieve" do'] + ['  version "0.9.0"'] * versions + ['  sha256 :no_check'] * hashes + ['end']) + (ending if trailing else "")
            with self.subTest(ending=ending, trailing=trailing, versions=versions, hashes=hashes):
                if versions != 1 or hashes != 1:
                    with self.assertRaises(ValueError): self.tool.rewrite_cask(text, VERSION, "a" * 64)
                    with self.assertRaises(ValueError): self.tool.cask_state(text)
                else:
                    rewritten = self.tool.rewrite_cask(text, VERSION, "a" * 64)
                    self.assertEqual(self.tool.cask_state(rewritten), VERSION + " " + "a" * 64)
                    self.assertEqual(rewritten, self.tool.rewrite_cask(rewritten, VERSION, "a" * 64))
                    self.assertEqual(rewritten.endswith(ending), trailing)
                    self.assertEqual(rewritten.count(ending), text.count(ending))
            count += 1
        self.assertEqual(count, 36)
        with self.assertRaises(ValueError): self.tool.cask_state("")
        for malformed in (cask().replace('"0.9.0"', '"unparseable"'), cask().replace('"' + "0" * 64 + '"', '"oops"')):
            with self.assertRaises(ValueError): self.tool.cask_state(malformed)

    def test_appcast_shape_cross_product(self):
        count = 0
        for ending, trailing, items, other in itertools.product(("\n", "\r\n"), (False, True), (0, 1, 2), (False, True)):
            item = feed().split("<channel>")[1].split("</channel>")[0]
            old = feed("0.9.0").split("<channel>")[1].split("</channel>")[0] if other else ""
            text = feed().split("<channel>")[0] + "<channel>" + ending + (item + ending) * items + old + "</channel></rss>" + (ending if trailing else "")
            with self.subTest(ending=ending, trailing=trailing, items=items, other=other):
                if items == 2:
                    with self.assertRaises(ValueError): self.tool.appcast_publication_state(self.tool.appcast_root(text), VERSION, DOWNLOAD_PREFIX)
                else:
                    expected = "absent" if items == 0 else str(len(DMG)) + " " + SIGNATURE
                    self.assertEqual(self.tool.appcast_publication_state(self.tool.appcast_root(text), VERSION, DOWNLOAD_PREFIX), (expected, "absent"))
            count += 1
        self.assertEqual(count, 24)
        # Two enclosures must be refused whichever one would be trusted first.
        for ending, trailing, position in itertools.product(("\n", "\r\n"), (False, True), ("before", "after")):
            root = ET.fromstring(feed())
            item = root.find("channel/item")
            duplicate = ET.fromstring(ET.tostring(item.find("enclosure")))
            duplicate.set("length", "16")
            item.insert(1 if position == "before" else len(item), duplicate)
            text = ET.tostring(root, encoding="unicode").replace("><", ">" + ending + "<") + (ending if trailing else "")
            with self.subTest(ending=ending, trailing=trailing, duplicate_enclosure=position):
                with self.assertRaisesRegex(ValueError, "duplicated appcast enclosure"):
                    self.tool.appcast_publication_state(self.tool.appcast_root(text), VERSION, DOWNLOAD_PREFIX)
        for invalid in ("", feed().replace("<enclosure", "<other"), feed().replace('length="15"', 'length="bad"'), feed().replace(SIGNATURE, "bad"), feed().replace("v1.0.0/", "v9.0.0/")):
            with self.assertRaises((ValueError, ET.ParseError)): self.tool.appcast_publication_state(self.tool.appcast_root(invalid), VERSION, DOWNLOAD_PREFIX)

    def test_appcast_publication_channels(self):
        for version in (VERSION, "1.0.0-beta.2"):
            for published, channel in (("1.1.0", ""), ("1.1.0-beta.1", "beta"), ("1.1.0-alpha.1", "alpha")):
                with self.subTest(version=version, published=published, channel=channel):
                    text = feed(version).replace("</channel>", "<item>" + feed(published, channel=channel).split("<item>")[1].split("</item>")[0] + "</item>" + "</channel>")
                    visible = channel == "" or (version != VERSION and channel == "beta")
                    expected = (str(len(DMG)) + " " + SIGNATURE, published if visible else "absent")
                    self.assertEqual(self.tool.appcast_publication_state(self.tool.appcast_root(text), version, DOWNLOAD_PREFIX), expected)

    def test_contents_sha_validation_and_decode(self):
        with tempfile.TemporaryDirectory(prefix="pensieve-contents-") as directory:
            response, output = Path(directory) / "response", Path(directory) / "output"
            for sha in (SHA, "", "g" * 40, "a" * 39, None, 1):
                value = dict(sha=sha, encoding="base64", content=base64.b64encode(b"fixture bytes").decode())
                response.write_text("HTTP/2.0 200 OK\n\n" + json.dumps(value))
                for mode in ("contents-sha", "contents"):
                    with self.subTest(sha=sha, mode=mode):
                        error = None
                        try:
                            result = self.tool.contents_sha(response) if mode == "contents-sha" else self.tool.contents(response, output)
                        except Exception as caught:
                            error = caught
                        if sha == SHA:
                            self.assertIsNone(error); self.assertEqual(result, SHA)
                            if mode == "contents": self.assertEqual(output.read_bytes(), b"fixture bytes")
                        else:
                            self.assertIsInstance(error, ValueError, "unknown contents SHA must be refused normally")
                            self.assertEqual(str(error), "contents response has no valid SHA")

    def test_missing_ruby_names_required_interpreter(self):
        with mock.patch.object(self.tool.subprocess, "run", side_effect=FileNotFoundError(2, "No such file or directory")) as launch:
            with self.assertRaisesRegex(Exception, r"required interpreter /usr/bin/ruby is missing") as missing:
                self.tool.cask_state(cask())
        self.assertIsInstance(missing.exception, ValueError)
        self.assertEqual(launch.call_args.args[0][0], "/usr/bin/ruby")


if __name__ == "__main__":
    unittest.main()
