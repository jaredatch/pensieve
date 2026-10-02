#!/usr/bin/env python3
"""Side-by-side, diff mask, and per-region fractions between an anchor and an export (both 2x).

usage: diff_frames.py [--halo N] anchor.png export.png outdir stem [regions.json]
regions.json: {"name": [x, y, w, h], ...} in points (1x); whole frame is always included.

Sizes must agree before anything is measured. An RGBA export that bleeds a window shadow is cropped to
its opaque alpha box (alpha >= 250) and the cropped image is written to outdir as <stem>-export-cropped@2x.png
(measure that file, not the raw export). With --halo N, an anchor at most N px larger in each dimension
(cua-driver's capture halo) is trimmed from its top-left to the export's size; without the flag, or past N,
any size difference is a SIZE MISMATCH: exit 2, nothing written. Fractions on resized images are never evidence.
"""
import json, sys, os
from PIL import Image, ImageChops

args = sys.argv[1:]
halo = 0
if args and args[0] == '--halo':
    halo = int(args[1]); args = args[2:]
anchor, export, outdir, stem = args[:4]
regions = json.load(open(args[4])) if len(args) > 4 else {}
a_raw = Image.open(anchor)
b_raw = Image.open(export)
a = a_raw.convert('RGB')
b = b_raw.convert('RGB')
cropped = False
if b_raw.mode == 'RGBA':
    bb = b_raw.split()[3].point(lambda v: 255 if v >= 250 else 0).getbbox()
    if bb and (bb[2] - bb[0], bb[3] - bb[1]) != b.size:
        b = b_raw.crop(bb).convert('RGB')
        cropped = True
        print('export alpha-cropped at', bb[:2], 'to', b.size)
if a.size != b.size and halo and 0 <= a.width - b.width <= halo and 0 <= a.height - b.height <= halo:
    a = a.crop((0, 0, b.width, b.height))
    print('anchor halo trimmed to', a.size)
if a.size != b.size:
    print('SIZE MISMATCH', a.size, b.size, '- crop first (or --halo N for a capture halo); nothing written')
    sys.exit(2)
os.makedirs(outdir, exist_ok=True)
if cropped:
    b.save(os.path.join(outdir, f'{stem}-export-cropped@2x.png'))
diff = ImageChops.difference(a, b).convert('L')
mask = diff.point(lambda p: 255 if p > 40 else 0)
side = Image.new('RGB', (a.width * 2 + 20, a.height), 'white')
side.paste(a, (0, 0)); side.paste(b, (a.width + 20, 0))
side.save(os.path.join(outdir, f'{stem}-side-by-side@2x.png'))
mask.save(os.path.join(outdir, f'{stem}-diff-mask.png'))
fr = {}
def frac(box):
    m = mask.crop(box)
    h = m.histogram()
    return round(h[255] / max(1, m.width * m.height), 4)
fr['whole'] = frac((0, 0, a.width, a.height))
for name, (x, y, w, h) in regions.items():
    fr[name] = frac((int(x * 2), int(y * 2), int((x + w) * 2), int((y + h) * 2)))
json.dump(fr, open(os.path.join(outdir, f'{stem}-diff-fractions.json'), 'w'), indent=1)
print(json.dumps(fr))
