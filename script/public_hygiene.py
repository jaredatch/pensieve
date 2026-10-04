"""Read-only public-tree hygiene checks; Git paths are always NUL-delimited.

Policy comes from the index on commit, the working tree in tree mode, and each
commit in range mode. Range acceptances come from the range's base commit.
Staged, tree and range scans trust no diff text, textconv, external diff,
or rename heuristic: a new destination is always scanned whole. Binary bytes aren't
skipped. Line numbers count LF bytes, including in CRLF and binary input.
The project-check replay callback can inspect only added text in its stdin diff;
range mode remains required for blob contents and historical policy.
"""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import posixpath
import re
import stat
import subprocess
import sys
from urllib.parse import unquote, urlsplit

PATHS = 'script/private-paths.txt'
SETTINGS = 'script/public-hygiene.json'
ACCEPTANCES = 'script/public-hygiene-acceptances.json'
KIT = frozenset('script/' + name for name in (
    'ratchet.sh', 'refreeze.sh', 'ci-replay.sh', 'tmp-tidy.sh',
    'briefing-lint.sh', 'acceptance-extract.awk', 'install-hooks.sh', 'drive-stage.sh',
    'hooks/pre-commit', 'hooks/commit-msg', 'hooks/pre-push',
))
KIT_CONFIG = frozenset(('script/ratchet.conf', 'script/herdr.conf'))
FIXTURE_USERS = frozenset(('test', 'x', 'k', 'kk', 'fixture', 'other', 'me', 'user', 'Shared'))
EMAIL_DOMAINS = frozenset(('example.com', 'example.org', 'example.net',
                           'pensieve.local', 'github.com'))
# The asset catalog, and the app icon's Icon Composer layers: Xcode won't take an .icon bundle inside
# an asset catalog, so its layer images sit beside it. That one bundle's Assets/ folder only.
ASSET_FOLDERS = ('Pensieve/Resources/Assets.xcassets/', 'Pensieve/Resources/Pensieve.icon/Assets/')
IMAGE_SUFFIXES = frozenset(('.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg',
                            '.heic', '.heif', '.tif', '.tiff', '.bmp', '.ico', '.icns', '.avif',
                            '.sketch', '.fig', '.psd', '.ai', '.svgz', '.jxl', '.mov', '.mp4', '.webm'))
OPAQUE_SUFFIXES = frozenset(('.zip', '.gz', '.gzip', '.tgz', '.tar', '.bz2', '.tbz', '.tbz2',
                            '.xz', '.txz', '.zst', '.zstd', '.tzst', '.lz', '.lzma', '.lz4', '.z',
                            '.7z', '.rar', '.dmg', '.iso', '.pkg', '.xar', '.pdf', '.jar', '.war',
                            '.key', '.pages', '.numbers', '.doc', '.docx', '.xls', '.xlsx',
                            '.ppt', '.pptx', '.odt', '.ods', '.odp', '.xcresult', '.deb', '.rpm'))
# No opaque files are currently required in the public tree. Add only reviewed
# exact paths here, with the reason recorded in the private decision log.
OPAQUE_ALLOWLIST = frozenset()
# Deliberate briefing edits require a reviewed pin update and a private record.
PUBLIC_BRIEFING_SHA256 = {
    'CLAUDE.md': '5b9ddfe47b6fc2685bfa9944526d0174641e5c3f9b0a05f06fd5c20ea1726a00',
    'AGENTS.md': 'abbed1a08146130b5ee0460f5ca5c99e67355f933b2055dc992bcae68a80625c',
}
EMAIL_FILENAME_SUFFIXES = IMAGE_SUFFIXES - {'.ai', '.mov'}
MARKUP_SUFFIXES = frozenset(('.md', '.markdown', '.html', '.htm'))
DECISION = re.compile(r'\bDEC-\d+\b')
HOME_PATH = re.compile(r'/Users' r'/(\w[^/\s"\'`<>\\),;:\]}]*)')
NAMED_HOME = re.compile(r'(?<![^\s"\'`(\[<])~([A-Za-z_][A-Za-z0-9._-]*)/')
PROJECT_HOME = re.compile(r'(?<![\w-])-Users' r'-([^-/\s"\'`)<>\\\],;:]+)')
EMAIL = re.compile(r'(?<![\w.+-])[\w.!#$%&\'*+/=?^`{|}~-]+@([a-z0-9-]+(?:\.[a-z0-9-]+)+)', re.I)
HOSTNAME = re.compile(r'(?<![\w-])(?:[a-z0-9-]+\.)+ts\.net\b', re.I)


class ReadError(Exception):
    pass


