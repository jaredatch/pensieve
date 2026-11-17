"""Balance XCTest classes from strict per-test timings; print other shares' classes to skip."""
import math
from pathlib import Path
import re
import sys


def plan(path, count):
    """Assign heaviest classes first to the lightest share, with stable name/index ties."""
    path = Path(path)
    try:
        lines = path.read_text().splitlines()
    except (OSError, UnicodeError) as error:
        raise ValueError(f'{path}: {error}') from error
    if not lines:
        raise ValueError(f'{path}: empty timings file')
    tests = {}
    for number, line in enumerate(lines, 1):
        fields = line.split()
        if len(fields) != 2 or len(fields[0].split('/')) != 3 or not all(fields[0].split('/')):
            raise ValueError(f'{path}:{number}: expected <target>/<class>/<test> <seconds>')
        identifier, duration = fields
        try:
            seconds = float(duration)
        except ValueError as error:
            raise ValueError(f'{path}:{number}: invalid duration {duration!r}') from error
        if not math.isfinite(seconds) or seconds < 0:
            raise ValueError(f'{path}:{number}: duration must be finite and non-negative')
        if identifier in tests:
            raise ValueError(f'{path}:{number}: repeated identifier {identifier}')
        tests[identifier] = seconds
    weights = {}
    # Sort before summing too: input order must not change floating point ties.
    for identifier, seconds in sorted(tests.items()):
        name = identifier.rsplit('/', 1)[0]
        weights[name] = weights.get(name, 0.0) + seconds
    shares = [[] for _ in range(count)]
    totals = [0.0] * count
    for name in sorted(weights, key=lambda name: (-weights[name], name)):
        index = min(range(count), key=lambda index: (totals[index], index))
        shares[index].append(name)
        totals[index] += weights[name]
    return [sorted(share) for share in shares]


def main():
    path, shard = sys.argv[1:]
    if not re.fullmatch(r'[0-9]+/[0-9]+', shard):
        return 64
    index, count = map(int, shard.split('/'))
    if not 1 <= index <= count:
        return 64
    try:
        shares = plan(path, count)
    except ValueError as error:
        print(f'test.sh: {error}', file=sys.stderr)
        return 1
    for other, classes in enumerate(shares, 1):
        if other != index:
            for name in classes:
                print(name)
    return 0


if __name__ == '__main__':
    sys.exit(main())
