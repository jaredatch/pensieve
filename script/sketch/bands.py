#!/usr/bin/env python3
"""Ink bands (points) in a 2x PNG region. usage: bands.py img.png x0 y0 x1 y1 [threshold]  (region in points)"""
import sys
from PIL import Image
import numpy as np
path = sys.argv[1]
x0, y0, x1, y1 = [int(float(v) * 2) for v in sys.argv[2:6]]
thr = int(sys.argv[6]) if len(sys.argv) > 6 else 200
im = np.array(Image.open(path).convert('L')).astype(int)
reg = im[y0:y1, x0:x1]
ink = reg < thr
rows = np.where(ink.any(axis=1))[0]
if len(rows) == 0:
    print('no ink'); sys.exit()
out = []; start = rows[0]; prev = rows[0]
for r in rows[1:]:
    if r > prev + 3: out.append((start, prev)); start = r
    prev = r
out.append((start, prev))
for a, b in out:
    cols = np.where(ink[a:b + 1].any(axis=0))[0]
    print(f'y {(a+y0)/2:.1f}-{(b+y0+1)/2:.1f} h {(b-a+1)/2:.1f}  x {(cols[0]+x0)/2:.1f}-{(cols[-1]+x0+1)/2:.1f} w {(cols[-1]-cols[0]+1)/2:.1f} cx {(cols[0]+cols[-1]+1+2*x0)/4:.2f}')
