#!/usr/bin/env python3
"""Crop bands (in points, 1x) from a 2x PNG.  usage: crop.py src.png outdir name x y w h [name x y w h ...]"""
import sys, os
from PIL import Image
src, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)
img = Image.open(src)
args = sys.argv[3:]
for i in range(0, len(args), 5):
    name, x, y, w, h = args[i], *map(float, args[i+1:i+5])
    img.crop((int(x*2), int(y*2), int((x+w)*2), int((y+h)*2))).save(os.path.join(outdir, f'{name}@2x.png'))
    print(name, 'ok')
