import sys, json, numpy as np
from PIL import Image
"""Ink measurement: for each text in a text_inventory.js JSON, the ink width, height, and coverage inside its box on a 2x export (alpha-cropped first). Usage: measure_ink.py inventory.json export@2x.png out.json; pipe out.json to font-from-ink."""
inv, png, out = sys.argv[1], sys.argv[2], sys.argv[3]
a = np.array(Image.open(png).convert('RGBA')); al = a[:,:,3] >= 250
ys, xs = np.where(al); crop = a[ys.min():ys.max()+1, xs.min():xs.max()+1][:,:,:3].astype(int)
H, W = crop.shape[:2]
items = []
for i, t in enumerate(json.load(open(inv))['texts']):
    name, text, x, y, w, h, color, style, align = t
    if any(0xF0000 <= ord(c) <= 0x10FFFF for c in text): continue
    ml = h > 22 and len(text) > 30
    hh = h/2 if ml else h
    x0, y0, x1, y1 = int(x*2), max(0, int((y-3)*2)), min(W, int((x+w)*2)), min(H, int((y+hh+2)*2))
    reg = crop[y0:y1, x0:x1]
    if reg.size == 0: continue
    flat = reg.reshape(-1, 3); vals, counts = np.unique(flat, axis=0, return_counts=True); bg = vals[counts.argmax()]
    dist = np.abs(reg - bg).sum(axis=2)
    mx = dist.max()
    if mx < 60: items.append({"id": str(i), "name": name, "text": text, "skip": "no ink"}); continue
    ink = dist >= max(40, 0.5*mx)
    rows = np.where(ink.any(axis=1))[0]; cols = np.where(ink.any(axis=0))[0]
    bb = ink[rows.min():rows.max()+1, cols.min():cols.max()+1]
    items.append({"id": str(i), "name": name, "text": text, "style": style, "color": color, "mono": style is not None and "mono" in style.lower(),
                  "inkW": (cols.max()+1-cols.min())/2, "inkH": (rows.max()+1-rows.min())/2, "cov": float(bb.mean()), "inkX": x + cols.min()/2, "inkY": (y0 + rows.min())/2})
json.dump(items, open(out, 'w'), indent=0)
print(len(items), "measured")
