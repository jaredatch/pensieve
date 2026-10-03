#!/usr/bin/env python3
"""Exercise release.sh in an isolated checkout; all external commands are stubs."""
import base64
import importlib.util
import itertools
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
VERSION = "1.0.0"
SHA = "a" * 40
DMG = b"fresh built DMG"
SIGNATURE = base64.b64encode(b"s" * 64).decode()


def feed(version=VERSION, signature=SIGNATURE, length=len(DMG)):
    return (f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
            f'<channel><item><sparkle:shortVersionString>{version}</sparkle:shortVersionString>'
            f'<enclosure url="https://github.com/jaredatch/pensieve/releases/download/v{version}/'
            f'Pensieve-{version}.dmg" length="{length}" sparkle:edSignature="{signature}"/>'
            '</item></channel></rss>')


def cask(version="0.9.0", sha="0" * 64):
    return f'cask "pensieve" do\n  version "{version}"\n  sha256 "{sha}"\nend\n'


# The stub only handles the command shapes used by production. An unexpected
# call fails rather than reaching a real network, compiler, or signing service.
STUB = r'''#!/usr/bin/env python3
import base64, json, os, pathlib, sys
p = pathlib.Path(os.environ["RELEASE_TEST_STATE"])
s = json.loads(p.read_text())
cmd, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
def save(): p.write_text(json.dumps(s))
def fail(message):
    print(message, file=sys.stderr); save(); sys.exit(1)
s["calls"].append([cmd] + args)
save()
if cmd == "gh":
    if args[0] == "api":
        path = next(a for a in args if a.startswith("repos/"))
        method = args[args.index("-X") + 1] if "-X" in args else "GET"
        kind = "appcast" if "appcast.xml" in path else "cask" if "pensieve.rb" in path else "release" if "/releases/tags/" in path else "tag" if "/git/ref/" in path else "repo"
        if method == "PUT":
            fields = dict(a.split("=", 1) for i, a in enumerate(args) if i and args[i-1] == "-f")
            if s.get("race") == kind:
                s[kind] = s.get("race_content", s[kind]); s[kind + "_sha"] = "b" * 40
                print('HTTP/2.0 409 Conflict\n\n{}'); fail("lost write race")
            if fields.get("sha", "") != s[kind + "_sha"]: fail("unguarded PUT")
            s[kind] = base64.b64decode(fields["content"]).decode()
            s[kind + "_sha"] = "b" * 40
            s["writes"].append(kind); save()
            print('HTTP/2.0 200 OK\n\n{}'); sys.exit(0)
        if s.get("fail_read") == kind:
            print('HTTP/2.0 503 Failed\n\n{}'); fail("failed " + kind + " read")
        if s.get("malformed") == kind:
            print('HTTP/2.0 200 OK\n\n{"bad":'); sys.exit(0)
        if kind == "repo": print("master"); sys.exit(0)
        if kind == "tag": value = {"object": {"type": "commit", "sha": s.get("target", "a" * 40)}}
        elif kind == "release": value = s["release"]
        else:
            value = None if s[kind] is None else {"sha": s[kind + "_sha"], "encoding": "base64", "content": base64.b64encode(s[kind].encode()).decode()}
        if value is None:
            print('HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}'); sys.exit(1)
        print('HTTP/2.0 200 OK\n\n' + json.dumps(value)); sys.exit(0)
    if args[:2] == ["release", "create"]:
        if s["release"] is not None: fail("second release creation")
        s["release"] = s["expected_release"]; s["asset"] = pathlib.Path(next(a for a in args if a.endswith(".dmg"))).read_text()
        s["writes"].append("create"); save(); sys.exit(0)
    if args[:2] == ["release", "upload"]:
        if "--clobber" not in args: fail("no replacement requested")
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
    for name in ["MacOS/pensieve-daemon", "Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/file", "Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/file", "Frameworks/Sparkle.framework/Versions/B/Autoupdate", "Frameworks/Sparkle.framework/Versions/B/Updater.app/file"]:
        f = dest / "Contents" / name; f.parent.mkdir(parents=True, exist_ok=True); f.write_text("built")
    (dest / "Contents/Info.plist").write_text('<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>' + s["version"] + '</string></dict></plist>')
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
        pathlib.Path(args[-1]).write_text("fresh built DMG"); save()
    elif args[0] == "attach":
        (pathlib.Path(args[args.index("-mountpoint") + 1]) / "Pensieve.app").mkdir()
    elif args[0] == "detach":
        import shutil; shutil.rmtree(pathlib.Path(args[1]) / "Pensieve.app")
    else: fail("unexpected hdiutil")
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


class ReleaseSequenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pensieve-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "script").mkdir()
        for name in ("release.sh", "release_recovery.sh", "package.sh", "build-number.sh", "release_state.py", "verify_update.swift"):
            if (ROOT / "script" / name).exists(): shutil.copy2(ROOT / "script" / name, self.root / "script" / name)
        shutil.copytree(ROOT / "release/homebrew", self.root / "release/homebrew")
        shutil.copytree(ROOT / "Pensieve", self.root / "Pensieve", ignore=shutil.ignore_patterns("*.swift", "Resources"))
        (self.root / "VERSION").write_text(VERSION)
        (self.root / "BUILD_NUMBER_OFFSET").write_text("00")
        (self.root / "project.yml").write_text('MARKETING_VERSION: "1.0.0"\n')
        (self.root / "CHANGELOG.md").write_text("## [1.0.0]\nRelease fixture.\n")
        (self.root / "fixture-key").write_text("not a signing key")
        bin_dir = self.root / "bin"; bin_dir.mkdir()
        for name in ("gh", "git", "xcodegen", "xcodebuild", "codesign", "ditto", "hdiutil", "spctl", "notary", "stapler", "generate", "verify"):
            f = bin_dir / name; f.write_text(STUB); f.chmod(0o755)
        self.state_path = self.root / "state.json"
        release = {"id": 1, "tag_name": "v" + VERSION, "draft": False, "prerelease": False,
                   "assets": [{"id": 2, "name": "Pensieve-1.0.0.dmg", "size": len(DMG), "state": "uploaded"}]}
        self.state = dict(version=VERSION, release=None, expected_release=release, asset=DMG.decode(),
                          appcast=feed("0.9.0"), cask=cask(), appcast_sha=SHA, cask_sha=SHA,
                          calls=[], writes=[], builds=0, signing_inputs=[], new_feed=feed(), signature=SIGNATURE)
        self.env = dict(os.environ, PATH=str(bin_dir) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        RELEASE_TEST_STATE=str(self.state_path), GH_CMD=str(bin_dir / "gh"),
                        NOTARY_CMD=str(bin_dir / "notary"), STAPLER_CMD=str(bin_dir / "stapler"),
                        GENERATE_APPCAST_CMD=str(bin_dir / "generate"), VERIFY_UPDATE_CMD=str(bin_dir / "verify"),
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
        result = subprocess.run(args, env=self.env, text=True, capture_output=True, timeout=30)
        self.state = json.loads(self.state_path.read_text())
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_fresh_release_and_second_run(self):
        self.run_release(); self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], ["create", "appcast", "cask"])
        self.assertEqual(self.state["builds"], 1)
        self.assertEqual(self.state["signing_inputs"], [["Pensieve-1.0.0.dmg"]])
        self.run_release(); self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], ["create", "appcast", "cask"])
        self.assertEqual(self.state["builds"], 1)

    def test_release_exists_rebuilds_and_replaces_before_signing_feed(self):
        self.state["release"] = self.state["expected_release"]
        self.state["asset"] = "old unpublished bytes"
        self.run_release(); self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], ["replace", "appcast", "cask"])
        self.assertEqual(self.state["asset"], DMG.decode())
        self.assertEqual(self.state["signing_inputs"], [["Pensieve-1.0.0.dmg"]])
        self.assertFalse(any(c[:2] == ["gh", "release"] and c[2] == "download" for c in self.state["calls"]))

    def test_live_appcast_verifies_without_rebuild_or_asset_write(self):
        self.state.update(release=self.state["expected_release"], appcast=feed())
        self.run_release(); self.run_release(cask_only=True)
        self.assertEqual(self.state["builds"], 0)
        self.assertEqual(self.state["writes"], ["cask"])
        self.assertEqual(self.state["signing_inputs"], [])
        self.assertTrue(any(c[0] == "verify" for c in self.state["calls"]))

    def test_bad_release_shapes_stop_before_any_changes(self):
        for change in ({"draft": True}, {"assets": []}, {"assets": self.state["expected_release"]["assets"] * 2}, {"tag_name": "v9.0.0"}, {"prerelease": True}, {"assets": [{"name": "extra"}]}):
            with self.subTest(change=change):
                self.state["release"] = dict(self.state["expected_release"], **change)
                output = self.run_release(expected=1)
                self.assertIn("release", output)
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
        self.assertIn("sha256", self.run_release(expected=1))
        self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)

    def test_valid_developer_id_does_not_replace_eddsa_verification(self):
        self.state.update(release=self.state["expected_release"], appcast=feed(), asset="other bytes")
        self.assertIn("EdDSA", self.run_release(expected=1))
        self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)

    def test_real_public_key_verification_accepts_only_matching_bytes(self):
        generator = self.root / "fixture-signature.swift"
        generator.write_text('import CryptoKit\nimport Foundation\nlet key = Curve25519.Signing.PrivateKey()\nlet data = Data("fresh built DMG".utf8)\nprint(key.publicKey.rawRepresentation.base64EncodedString())\nprint(try key.signature(for: data).base64EncodedString())\n')
        keys = subprocess.run(["/usr/bin/swift", str(generator)], capture_output=True, text=True, timeout=30)
        self.assertEqual(keys.returncode, 0, keys.stderr)
        public, signature = keys.stdout.splitlines()
        plist = self.root / "Pensieve/Info.plist"
        plist.write_text(plist.read_text().replace("HibOcVcc/1MTA9UQHp4cIb7qMewKaA0elSCSQ0DY8Ns=", public))
        self.env["VERIFY_UPDATE_CMD"] = "/usr/bin/swift " + str(self.root / "script/verify_update.swift")
        self.state.update(release=self.state["expected_release"], appcast=feed(signature=signature))
        self.run_release()
        self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)
        for bad in ("wrong built DMG", "short"):
            self.state["asset"] = bad
            self.assertIn("does not match appcast", self.run_release(expected=1))
            self.assertEqual(self.state["writes"], []); self.assertEqual(self.state["builds"], 0)

    def test_failed_and_malformed_reads_are_unknown(self):
        original = json.loads(json.dumps(self.state))
        for mode, kind in itertools.product(("fail_read", "malformed"), ("release", "appcast", "cask", "tag")):
            with self.subTest(mode=mode, kind=kind):
                self.state = json.loads(json.dumps(original))
                self.state[mode] = kind
                self.assertIn(kind, self.run_release(expected=1))
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
        import hashlib
        self.run_release()
        self.state.update(race="cask", race_content=cask(VERSION, hashlib.sha256(DMG).hexdigest()))
        self.assertIn("409", self.run_release(cask_only=True, expected=1))
        self.state.pop("race")
        self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], ["create", "appcast"])

    def test_prerelease_recovery_skips_cask(self):
        version = "1.0.0-beta.1"
        self.state.update(version=version, appcast=feed(version), release=dict(self.state["expected_release"], tag_name="v" + version, prerelease=True, assets=[{"id": 2, "name": "Pensieve-" + version + ".dmg", "size": len(DMG), "state": "uploaded"}]))
        (self.root / "VERSION").write_text(version)
        self.run_release(); self.run_release(cask_only=True)
        self.assertEqual(self.state["writes"], [])

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


class PublishedTextSweepTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("release_state", ROOT / "script/release_state.py")
        cls.tool = importlib.util.module_from_spec(spec); spec.loader.exec_module(cls.tool)

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

    def test_appcast_shape_cross_product_and_repeat_comparison(self):
        count = 0
        for ending, trailing, items, other in itertools.product(("\n", "\r\n"), (False, True), (0, 1, 2), (False, True)):
            item = feed().split("<channel>")[1].split("</channel>")[0]
            old = feed("0.9.0").split("<channel>")[1].split("</channel>")[0] if other else ""
            text = feed().split("<channel>")[0] + "<channel>" + ending + (item + ending) * items + old + "</channel></rss>" + (ending if trailing else "")
            with self.subTest(ending=ending, trailing=trailing, items=items, other=other):
                if items == 2:
                    with self.assertRaises(ValueError): self.tool.appcast_state(text, VERSION)
                else:
                    expected = "absent" if items == 0 else str(len(DMG)) + " " + SIGNATURE
                    self.assertEqual(self.tool.appcast_state(text, VERSION), expected)
                    self.assertEqual(self.tool.appcast_state(text, VERSION), expected)
            count += 1
        self.assertEqual(count, 24)
        for invalid in ("", feed().replace("<enclosure", "<other"), feed().replace('length="15"', 'length="bad"'), feed().replace(SIGNATURE, "bad"), feed().replace("v1.0.0/", "v9.0.0/")):
            with self.assertRaises((ValueError, ET.ParseError)): self.tool.appcast_state(invalid, VERSION)


if __name__ == "__main__":
    unittest.main()
