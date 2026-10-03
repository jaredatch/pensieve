#!/usr/bin/env python3
"""Strict readers for publication state. Unknown state never means absent."""
import base64
import json
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
VERSION = r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def response_json(path):
    response = Path(path).read_bytes()
    headers, body = re.split(rb"\r?\n\r?\n", response, maxsplit=1)
    require(re.match(rb"HTTP/\S+ 200\b", headers), "unexpected HTTP response")
    value = json.loads(body)
    require(isinstance(value, dict), "response is not an object")
    return value


def contents(path, output):
    value = response_json(path)
    require(re.fullmatch(r"[a-f0-9]{40}", value.get("sha", "")), "contents response has no valid SHA")
    require(value.get("encoding") == "base64", "contents response is not base64")
    data = base64.b64decode(value["content"].replace("\n", "").replace("\r", ""), validate=True)
    require(data, "empty contents response")
    Path(output).write_bytes(data)
    return value["sha"]


def cask_fields(text):
    fields = []
    for name, pattern in (("version", rf'"({VERSION})"'), ("sha256", r'(?:"([a-f0-9]{64})"|(:no_check))')):
        candidates = list(re.finditer(rf"(?m)^[ \t]*{name}\b[^\r\n]*", text))
        require(len(candidates) == 1, f"cask has missing or duplicated {name} line")
        match = re.fullmatch(rf"[ \t]*{name}[ \t]+({pattern})[ \t]*", candidates[0].group())
        require(match, f"cask has malformed {name} line")
        fields.append((candidates[0], match.group(1)))
    syntax = subprocess.run(
        ["/usr/bin/ruby", "-rripper", "-e", "exit(Ripper.sexp(STDIN.read) ? 0 : 1)"],
        input=text, text=True, capture_output=True, timeout=10)
    require(syntax.returncode == 0, "cask has malformed Ruby syntax")
    return fields


def cask_state(text):
    return " ".join(value.strip('"') for _, value in cask_fields(text))


def rewrite_cask(text, version, sha):
    require(re.fullmatch(VERSION, version), "invalid cask version")
    require(re.fullmatch(r"[a-f0-9]{64}", sha), "invalid cask sha256")
    fields = cask_fields(text)
    for (match, _), value in reversed(list(zip(fields, (version, sha)))):
        prefix = re.match(r"[ \t]*\w+[ \t]+", match.group()).group()
        suffix = re.search(r"[ \t]*$", match.group()).group()
        text = text[:match.start()] + prefix + '"' + value + '"' + suffix + text[match.end():]
    return text


def appcast_state(text, version):
    require(text.strip(), "empty appcast")
    require("<!DOCTYPE" not in text.upper() and "<!ENTITY" not in text.upper(), "appcast contains a DTD")
    root = ET.fromstring(text)
    require(root.tag == "rss" and len(root.findall("channel")) == 1, "invalid appcast channel")
    seen, result = set(), "absent"
    expected_url = f"https://github.com/jaredatch/pensieve/releases/download/v{version}/Pensieve-{version}.dmg"
    for item in root.find("channel").findall("item"):
        versions = item.findall(SPARKLE + "shortVersionString")
        require(len(versions) == 1 and re.fullmatch(VERSION, versions[0].text or ""), "malformed appcast version")
        current = versions[0].text
        require(current not in seen, f"duplicated appcast item for {current}")
        seen.add(current)
        enclosures = item.findall("enclosure")
        require(len(enclosures) == 1, f"missing or duplicated appcast enclosure for {current}")
        enclosure = enclosures[0]
        if current != version:
            require(enclosure.get("url") != expected_url, "appcast item names this DMG under another version")
            continue
        require(enclosure.get("url") == expected_url, "appcast item names other bytes (wrong DMG URL)")
        length = enclosure.get("length", "")
        require(re.fullmatch(r"[1-9][0-9]*", length), "appcast has invalid DMG length")
        signature = enclosure.get(SPARKLE + "edSignature", "")
        require(len(base64.b64decode(signature, validate=True)) == 64, "appcast has invalid EdDSA signature")
        result = length + " " + signature
    return result


def release_state(value, version):
    require(value.get("tag_name") == "v" + version, "release has wrong tag")
    require(value.get("draft") is False, "release is a draft or has no draft flag")
    require(value.get("prerelease") is ("-" in version), "release has wrong prerelease flag")
    require(type(value.get("id")) is int and value["id"] > 0, "release has invalid ID")
    assets = value.get("assets")
    require(isinstance(assets, list) and len(assets) == 1, "release has extra or missing DMG assets")
    asset = assets[0]
    require(isinstance(asset, dict), "release DMG is not an object")
    require(asset.get("name") == f"Pensieve-{version}.dmg", "release is missing its expected DMG")
    require(asset.get("state") == "uploaded", "release DMG is not uploaded")
    require(type(asset.get("size")) is int and asset["size"] > 0, "release DMG has invalid size")
    require(type(asset.get("id")) is int and asset["id"] > 0, "release DMG has invalid ID")
    # Download counts and timestamps can change without changing publication state.
    return json.dumps({"id": value["id"], "asset": {key: asset[key] for key in ("id", "name", "size", "state")}}, sort_keys=True)


def main(args):
    mode = args[0]
    if mode == "contents":
        print(contents(*args[1:]))
    elif mode == "release":
        print(release_state(response_json(args[1]), args[2]))
    elif mode == "tag":
        obj = response_json(args[1])["object"]
        require(obj["type"] in ("commit", "tag") and re.fullmatch(r"[a-f0-9]{40}", obj["sha"]), "invalid tag target")
        print(obj["type"], obj["sha"])
    elif mode == "appcast":
        print(appcast_state(Path(args[1]).read_text(), args[2]))
    elif mode == "cask":
        print(cask_state(Path(args[1]).read_text()))
    elif mode == "rewrite-cask":
        text = Path(args[1]).read_bytes().decode("utf-8")
        Path(args[2]).write_bytes(rewrite_cask(text, args[3], args[4]).encode("utf-8"))
    else:
        raise ValueError("unknown state operation")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, KeyError, IndexError, TypeError, OSError, ET.ParseError, subprocess.SubprocessError) as error:
        sys.exit(f"release: invalid {sys.argv[1] if len(sys.argv) > 1 else 'publication'} state: {error}")
