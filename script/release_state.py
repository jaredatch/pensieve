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
PUBLICATION_CHANNELS = dict(stable="", alpha="alpha", prerelease="beta")


def diagnostic_text(value):
    # The runner also recognizes legacy commands anywhere in a log line.
    return ascii(str(value)).replace("##[", r"\x23\x23[")


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


def contents_blob_sha(value):
    sha = value.get("sha")
    require(isinstance(sha, str) and re.fullmatch(r"[a-f0-9]{40}", sha), "contents response has no valid SHA")
    return sha


def contents_sha(path):
    return contents_blob_sha(response_json(path))


def contents(path, output):
    value = response_json(path)
    sha = contents_blob_sha(value)
    require(value.get("encoding") == "base64", "contents response is not base64")
    require(isinstance(value.get("content"), str), "contents response has no text content")
    data = base64.b64decode(value["content"].replace("\n", "").replace("\r", ""), validate=True)
    require(data, "empty contents response")
    Path(output).write_bytes(data)
    return sha


def version_parts(version):
    require(re.fullmatch(VERSION, version), f"invalid publication version: {version}")
    core, separator, suffix = version.partition("-")
    numbers = core.split(".")
    identifiers = suffix.split(".") if separator else []
    require(all(n == "0" or not n.startswith("0") for n in numbers), "version has leading zeros")
    require(all(re.fullmatch(r"[A-Za-z0-9-]+", part) for part in identifiers), "invalid prerelease version")
    require(all(not part.isdigit() or part == "0" or not part.startswith("0") for part in identifiers), "prerelease has leading zeros")
    return tuple(map(int, numbers)), identifiers


def compare_versions(left, right):
    return compare_version_parts(version_parts(left), version_parts(right))


def publication_channel(version):
    """Channel for a validated publication version; all prereleases use beta."""
    return PUBLICATION_CHANNELS["prerelease"] if "-" in version else PUBLICATION_CHANNELS["stable"]


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


def appcast_publication_state(root, version, download_prefix):
    seen, result = set(), "absent"
    newest, newest_parts = version, version_parts(version)
    channel = publication_channel(version)
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
        current_channel = channels[0].text if channels else PUBLICATION_CHANNELS["stable"]
        require(not channels or bool(current_channel), "empty appcast channel")
        require(current_channel in PUBLICATION_CHANNELS.values(), "unknown or malformed appcast channel")
        if current_channel in (PUBLICATION_CHANNELS["stable"], channel) and compare_version_parts(current_parts, newest_parts) > 0:
            newest, newest_parts = current, current_parts
        if current != version:
            require(enclosure.get("url") != expected_url, "appcast item names this DMG under another version")
            continue
        require(current_channel == channel, "appcast item is in the wrong channel")
        require(enclosure.get("url") == expected_url, "appcast item names other bytes (wrong DMG URL)")
        length = enclosure.get("length", "")
        require(re.fullmatch(r"[1-9][0-9]*", length), "appcast has invalid DMG length")
        signature = enclosure.get(SPARKLE + "edSignature", "")
        require(len(base64.b64decode(signature, validate=True)) == 64, "appcast has invalid EdDSA signature")
        result = length + " " + signature
    return result, newest if newest != version else "absent"


def canonical_xml(element, omit_items=()):
    """Compare expanded XML names and content, ignoring pretty-print whitespace.

    Sparkle rewrites indentation and attribute order but preserves leaf text.
    Item tails belong to the channel, so even an omitted item's nonblank tail
    remains part of the channel metadata comparison.
    """
    text = element.text or ""
    if len(element) and not text.strip():
        text = ""
    children = []
    for child in element:
        if child not in omit_items:
            children.append(canonical_xml(child, omit_items))
        tail = child.tail or ""
        if tail.strip():
            children.append(tail)
    return element.tag, tuple(sorted(element.attrib.items())), text, tuple(children)