def git(*args):
    result = subprocess.run(['git', *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise ReadError('cannot read Git ' + ' '.join(args) + ': ' +
                        result.stderr.decode('utf-8', 'replace').strip())
    return result.stdout


def disk_bytes(path):
    try:
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode):
            return os.fsencode(os.readlink(path))
        if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o444:
            raise OSError('not a readable regular file')
        return Path(path).read_bytes()
    except OSError as error:
        raise ReadError(f'cannot read tracked file {path}: {error}') from error


class Snapshot:
    def __init__(self, revision=None, working=False):
        self.working = working
        self.revision = revision
        self.entries = {}
        self.cache = {}
        if revision is None:
            index = os.fsdecode(git('rev-parse', '--git-path', 'index').strip())
            # A missing index is not an empty staged tree.
            disk_bytes(index)
            listing = git('ls-files', '--stage', '-z')
        else:
            listing = git('ls-tree', '-r', '-z', revision)
        for entry in listing.split(b'\0'):
            if not entry:
                continue
            metadata, path = entry.split(b'\t', 1)
            fields = metadata.decode('ascii').split()
            mode, oid = fields[0], fields[1] if revision is None else fields[2]
            name = os.fsdecode(path)
            if revision is None and fields[2] != '0':
                raise ReadError(f'cannot read unmerged index entry {name}')
            if mode not in ('100644', '100755', '120000'):
                raise ReadError(f'cannot read tracked file {name}: unsupported Git mode {mode}')
            self.entries[name] = (mode, oid)

    def read(self, path):
        if path not in self.entries:
            raise ReadError(f'cannot read {path}: absent from snapshot')
        if path not in self.cache:
            if self.working:
                self.cache[path] = disk_bytes(path)
            else:
                try:
                    self.cache[path] = git('cat-file', 'blob', self.entries[path][1])
                except ReadError as error:
                    raise ReadError(f'cannot read blob {path}: {error}') from error
        return self.cache[path]


def private_paths(snapshot):
    try:
        lines = snapshot.read(PATHS).decode('utf-8').splitlines()
        paths = [line for line in lines if line and not line.startswith('#')]
        for path in paths:
            if (path != path.strip() or path.startswith('/') or '\\' in path or
                    any(part in ('', '.', '..') for part in path.rstrip('/').split('/'))):
                raise ValueError(f'invalid relative path {path!r}')
        if not paths or len(set(paths)) != len(paths):
            raise ValueError('empty or duplicate path list')
        return paths
    except (UnicodeError, ValueError) as error:
        raise ReadError(f'cannot read private-path list {PATHS}: {error}') from error


def is_private(path, paths):
    path = path.casefold()
    return any(path.startswith(item.casefold()) if item.endswith('/') else path == item.casefold() for item in paths)


def public_layout(snapshot):
    try:
        settings = json.loads(snapshot.read(SETTINGS))
        if set(settings) != {'public_repo'} or type(settings['public_repo']) is not bool:
            raise ValueError('expected a public_repo boolean')
        return settings['public_repo']
    except (ValueError, TypeError) as error:
        raise ReadError(f'cannot read settings {SETTINGS}: {error}') from error


def read_personal_terms(path, paths, root):
    if not is_private(os.path.relpath(path, root), paths):
        raise ReadError(f'personal-terms file must be under a private path: {path}')
    try:
        os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError as error:
        raise ReadError(f'cannot read personal-terms file {path}: {error}') from error
    try:
        # A dangling symlink or a directory is an error, never an absent file.
        if Path(path).is_symlink():
            raise OSError('symlinks are not supported')
        return [line.strip() for line in disk_bytes(path).decode('utf-8').splitlines()
                if line.strip() and not line.startswith('#')]
    except (OSError, UnicodeError, ReadError) as error:
        raise ReadError(f'cannot read personal-terms file {path}: {error}') from error


def personal_terms(path, paths, required=False):
    root = Path.cwd()
    if path is not None:
        terms = read_personal_terms(path, paths, root)
        if required and terms is None:
            raise ReadError('required personal-terms file missing: ' + str(path))
        return terms or []
    relative = Path('private') / 'hygiene-personal-terms'
    common = os.fsdecode(git('rev-parse', '--path-format=absolute', '--git-common-dir').rstrip(b'\n'))
    # Git lists the main worktree first, including with a separate Git directory.
    listing = git('--git-dir', common, 'worktree', 'list', '--porcelain', '-z')
    first = listing.split(b'\0', 1)[0]
    if not first.startswith(b'worktree '):
        raise ReadError('cannot read main worktree from Git common directory ' + common)
    main = Path(os.fsdecode(first[len(b'worktree '):]))
    roots = [root] if main.resolve() == root.resolve() else [root, main]
    selected = None
    for directory in roots:
        terms = read_personal_terms(directory / relative, paths, directory)
        # Validate both existing files, even when the local file takes precedence.
        if selected is None and terms is not None:
            selected = terms
    if required and selected is None:
        raise ReadError('required personal-terms file missing: ' + str(relative))
    return selected or []


def link_targets(line):
    patterns = (
        r'\]\(\s*(?:<([^>]+)>|([^\s)]+))',
        r'^\s*\[[^\]]+\]:\s*(?:<([^>]+)>|(\S+))',
        r'\b(?:href|src)\s*=\s*(?:"([^"]*)"|\'([^\']*)\')',
    )
    for pattern in patterns:
        for match in re.finditer(pattern, line, re.I):
            yield next(value for value in match.groups() if value is not None)


def private_link(line, paths, citing_path):
    if Path(citing_path).suffix.lower() not in MARKUP_SUFFIXES:
        return False
    for target in link_targets(line):
        if re.match(r'^(?:[A-Za-z][A-Za-z0-9+.-]*://|//|mailto:|tel:|data:|javascript:)', target, re.I):
            continue
        target = re.split(r'[?#]', target, maxsplit=1)[0]
        target = re.sub(r':L?\d+(?:[-:]L?\d+)?$', '', target)
        if not target:
            continue
        base = '' if target.startswith('/') else posixpath.dirname(citing_path)
        resolved = posixpath.normpath('/' + posixpath.join(base, target.lstrip('/'))).lstrip('/')
        if is_private(resolved, paths) or any(
                resolved.casefold() == item.rstrip('/').casefold() for item in paths if item.endswith('/')):
            return True
    return False


def private_cite(line, paths, citing_path=''):
    if private_link(line, paths, citing_path):
        return True
    shell_root = r'\$(?!(?:HOME|\{[!#]?HOME)(?!\w))(?:[A-Za-z_]\w*|\{[^{}\n]+\}|\([^\n]*?\))["\']?/'
    repository_url = (r'(?i:(?:https?://)?(?:(?:www\.)?github\.com/jaredatch/pensieve(?:-app)?/(?:blob|tree|raw|blame|edit|commits|history)/'
                      r'|raw\.githubusercontent\.com/jaredatch/pensieve(?:-app)?/))'
                      r'[^\s"\'<>?#)]+/')
    checkout_root = r'(?<![\w/.:~-])(?:~|\$HOME|\$\{HOME\})?/(?:[^/\s"\'`<>?#)]+/)*'
    if re.search(r'(?<![\w.-])jaredatch/' r'pensieve-private(?![\w-])', line, re.I):
        return True
    for path in paths:
        ending = r'(?=$|[^\w.-]|\.+(?![\w.-]))'
        cite = re.escape(path.rstrip('/')) + ending
        if path.startswith('docs/') and re.search(checkout_root + cite, line, re.I):
            return True
        needs_slash = path.endswith('/') and '/' not in path[:-1]
        shell_cite = re.escape(path) if needs_slash else cite
        if re.search(shell_root + shell_cite, line, re.I) or re.search(repository_url + cite, line, re.I):
            return True
        # Agent filenames are also product vocabulary. An explicit repo link,
        # ./ prefix or section reference distinguishes a cite from that vocabulary.
        if path in ('CLAUDE.md', 'AGENTS.md'):
            if re.search(r'(?:\]\((?:\.\./)*|\./)' + re.escape(path) + ending, line, re.I):
                return True
            if re.search(r'(?<![/\w])' + re.escape(path) + r'[` ]*§', line, re.I):
                return True
            continue
        pattern = r'(?<![\w/.-])(?:\./|\.\./)*' + cite
        if path.endswith('/') and '/' not in path.rstrip('/'):
            # A lone folder name is also ordinary prose or a source keyword.
            # A slash or relative prefix makes it a repository path.
            pattern = (r'(?<![\w/.-])(?:' + re.escape(path) +
                       r'|(?:\./|\.\./)+' + cite + r')')
        if re.search(pattern, line, re.I):
            return True
    return False


def xml_token_end(data, offset, terminator):
    end = data.find(terminator, offset)
    return end + len(terminator) if end >= 0 else None


def doctype_end(data, offset):
    depth = 0
    while offset < len(data):
        byte = data[offset]
        if data.startswith(b'<!--', offset):
            offset = xml_token_end(data, offset + 4, b'-->')
        elif data.startswith(b'<?', offset):
            offset = xml_token_end(data, offset + 2, b'?>')
        elif byte in b'"\'':
            offset = xml_token_end(data, offset + 1, bytes((byte,)))
        else:
            if byte == ord('['):
                depth += 1
            elif byte == ord(']'):
                if depth == 0:
                    return None
                depth -= 1
            elif byte == ord('>') and depth == 0:
                return offset + 1
            offset += 1
        if offset is None:
            return None
    return None


def svg_document(data):
    # Each byte is consumed once: delimited tokens advance past their closing
    # bytes or end the scan. No backtracking, entity expansion or external I/O.
    offset = 3 if data.startswith(b'\xef\xbb\xbf') else 0
    while offset < len(data):
        if data[offset] in b' \t\r\n':
            offset += 1
        elif data.startswith(b'<!--', offset):
            offset = xml_token_end(data, offset + 4, b'-->')
        elif data.startswith(b'<?', offset):
            offset = xml_token_end(data, offset + 2, b'?>')
        elif (data.startswith(b'<!DOCTYPE', offset) and offset + 9 < len(data)
              and data[offset + 9] in b' \t\r\n'):
            offset = doctype_end(data, offset + 10)
        else:
            return (data.startswith(b'<svg', offset) and offset + 4 < len(data)
                    and data[offset + 4] in b' \t\r\n/>')
        if offset is None:
            return False
    return False


def image_file(path, data):
    if Path(path).suffix.lower() in IMAGE_SUFFIXES:
        return True
    if data.startswith((b'\x89PNG\r\n\x1a\n', b'\xff\xd8\xff', b'GIF87a', b'GIF89a',
                        b'II*\0', b'MM\0*')):
        return True
    if data.startswith(b'RIFF') and data[8:12] == b'WEBP':
        return True
    if data[4:8] == b'ftyp':
        size = int.from_bytes(data[:4], 'big')
        brands = [data[8:12]] + [data[i:i + 4] for i in range(16, min(size, len(data)), 4)]
        if 16 <= size <= len(data) and any(brand in (
                b'heic', b'heix', b'hevc', b'hevx', b'mif1', b'msf1', b'avif', b'avis') for brand in brands):
            return True
    # Short ASCII magics also start ordinary prose. Require their binary header
    # and size/offset structure before treating an extensionless file as an image.
    if data.startswith(b'BM') and len(data) >= 26:
        size = int.from_bytes(data[2:6], 'little')
        offset = int.from_bytes(data[10:14], 'little')
        header = int.from_bytes(data[14:18], 'little')
        if header in (12, 40, 52, 56, 64, 108, 124) and 14 + header <= offset < size <= len(data):
            return True
    if data.startswith(b'icns') and len(data) >= 16:
        size = int.from_bytes(data[4:8], 'big')
        offset = 8
        while offset + 8 <= size <= len(data):
            length = int.from_bytes(data[offset + 4:offset + 8], 'big')
            if length < 8 or offset + length > size:
                break
            offset += length
            if offset == size:
                return True
    if data.startswith(b'\0\0\x01\0') and len(data) >= 22:
        count = int.from_bytes(data[4:6], 'little')
        table_end = 6 + 16 * count
        if count and table_end <= len(data):
            entries = [(int.from_bytes(data[i + 8:i + 12], 'little'),
                        int.from_bytes(data[i + 12:i + 16], 'little')) for i in range(6, table_end, 16)]
            if all(size > 0 and table_end <= offset < offset + size <= len(data) for size, offset in entries):
                return True
    return svg_document(data)


def line_rules(path, line, paths, terms, public=False):
    rules = []
    if path not in KIT and DECISION.search(line):
        rules.append('decision-cite')
    home_line = line.replace(r'\/', '/')
    home_patterns = (HOME_PATH, PROJECT_HOME)
    if Path(path).suffix.lower() not in ('.js', '.mjs', '.cjs', '.ts'):
        home_patterns += (NAMED_HOME,)
    if any((match.group(1).rstrip('.') if pattern is HOME_PATH else match.group(1)) not in FIXTURE_USERS
           for pattern in home_patterns
           for match in pattern.finditer(home_line)):
        rules.append('home-path')
    if Path(path).suffix.lower() in MARKUP_SUFFIXES and re.search(
            r'data:image/', line, re.I):
        rules.append('image-location')
    for match in EMAIL.finditer(line):
        domain = match.group(1).lower()
        # Only a complete version plus tag is package notation. Numeric mail
        # domains still need the same address checks as alphabetic domains.
        if re.fullmatch(r'v?\d+(?:\.(?:x|\d+))*\.(?:x|lts|rc|alpha|beta|next|latest|canary|stable|nightly)'
                        r'(?:-[a-z0-9-]+)?', domain):
            continue
        labels, top_level = domain.rsplit('.', 1)
        top_level = top_level.split('-', 1)[0]
        domain = labels + '.' + top_level
        if not re.fullmatch('[a-z]+', top_level) or '.' + top_level in EMAIL_FILENAME_SUFFIXES:
            continue
        # Verbatim license notices may name authors' email addresses.
        if (path != 'THIRD-PARTY-NOTICES.md' and
                domain not in EMAIL_DOMAINS and not domain.endswith('.example')):
            rules.append('email')
            break
    if HOSTNAME.search(line):
        rules.append('private-hostname')
    if any(term.casefold() in line.casefold() for term in terms):
        rules.append('personal-term')
    # Exact manifest and ignore declarations define locations rather than cite them.
    declaration = path in (PATHS, '.gitignore') and line.rstrip('\r') in paths
    config_declaration = public and path in KIT_CONFIG and bool(re.fullmatch(
        r'(?:RATCHET_(?:LOG=docs/' r'LOG\.md|PLANS_DIR=docs/' r'plans|ALLOWLIST=docs/test-allowlist\.md)'
        r'|(?:RATCHET|XP)_RESUME_NOTE="?tmp' r'/clear-continue\.md"?)', line))
    command_setup = ('XP_WORKTREE_SETUP="xcodegen generate && mkdir -p .claude && { '
                     '[ -L .claude/' 'commands ] || { [ ! -e .claude/' 'commands ] && '
                     'ln -s ..' '/pri' 'vate/.claude/' 'commands .claude/' 'commands; }; }"')
    config_declaration |= public and path == 'script/herdr.conf' and line == command_setup
    exempt = KIT if public else KIT | KIT_CONFIG
    old_repo = public and re.search(r'(?i)(?<![\w.-])jaredatch/' r'pensieve-app(?![\w-])', line)
    if path not in exempt and not declaration and not config_declaration and (
            private_cite(line, paths, path) or old_repo):
        rules.append('private-path-cite')
    return rules


def added_lines(old, new):
    before, after = old.split(b'\n'), new.split(b'\n')
    matcher = difflib.SequenceMatcher(None, before, after, autojunk=False)
    return {i + 1 for tag, _, _, start, end in matcher.get_opcodes()
            if tag in ('insert', 'replace') for i in range(start, end)}


def opaque_file(path, data):
    if any(Path(part).suffix.lower() in OPAQUE_SUFFIXES for part in path.split('/')):
        return True
    return (data.startswith((b'%PDF', b'PK\x03\x04', b'PK\x05\x06', b'PK\x07\x08',
                             b'\x1f\x8b', b'7z\xbc\xaf\x27\x1c', b'\xfd7zXZ\x00',
                             b'BZh', b'Rar!\x1a\x07', b'\x28\xb5\x2f\xfd', b'\x04\x22\x4d\x18',
                             b'\x1f\x9d', b'xar!', b'!<arch>\n', b'\xed\xab\xee\xdb',
                             b'\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1'))
            or data[257:262] == b'ustar' or data[-512:-508] == b'koly'
            or data[32769:32774] == b'CD001')


def asset_image_file(path, data):
    """Opaque exemption: declared image format must agree with its bytes."""
    if not path.startswith(ASSET_FOLDERS):
        return False
    suffix = Path(path).suffix.lower()
    if suffix in ('.pdf', '.sketch', '.ai'):
        return True
    magics = {
        '.png': (b'\x89PNG\r\n\x1a\n',),
        '.jpg': (b'\xff\xd8\xff',), '.jpeg': (b'\xff\xd8\xff',),
        '.gif': (b'GIF87a', b'GIF89a'),
        '.tif': (b'II*\0', b'MM\0*'), '.tiff': (b'II*\0', b'MM\0*'),
        '.bmp': (b'BM',), '.ico': (b'\0\0\x01\0',), '.icns': (b'icns',),
    }
    if suffix in magics:
        return data.startswith(magics[suffix]) and image_file('', data)
    if suffix == '.webp':
        return data.startswith(b'RIFF') and data[8:12] == b'WEBP'
    if suffix == '.svg':
        return svg_document(data)
    if suffix in ('.heic', '.heif', '.avif') and data[4:8] == b'ftyp':
        size = int.from_bytes(data[:4], 'big')
        brands = [data[8:12]] + [data[i:i + 4] for i in range(16, min(size, len(data)), 4)]
        expected = {'.heic': (b'heic', b'heix', b'hevc', b'hevx'),
                    '.heif': (b'mif1', b'msf1', b'heic', b'heix', b'hevc', b'hevx'),
                    '.avif': (b'avif', b'avis')}
        return 16 <= size <= len(data) and any(brand in expected[suffix] for brand in brands)
    return False


def text_bytes(data):
    """Decode text candidates only; binary/invalid encodings retain raw bytes."""
    def text_characters(text):
        return all(ord(char) >= 32 or char in '\t\r\n\f' for char in text)

    # UTF-32 LE shares UTF-16 LE's first two bytes: test the longer BOM first.
    if data.startswith((b'\xff\xfe\0\0', b'\0\0\xfe\xff')):
        encodings = ['utf-32']
    elif data.startswith((b'\xff\xfe', b'\xfe\xff')):
        encodings = ['utf-16']
    else:
        encodings = []
        # Look through the entire input, including text after a long prefix.
        for encoding, pattern in (
                ('utf-16-le', rb'(?:[\x09\x0a\x0d\x20-\x7e]\0){4,}'),
                ('utf-16-be', rb'(?:\0[\x09\x0a\x0d\x20-\x7e]){4,}')):
            match = re.search(pattern, data)
            if not match:
                continue
            # Whole-file UTF-16 code units begin on an even byte boundary.
            # The opposite byte order also matches ASCII runs, one byte late.
            if match.start() % 2 == 0:
                encodings.append(encoding)
            # Mixed ASCII/UTF-16 text occurs in generated files. Only accept
            # it if all remaining bytes are valid text, without binary controls.
            candidate = re.sub(pattern, lambda match: match[0].decode(encoding).encode('utf-8'), data)
            try:
                if text_characters(candidate.decode('utf-8')):
                    return candidate
            except UnicodeError:
                pass
    for encoding in encodings:
        try:
            text = data.decode(encoding)
            if text_characters(text):
                return text.encode('utf-8')
        except UnicodeError:
            pass
    return data


def extra_briefing(path):
    name = path.rsplit('/', 1)[-1]
    return (name.casefold() in ('claude.md', 'claude.local.md')
            or name in ('AGENTS.md', 'AGENTS.override.md', 'AGENTS.local.md'))


def scan(current, previous, terms_path, tree=False, floor=None, require_terms=False):
    if PATHS not in current.entries and (tree or floor is not None or (previous and PATHS in previous.entries)):
        return [(PATHS, 1, 'private-path-list-deleted')]
    paths = private_paths(current)
    public = public_layout(current)
    old_paths = private_paths(previous) if previous and PATHS in previous.entries else paths
    policies = [(paths, public)]
    findings = set()
    # Parent policy remains monotonic; adoption is the durable floor even when
    # an earlier refused weakening is already in HEAD or outside the range.
    for policy in (previous, floor):
        if policy and PATHS in policy.entries and public_layout(policy):
            baseline_paths = private_paths(policy)
            policies.append((baseline_paths, True))
            if not public:
                findings.add((SETTINGS, 1, 'public-policy-weakened'))
            if {p.casefold() for p in baseline_paths} - {p.casefold() for p in paths}:
                findings.add((PATHS, 1, 'public-policy-weakened'))
    policies = list(dict.fromkeys((tuple(sorted(set(p))), public) for p, public in policies))
    terms = personal_terms(terms_path, paths, required=require_terms and any(p[1] for p in policies))
    if any(p[1] for p in policies):
        for name in PUBLIC_BRIEFING_SHA256:
            if name not in current.entries and any(p and name in p.entries for p in (previous, floor)):
                findings.add((name, 1, 'briefing-pin'))
    for paths, public in policies:
        for path in sorted(current.entries):
            old = previous and path in previous.entries
            changed = not old or current.entries[path] != previous.entries[path]
            briefing = public and path in ('CLAUDE.md', 'AGENTS.md')
            if (is_private(path, paths) or (public and extra_briefing(path))) and not briefing:
                if public and (tree or not old or changed):
                    findings.add((path, 1, 'private-file'))
                continue
            whole = tree or not old or is_private(path, old_paths) or briefing
            if not whole and not changed:
                continue
            data = current.read(path)
            if briefing and hashlib.sha256(data).hexdigest() != PUBLIC_BRIEFING_SHA256[path]:
                findings.add((path, 1, 'briefing-pin'))
            lines = None if whole else added_lines(text_bytes(previous.read(path)), text_bytes(data))
            is_image = image_file(path, data) or (public and Path(path).suffix.lower() == '.pdf')
            new_image = is_image and (whole or not image_file(path, previous.read(path)))
            if new_image and not path.startswith(ASSET_FOLDERS):
                findings.add((path, 1, 'image-location'))
            asset_image = asset_image_file(path, data)
            if public and opaque_file(path, data) and path not in OPAQUE_ALLOWLIST and not asset_image:
                findings.add((path, 1, 'opaque-container'))
            allowed = {'CLAUDE.md': '@private' '/CLAUDE.md',
                       'AGENTS.md': 'private' '/AGENTS.md'}.get(path) if briefing else None
            used = False
            for number, raw in enumerate(text_bytes(data).split(b'\n'), 1):
                line = raw.decode('utf-8', 'surrogateescape')
                # Remove one exact, boundary-delimited token; scan the rest of
                # that line too. Additional cites, even on this line, fail.
                if allowed and not used:
                    pattern = r'(?<![\w/.-])' + re.escape(allowed) + r'(?![\w/.-])'
                    line, count = re.subn(pattern, 'briefing', line, count=1)
                    used = bool(count)
                if lines is not None and number not in lines:
                    continue
                for rule in line_rules(path, line, paths, terms, public):
                    findings.add((path, number, rule))
    return sorted(findings)


def diff_path(raw):
    """Decode Git's C-quoted +++ path, including octal-escaped filename bytes."""
    raw = raw[:-1] if raw.endswith(b'\t') else raw
    if raw == b'/dev/null':
        return None
    if raw.startswith(b'"'):
        if not raw.endswith(b'"'):
            raise ReadError('unterminated path in project-check diff')
        raw = raw[1:-1]
        decoded = bytearray()
        escapes = {ord(key): value for key, value in
                   (('a', 7), ('b', 8), ('t', 9), ('n', 10), ('v', 11),
                    ('f', 12), ('r', 13), ('"', 34), ('\\', 92))}
        offset = 0
        while offset < len(raw):
            byte = raw[offset]
            offset += 1
            if byte == 92:
                if offset == len(raw):
                    raise ReadError('unfinished path escape in project-check diff')
                if raw[offset] in escapes:
                    byte = escapes[raw[offset]]
                    offset += 1
                elif re.fullmatch(rb'[0-3][0-7]{2}', raw[offset:offset + 3]):
                    byte = int(raw[offset:offset + 3], 8)
                    offset += 3
                else:
                    raise ReadError('invalid path escape in project-check diff')
            decoded.append(byte)
        raw = bytes(decoded)
    if not raw or raw.startswith(b'/') or b'\0' in raw or any(
            part in (b'', b'.', b'..') for part in raw.split(b'/')):
        raise ReadError('invalid relative path in project-check diff')
    return os.fsdecode(raw)


def diff_additions(data):
    """Yield added lines from the kit's -U0 --no-prefix patch, never from the index.

    Hunk counts distinguish headers from content that starts with +++ or @@.
    Git binary summaries and content-free renames supply no lines here. The full
    range scan handles those and policy changes; this callback has no commit ID.
    """
    path = None
    old_left = new_left = number = 0
    header_seen = False
    for raw in data.split(b'\n'):
        if raw == b'\\ No newline at end of file':
            continue
        if old_left or new_left:
            kind = raw[:1]
            if kind == b'+':
                new_left -= 1
                if path is None:
                    raise ReadError('addition without a destination in project-check diff')
                yield path, number, raw[1:]
                number += 1
            elif kind == b'-':
                old_left -= 1
            elif kind == b' ':
                old_left -= 1
                new_left -= 1
                number += 1
            else:
                raise ReadError('malformed hunk in project-check diff')
            if min(old_left, new_left) < 0:
                raise ReadError('invalid hunk counts in project-check diff')
        elif raw.startswith(b'diff --git '):
            path = None
            header_seen = False
        elif raw.startswith(b'+++ '):
            path = diff_path(raw[4:])
            header_seen = True
        elif raw.startswith(b'@@'):
            match = re.match(rb'@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@', raw)
            if not match or not header_seen:
                raise ReadError('invalid hunk header in project-check diff')
            old_left = int(match[1] or b'1')
            number = int(match[2])
            new_left = int(match[3] or b'1')
    if old_left or new_left:
        raise ReadError('truncated hunk in project-check diff')


def scan_project_diff(data, terms_path):
    # The callback supplies no revision. Use HEAD's committed policy rather than
    # unrelated staged/working policy. --range is authoritative for past policy.
    policy = head_snapshot()
    if policy is None:
        raise ReadError('project-check replay needs committed policy')
    paths = private_paths(policy)
    terms = personal_terms(terms_path, paths)
    findings = []
    for path, number, raw in diff_additions(data):
        if not is_private(path, paths):
            for rule in line_rules(path, raw.decode('utf-8', 'surrogateescape'), paths, terms):
                findings.append((path, number, rule))
    return findings


def report(findings, commit=None):
    for path, line, rule in findings:
        prefix = f'commit {commit}: ' if commit else ''
        if rule == 'private-path-list-deleted':
            hint = 'restore the private-path list; it is required to scan this repository.'
        elif rule == 'private-file':
            hint = 'this file belongs in the private repo; do not add it to this repository.'
        elif rule == 'image-location':
            hint = 'move the image into the asset catalog or under a private path.'
        else:
            hint = 'reword the line or move its file under a private path.'
        print(f'{prefix}{path}:{line}: {rule}: {hint}', file=sys.stderr)


def range_acceptances(base):
    # Only the committed base may authorize exceptions for the judged range.
    snapshot = Snapshot(base)
    if ACCEPTANCES not in snapshot.entries:
        return {}
    if snapshot.entries[ACCEPTANCES][0] not in ('100644', '100755'):
        raise ReadError(f'cannot read {ACCEPTANCES}: not a regular file')

    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate field')
            result[key] = value
        return result

    try:
        entries = json.loads(snapshot.read(ACCEPTANCES).decode('utf-8'), object_pairs_hook=unique_object)
        if not isinstance(entries, list):
            raise ValueError('expected a list of acceptance entries')
        accepted = {}
        fields = {'commit', 'path', 'line', 'rule', 'reason'}
        for entry in entries:
            if not isinstance(entry, dict) or set(entry) != fields:
                raise ValueError('each entry needs commit, path, line, rule and reason')
            if any(not isinstance(entry[field], str) for field in fields - {'line'}):
                raise ValueError('commit, path, rule and reason must be strings')
            if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', entry['commit']):
                raise ValueError('commit must be a full lowercase SHA')
            if any(part in ('', '.', '..') for part in entry['path'].split('/')) or '\x00' in entry['path']:
                raise ValueError('path must be a repository-relative file path')
            if type(entry['line']) is not int or entry['line'] < 1:
                raise ValueError('line must be a positive integer')
            if not re.fullmatch(r'[a-z]+(?:-[a-z]+)*', entry['rule']) or not entry['reason'].strip():
                raise ValueError('rule and reason must be nonempty and valid')
            key = (entry['commit'], entry['path'], entry['line'], entry['rule'])
            if key in accepted:
                raise ValueError('duplicate acceptance')
            accepted[key] = entry['reason']
        return accepted
    except (ValueError, UnicodeError) as error:
        raise ReadError(f'cannot read {ACCEPTANCES}: {error}') from error


def unaccepted_findings(findings, commit, acceptances):
    remaining = []
    for finding in findings:
        reason = acceptances.get((commit, *finding))
        if reason is None or finding[2] in ('public-policy-weakened', 'private-path-list-deleted', 'briefing-pin'):
            remaining.append(finding)
        else:
            path, line, rule = finding
            # JSON quoting keeps even unusual paths/reasons on one output line.
            print(f'commit {commit}: accepted {json.dumps(path)}:{line}: {rule}: {json.dumps(reason)}')
    return remaining


def head_snapshot():
    # --revs-only omits an unresolved HEAD but still propagates Git failures.
    revision = git('rev-parse', '--revs-only', 'HEAD').strip()
    return Snapshot(revision.decode('ascii')) if revision else None


def comparison_parent(parents):
    first = next(parents, None)
    if first and PATHS in first.entries:
        return first
    # On a merge into pre-guard history, additions are relative to the guarded
    # side. Initial adoption, with no guarded parent, keeps its original baseline.
    return next((parent for parent in parents if PATHS in parent.entries), first)


def staged_parents():
    head = head_snapshot()
    if head is None:
        return
    yield head
    merge_head = Path(os.fsdecode(git('rev-parse', '--git-path', 'MERGE_HEAD').strip()))
    try:
        merge_head.lstat()
    except FileNotFoundError:
        return
    revisions = disk_bytes(merge_head).splitlines()
    if not revisions:
        raise ReadError('cannot read empty MERGE_HEAD')
    for revision in revisions:
        if not re.fullmatch(b'[0-9a-fA-F]{40}|[0-9a-fA-F]{64}', revision):
            raise ReadError('cannot read invalid MERGE_HEAD')
        yield Snapshot(revision.decode('ascii'))


def is_ancestor(ancestor, commit):
    result = subprocess.run(['git', 'merge-base', '--is-ancestor', ancestor, commit],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode not in (0, 1):
        raise ReadError('cannot check ancestry: ' + result.stderr.decode('utf-8', 'replace'))
    return result.returncode == 0


def public_adoption(revision):
    # The first-parent policy lineage identifies this repository's adoption,
    # never an unrelated side history's copy of the guard or its settings.
    changes = git('log', '--first-parent', '--reverse', '--format=%H', revision, '--', SETTINGS)
    for commit in changes.decode().splitlines():
        snapshot = Snapshot(commit)
        if SETTINGS in snapshot.entries and PATHS in snapshot.entries and public_layout(snapshot):
            return commit
    return None


def public_ancestry(adoption, revisions, commit=None):
    foreign = [revision for revision in revisions if not is_ancestor(adoption, revision)]
    prefix = f'commit {commit}: ' if commit else ''
    for revision in foreign:
        print(f'{prefix}public-guard-ancestry: {revision} does not descend '
              f'from public guard adoption {adoption}', file=sys.stderr)
    return not foreign


def public_destination(remote):
    # Git supplies the actual push URL (including pushurl/insteadOf expansion).
    if '://' not in remote:
        match = re.fullmatch(r'(?:[^/@:]+@)?([^/:]+):(.+)', remote)
        if not match:
            return False
        _, path = match.groups()
    else:
        parsed = urlsplit(remote)
        path = parsed.path
    path = unquote(path).strip('/').casefold()
    if path.endswith('.git'):
        path = path[:-4]
    return path == 'jaredatch/pensieve'


def cached_adoption(revision, cache):
    if revision not in cache:
        cache[revision] = public_adoption(revision)
    return cache[revision]


def pre_push(remote, before, after, ref, cache=None):
    """Check committed objects before transport; never depend on checkout HEAD."""
    if not remote:
        raise ReadError('pre-push: empty remote URL')
    if set(after) == {'0'}:
        return 0  # Only the scan skips deletions; the kit's gates still run.
    cache = {} if cache is None else cache
    adoptions = cache.setdefault('adoptions', {})

    tip = git('rev-parse', '--verify', after + '^{commit}').decode().strip()
    adoption = cached_adoption(tip, adoptions)
    if public_destination(remote) and not adoption:
        print('pre-push: public-guard-ancestry: public destination requires adoption at pushed tip', file=sys.stderr)
        return 1
    if not adoption:
        if 'head_adoption' not in cache:
            head = head_snapshot()
            cache['head_adoption'] = cached_adoption(head.revision, adoptions) if head else None
        adoption = cache['head_adoption']
    if not adoption:
        return 0  # Today's single repository and the nested records repository.
    if set(before) == {'0'}:
        if 'default_tip' not in cache:
            advertised = git('ls-remote', '--symref', '--', remote, 'HEAD').decode().splitlines()
            defaults = [line.split('\t')[0][5:] for line in advertised
                        if line.startswith('ref: refs/heads/') and line.endswith('\tHEAD')]
            tips = [line.split('\t')[0] for line in advertised
                    if re.fullmatch(r'[0-9a-f]{40,64}\tHEAD', line)]
            if len(defaults) != 1 or len(tips) != 1:
                raise ReadError('cannot resolve remote default branch for new ref ' + ref)
            cache['default_tip'] = tips[0]
        before = cache['default_tip']
    if not subprocess.run(['git', 'cat-file', '-e', before + '^{commit}'],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        git('fetch', '--no-tags', '--no-write-fetch-head', '--', remote, before)
    base = git('rev-parse', '--verify', before + '^{commit}').decode().strip()
    ranges = cache.setdefault('ranges', {})
    if (base, tip) in ranges:
        return ranges[base, tip]
    remote_adoption = cached_adoption(base, adoptions)
    if remote_adoption and not public_ancestry(remote_adoption, [tip]):
        return 1
    personal_terms(None, private_paths(Snapshot(adoption)), required=True)
    print(f'pre-push: public hygiene {ref}: {base}..{tip}', file=sys.stderr)
    result = main(['--range', base + '..' + tip, '--require-personal-terms'], adoption_cache=adoptions)
    ranges[base, tip] = result
    return result


def pre_push_batch(remote, data):
    if not remote:
        raise ReadError('pre-push: empty remote URL')
    cache = {}
    for line in data.splitlines():
        fields = line.split()
        if len(fields) != 4:
            raise ReadError('invalid pre-push ref record')
        _, after, ref, before = fields
        if not all(re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', oid) for oid in (after, before)):
            raise ReadError('invalid pre-push object ID')
        result = pre_push(remote, before, after, ref, cache)
        if result:
            return result
    return 0


def main(argv=None, *, adoption_cache=None):
    adoption_cache = {} if adoption_cache is None else adoption_cache
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--tree', action='store_true', help='scan tracked working files')
    modes.add_argument('--range', metavar='BASE..HEAD', help='replay each pushed commit')
    modes.add_argument('--self-test', action='store_true')
    modes.add_argument('--project-check', action='store_true',
                       help='hook index when Git supplies GIT_INDEX_FILE, otherwise stdin diff')
    modes.add_argument('--pre-push', nargs=4, metavar=('REMOTE', 'BEFORE', 'AFTER', 'REF'),
                       help='local hook: check every pushed ref before publication')
    modes.add_argument('--pre-push-batch', metavar='REMOTE', help='local hook: read all refs from stdin')
    parser.add_argument('--require-personal-terms', action='store_true', help='require local audit terms')
    parser.add_argument('--personal-terms', help='private terms file; overrides worktree/main discovery')
    args = parser.parse_args(argv)
    if args.self_test:
        import hygiene_self_test
        return hygiene_self_test.run()
    try:
        root = os.fsdecode(git('rev-parse', '--show-toplevel').rstrip(b'\n'))
        os.chdir(root)
        failed = False
        if args.pre_push_batch is not None:
            return pre_push_batch(args.pre_push_batch, sys.stdin.read())
        if args.pre_push:
            return pre_push(*args.pre_push)
        if args.project_check and 'GIT_INDEX_FILE' not in os.environ:
            findings = scan_project_diff(sys.stdin.buffer.read(), args.personal_terms)
            report(findings)
            failed = bool(findings)
        elif args.range:
            if args.range.count('..') != 1 or '...' in args.range or args.range.startswith('-'):
                raise ReadError('cannot read range: expected BASE..HEAD')
            base, tip = args.range.split('..')
            if not base or not tip:
                raise ReadError('cannot read range: expected BASE..HEAD')
            base = git('rev-parse', '--verify', base + '^{commit}').decode().strip()
            tip = git('rev-parse', '--verify', tip + '^{commit}').decode().strip()
            acceptances = range_acceptances(base)
            adoption = cached_adoption(base, adoption_cache) or cached_adoption(tip, adoption_cache)
            floor = Snapshot(adoption) if adoption else None
            introductions = [] if adoption else git(
                'log', '--full-history', '--format=%H', '--diff-filter=A', base, tip, '--',
                'script/public_hygiene.py', PATHS).decode().splitlines()
            commits = git('rev-list', '--reverse', '--topo-order', args.range).decode().splitlines()
            for commit in commits:
                try:
                    parents = git('rev-list', '--parents', '-n', '1', commit).decode().split()
                    if adoption:
                        # Every merge parent is checked even if excluded by BASE..TIP.
                        judged = parents if len(parents) > 2 else [commit]
                        if not public_ancestry(adoption, judged, commit):
                            failed = True
                            continue
                    elif not any(is_ancestor(start, commit) for start in introductions):
                        print(f'commit {commit}: skipped (predates public hygiene guard)')
                        continue
                    previous = comparison_parent(Snapshot(parent) for parent in parents[1:])
                    current = Snapshot(commit)
                    findings = scan(current, previous, args.personal_terms, floor=floor,
                                    require_terms=args.require_personal_terms)
                    findings = unaccepted_findings(findings, commit, acceptances)
                    report(findings, commit)
                    failed |= bool(findings)
                except ReadError as error:
                    raise ReadError(f'commit {commit}: {error}') from error
        else:
            current = Snapshot(working=args.tree)
            parents = [] if args.tree else list(staged_parents())
            adoption = None
            for parent in parents:
                adoption = public_adoption(parent.revision)
                if adoption:
                    break
            if adoption and not public_ancestry(adoption, [parent.revision for parent in parents]):
                return 1
            floor = Snapshot(adoption) if adoption else None
            findings = scan(current, comparison_parent(iter(parents)), args.personal_terms,
                            tree=args.tree, floor=floor, require_terms=not args.tree or args.require_personal_terms)
            report(findings)
            failed = bool(findings)
        return 1 if failed else 0
    except (ReadError, OSError) as error:
        print(f'public-hygiene: {error}; scan incomplete', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
