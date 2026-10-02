"""Horizontal separator finder: rows darker than the region median inside x0 y0 x1 y1 (points) on an alpha-cropped 2x image. Usage: hlines.py img@2x.png x0 y0 x1 y1"""
import sys, numpy as np
from PIL import Image
src, x0, y0, x1, y1 = sys.argv[1], *map(float, sys.argv[2:6])
a = np.array(Image.open(src).convert('RGBA')); al = a[:,:,3] >= 250; ys, xs = np.where(al); c = a[ys.min():ys.max()+1, xs.min():xs.max()+1][:,:,:3].astype(int)
reg = c[int(y0*2):int(y1*2), int(x0*2):int(x1*2)]
rowmean = reg.mean(axis=(1,2)); base = np.median(rowmean)
lines = [i for i, v in enumerate(rowmean) if v < base - 3]
out = []; 
for i in lines:
    if out and i - out[-1][-1] <= 1: out[-1].append(i)
    else: out.append([i])
print(' '.join(f"y{y0 + g[0]/2:.1f}(v{rowmean[g[0]]:.0f})" for g in out))