def appcast_provenance(text, base_text, built_dmg, download_prefix, version, built_minimum=None):
    version_parts(version)
    require(built_dmg == f"Pensieve-{version}.dmg", "generated appcast names a different built DMG")
    root = appcast_root(text)
    if base_text is None:
        # Sparkle's FeedXML creates this shape when no feed exists yet.
        base = ET.Element("rss", version="2.0")
        ET.SubElement(ET.SubElement(base, "channel"), "title").text = "Pensieve"
    else:
        base = appcast_root(base_text)
    state, _ = appcast_publication_state(root, version, download_prefix)
    require(state != "absent", "generated appcast has no item for the publication version")
    base_items = base.find("channel").findall("item")
    items = root.find("channel").findall("item")
    if built_minimum is not None:
        current = next(item for item in items if item.findtext(SPARKLE + "shortVersionString") == version)
        minimums = current.findall(SPARKLE + "minimumSystemVersion")
        require(len(minimums) == 1 and bool(minimums[0].text),
                "generated appcast has missing, empty or duplicated minimum system version")
        require(minimums[0].text == built_minimum,
                f"generated appcast minimum {minimums[0].text} differs from built app minimum {built_minimum}")
    require(canonical_xml(root, items) == canonical_xml(base, base_items),
            "generated appcast changes channel or feed metadata")
    require(not any(item.findtext(SPARKLE + "shortVersionString") == version for item in base_items),
            "generated appcast publication version already exists in base")
    carried = {canonical_xml(item) for item in base_items}
    for item in items:
        if item.findtext(SPARKLE + "shortVersionString") != version:
            require(canonical_xml(item) in carried, "generated appcast introduces or changes another item")


def release_state(value, version, require_uploaded=False):
    require(value.get("tag_name") == "v" + version, "release has wrong tag")
    require(value.get("draft") is False, "release is a draft or has no draft flag")
    require(value.get("prerelease") is bool(publication_channel(version)), "release has wrong prerelease flag")
    require(type(value.get("id")) is int and value["id"] > 0, "release has invalid ID")
    assets = value.get("assets")
    require(isinstance(assets, list) and len(assets) <= 1, "release has extra or invalid DMG assets")
    asset = assets[0] if assets else None
    if assets:
        require(isinstance(asset, dict), "release DMG is not an object")
        require(asset.get("name") == f"Pensieve-{version}.dmg", "release is missing its expected DMG")
        require(asset.get("state") in ("uploaded", "open", "starter"), "release DMG has unknown upload state")
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
    if mode == "log-text":
        print(diagnostic_text(args[1]))
    elif mode == "log-file":
        print(diagnostic_text(Path(args[1]).read_bytes().decode("utf-8", errors="backslashreplace")))
    elif mode == "contents":
        print(contents(*args[1:]))
    elif mode == "contents-sha":
        print(contents_sha(args[1]))
    elif mode == "release":
        print(release_state(response_json(args[1]), args[2], args[3] == "live"))
    elif mode == "tag":
        obj = response_json(args[1])["object"]
        require(obj["type"] in ("commit", "tag") and re.fullmatch(r"[a-f0-9]{40}", obj["sha"]), "invalid tag target")
        print(obj["type"], obj["sha"])
    elif mode == "provenance":
        text = Path(args[1]).read_text()
        base_text = Path(args[2]).read_text() if args[2] else None
        appcast_provenance(text, base_text, args[3], args[4], args[5], args[6] if len(args) > 6 else None)
    elif mode == "appcast":
        print(*appcast_publication_state(appcast_root(Path(args[1]).read_text()), args[2], args[3]), sep="\n")
    elif mode == "compare-versions":
        print(compare_versions(args[1], args[2]))
    elif mode == "channel":
        version_parts(args[1])
        print(publication_channel(args[1]))
    elif mode == "cask":
        print(cask_state(Path(args[1]).read_text()))
    elif mode == "rewrite-cask":
        text = Path(args[1]).read_bytes().decode("utf-8")
        Path(args[2]).write_bytes(rewrite_cask(text, args[3], args[4]).encode("utf-8"))
    else:
        raise ValueError(f"unknown state operation: {mode}")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, KeyError, IndexError, TypeError, OSError, ET.ParseError, subprocess.SubprocessError) as error:
        sys.exit(f"release: invalid {diagnostic_text(sys.argv[1] if len(sys.argv) > 1 else 'publication')} state: {diagnostic_text(error)}")
