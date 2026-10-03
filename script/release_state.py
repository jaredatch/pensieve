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


def contents_sha(path):
    value = response_json(path)
    require(re.fullmatch(r"[a-f0-9]{40}", value.get("sha", "")), "contents response has no valid SHA")
    return value["sha"]


def contents(path, output):
    value = response_json(path)
    require(re.fullmatch(r"[a-f0-9]{40}", value.get("sha", "")), "contents response has no valid SHA")
    require(value.get("encoding") == "base64", "contents response is not base64")
    require(isinstance(value.get("content"), str), "contents response has no text content")
    data = base64.b64decode(value["content"].replace("\n", "").replace("\r", ""), validate=True)
    require(data, "empty contents response")
    Path(output).write_bytes(data)
    return value["sha"]


def version_parts(version):
    require(re.fullmatch(VERSION, version), "invalid publication version")
    core, separator, suffix = version.partition("-")
    numbers = core.split(".")
    identifiers = suffix.split(".") if separator else []
    require(all(n == "0" or not n.startswith("0") for n in numbers), "version has leading zeros")
    require(all(re.fullmatch(r"[A-Za-z0-9-]+", part) for part in identifiers), "invalid prerelease version")
    require(all(not part.isdigit() or part == "0" or not part.startswith("0") for part in identifiers), "prerelease has leading zeros")
    return tuple(map(int, numbers)), identifiers


def compare_versions(left, right):
    return compare_version_parts(version_parts(left), version_parts(right))


def compare_version_parts(left, right):
    left_core, left_pre = left
    right_core, right_pre = right
    if left_core != right_core:
        return 1 if left_core > right_core else -1
    if not left_pre or not right_pre:
        return (not left_pre) - (not right_pre)
    for a, b in zip(left_pre, right_pre):
        if a == b:
            continue
        if a.isdigit() and b.isdigit():
            return 1 if int(a) > int(b) else -1
        if a.isdigit() != b.isdigit():
            return -1 if a.isdigit() else 1
        return 1 if a > b else -1
    return (len(left_pre) > len(right_pre)) - (len(left_pre) < len(right_pre))


def cask_fields(text):
    fields = []
    for name, pattern in (("version", rf'"({VERSION})"'), ("sha256", r'(?:"([a-f0-9]{64})"|(:no_check))')):
        candidates = list(re.finditer(rf"(?m)^[ \t]*{name}\b[^\r\n]*", text))
        require(len(candidates) == 1, f"cask has missing or duplicated {name} line")
        match = re.fullmatch(rf"[ \t]*{name}[ \t]+({pattern})[ \t]*", candidates[0].group())
        require(match, f"cask has malformed {name} line")
        fields.append((candidates[0], match.group(1)))
    try:
        syntax = subprocess.run(
            ["/usr/bin/ruby", "-rripper", "-e", "exit(Ripper.sexp(STDIN.read) ? 0 : 1)"],
            input=text, text=True, capture_output=True, timeout=10)
    except FileNotFoundError as error:
        raise ValueError("required interpreter /usr/bin/ruby is missing") from error
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


def appcast_root(text):
    require(text.strip(), "empty appcast")
    require("<!DOCTYPE" not in text.upper() and "<!ENTITY" not in text.upper(), "appcast contains a DTD")
    root = ET.fromstring(text)
    require(root.tag == "rss" and len(root.findall("channel")) == 1, "invalid appcast channel")
    return root


def appcast_publication_state(text, version, download_prefix):
    root = appcast_root(text)
    seen, result = set(), "absent"
    newest, newest_parts = version, version_parts(version)
    channel = "beta" if "-" in version else ""
    expected_url = f"{download_prefix}/v{version}/Pensieve-{version}.dmg"
    for item in root.find("channel").findall("item"):
        versions = item.findall(SPARKLE + "shortVersionString")
        require(len(versions) == 1, "malformed appcast version")
        current = versions[0].text or ""
        current_parts = version_parts(current)
        require(current not in seen, f"duplicated appcast item for {current}")
        seen.add(current)
        enclosures = item.findall("enclosure")
        require(len(enclosures) == 1, f"missing or duplicated appcast enclosure for {current}")
        enclosure = enclosures[0]
        channels = item.findall(SPARKLE + "channel")
        require(len(channels) <= 1, "duplicated appcast channel")
        current_channel = (channels[0].text or "") if channels else ""
        if current_channel == channel and compare_version_parts(current_parts, newest_parts) > 0:
            newest, newest_parts = current, current_parts
        if current != version:
            require(enclosure.get("url") != expected_url, "appcast item names this DMG under another version")
            continue
        require(enclosure.get("url") == expected_url, "appcast item names other bytes (wrong DMG URL)")
        length = enclosure.get("length", "")
        require(re.fullmatch(r"[1-9][0-9]*", length), "appcast has invalid DMG length")
        signature = enclosure.get(SPARKLE + "edSignature", "")
        require(len(base64.b64decode(signature, validate=True)) == 64, "appcast has invalid EdDSA signature")
        result = length + " " + signature
    return result, newest if newest != version else "absent"


def appcast_state(text, version, download_prefix):
    return appcast_publication_state(text, version, download_prefix)[0]


def release_state(value, version, require_uploaded=False):
    require(value.get("tag_name") == "v" + version, "release has wrong tag")
    require(value.get("draft") is False, "release is a draft or has no draft flag")
    require(value.get("prerelease") is ("-" in version), "release has wrong prerelease flag")
    require(type(value.get("id")) is int and value["id"] > 0, "release has invalid ID")
    assets = value.get("assets")
    require(isinstance(assets, list) and len(assets) <= 1, "release has extra or invalid DMG assets")
    asset = assets[0] if assets else None
    if assets:
        require(isinstance(asset, dict), "release DMG is not an object")
        require(asset.get("name") == f"Pensieve-{version}.dmg", "release is missing its expected DMG")
        require(type(asset.get("size")) is int and asset["size"] >= (1 if asset.get("state") == "uploaded" else 0), "release DMG has invalid size")
        require(type(asset.get("id")) is int and asset["id"] > 0, "release DMG has invalid ID")
    if require_uploaded:
        require(asset is not None and asset.get("state") == "uploaded", "live appcast release DMG is missing or not uploaded")
    # The actual tag target is peeled and verified separately. Asset IDs, sizes,
    # timestamps and partial state names do not decide creation or replacement.
    action = {key: value[key] for key in ("id", "tag_name", "draft", "prerelease")}
    action["asset"] = "absent" if asset is None else "uploaded" if asset.get("state") == "uploaded" else "partial"
    return json.dumps(action, sort_keys=True)


def main(args):
    mode = args[0]
    if mode == "contents":
        print(contents(*args[1:]))
    elif mode == "contents-sha":
        print(contents_sha(args[1]))
    elif mode == "release":
        print(release_state(response_json(args[1]), args[2], args[3] == "live"))
    elif mode == "tag":
        obj = response_json(args[1])["object"]
        require(obj["type"] in ("commit", "tag") and re.fullmatch(r"[a-f0-9]{40}", obj["sha"]), "invalid tag target")
        print(obj["type"], obj["sha"])
    elif mode == "appcast":
        print(*appcast_publication_state(Path(args[1]).read_text(), args[2], args[3]), sep="\n")
    elif mode == "compare-versions":
        print(compare_versions(args[1], args[2]))
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
