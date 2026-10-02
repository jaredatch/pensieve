"""Check a push locally using the same range and tree guard as CI.

The caller checks out the pushed head with full history and the default branch.
New refs are compared with that branch, retaining its history acceptances. A
missing old tip is fetched by ID; if unavailable, use the new-ref comparison.
For a push to the default branch itself, that fallback starts before adoption.
Deletions need no checkout.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

from public_hygiene import ReadError, git, public_adoption, public_ancestry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', required=True)
    parser.add_argument('--after', required=True)
    parser.add_argument('--default-branch', default='master')
    parser.add_argument('--ref', default=os.environ.get('GITHUB_REF'),
                        help='pushed refs/heads/... or refs/tags/...; defaults to GITHUB_REF')
    args = parser.parse_args()
    try:
        for name, value in (('before', args.before), ('after', args.after)):
            if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', value):
                raise ReadError(f'{name} must be a full object ID')
        if set(args.after) == {'0'}:
            print('Deleted ref; no added commits or pushed tree.')
            return 0
        if not args.ref or not args.ref.startswith(('refs/heads/', 'refs/tags/')):
            raise ReadError('pushed ref is required (--ref or GITHUB_REF)')
        git('check-ref-format', args.ref)
        after = git('rev-parse', '--verify', args.after + '^{commit}').decode().strip()
        head = git('rev-parse', '--verify', 'HEAD').decode().strip()
        if head != after:
            raise ReadError('checkout HEAD is not the pushed head')
        git('check-ref-format', 'refs/heads/' + args.default_branch)
        default_ref = 'refs/remotes/origin/' + args.default_branch
        default = git('rev-parse', '--verify', default_ref + '^{commit}').decode().strip()
        adoption = public_adoption(default)
        if adoption is None:
            raise ReadError('default branch has no public guard adoption')
        if not public_ancestry(adoption, [after]):
            return 1
        new_ref = set(args.before) == {'0'}
        if new_ref:
            before = default
        else:
            try:
                before = git('rev-parse', '--verify', args.before + '^{commit}').decode().strip()
            except ReadError:
                print(f'Old tip {args.before} missing; fetching it from origin.', flush=True)
                try:
                    git('fetch', '--no-tags', 'origin', args.before)
                    before = git('rev-parse', '--verify', args.before + '^{commit}').decode().strip()
                except ReadError as error:
                    print(f'Old tip {args.before} unavailable; judging as a new ref: {error}', flush=True)
                    before = default
                    new_ref = True
        if new_ref and args.ref == 'refs/heads/' + args.default_branch:
            # The fetched default branch already includes this push. Using it
            # as the base would hide commits added and removed before the head.
            before = git('rev-parse', '--verify', adoption + '^').decode().strip()
        guard = Path(__file__).with_name('public-hygiene.sh')
        print(f'Push range: {before}..{after}', flush=True)
        ranged = subprocess.run(['bash', guard, '--range', f'{before}..{after}'])
        print(f'Push tree: {after}', flush=True)
        tree = subprocess.run(['bash', guard, '--tree'])
        return ranged.returncode or tree.returncode
    except ReadError as error:
        print(f'public hygiene push: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
