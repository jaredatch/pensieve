#!/usr/bin/env python3
"""Reduce a cua-driver get_window_state raw JSON to window-relative frames.

usage: reduce_ax.py raw.json out.ax.json out.ax.md win_x win_y
"""
import json, sys

raw, out_json, out_md, wx, wy = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), float(sys.argv[5])
d = json.load(open(raw))
sc = d['structuredContent'] if 'structuredContent' in d else d
els = sc['elements']
reduced = []
for e in els:
    fr = e.get('frame') or e.get('bounds') or {}
    r = {
        'i': e.get('element_index'),
        'role': e.get('role'),
        'label': e.get('label') or e.get('title') or '',
        'value': e.get('value') or '',
    }
    if fr:
        r['x'] = round(fr.get('x', 0) - wx, 1)
        r['y'] = round(fr.get('y', 0) - wy, 1)
        r['w'] = round(fr.get('width', fr.get('w', 0)), 1)
        r['h'] = round(fr.get('height', fr.get('h', 0)), 1)
    reduced.append(r)
json.dump({'window': {'x': wx, 'y': wy}, 'snapshot_id': sc.get('snapshot_id'), 'elements': reduced},
          open(out_json, 'w'), indent=1, ensure_ascii=False)
open(out_md, 'w').write(sc.get('tree_markdown', ''))
print('elements', len(reduced), '->', out_json, out_md)
