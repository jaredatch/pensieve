# Sketch tools

Helpers for checking Sketch captures and glyphs. Run from the repo root with the paths shown. The Python ones need Pillow (and numpy for `bands.py`).

- `python3 script/sketch/reduce_ax.py raw.json out.ax.json out.ax.md win_x win_y` — turns a cua-driver `get_window_state` capture into window-relative frames (subtract the window origin) plus the tree markdown.
- `text_inventory.js` — paste as one `run_code` call with `FRAME_ID` and `MIN_X` set; prints every visible text (through symbol instances, overrides honored) with box, color, style name, and every enabled fill. Save the JSON; it is `measure_ink.py`'s input.
- `python3 script/sketch/measure_ink.py inventory.json export@2x.png measured.json` — alpha-crops the export, measures the ink inside each text box (width, height, coverage), skips SF Symbol glyphs.
- `swiftc -O -o /tmp/font-from-ink script/sketch/font-from-ink.swift && /tmp/font-from-ink measured.json` — renders each string with CoreText at 10–26 pt × regular/medium/semibold/bold (SF Mono when the style name says mono) and prints the best three; width is decisive, weight is reliable on primary-colored text.
- `python3 script/sketch/hlines.py img@2x.png x0 y0 x1 y1` — separator rows (darker than the strip's median) with their y in points; run on the export and the capture to compare row pitch.
- `python3 script/sketch/bands.py img@2x.png x0 y0 x1 y1 [threshold]` — ink bands (rows of pixels darker than the threshold, grouped) inside a region given in points; prints each band's y range, height, x range, width, and center. Run on the anchor and on the export with the same region and compare line by line.
- `python3 script/sketch/diff_frames.py [--halo N] anchor.png export.png outdir stem [regions.json]` — side-by-side, a 40/255 diff mask, and per-region mismatch fractions (regions in points, `{"name": [x, y, w, h]}`). An RGBA export with a shadow bleed is cropped to the window by its opaque alpha box and the cropped image is written as `<stem>-export-cropped@2x.png` (run `bands.py` on that, never on the raw export). `--halo N` permits trimming an anchor that is at most N px larger (cua-driver's capture halo is 2); without it, or past N, any size difference exits 2 and writes nothing.
- `python3 script/sketch/crop.py src@2x.png outdir name x y w h …` — band crops in points (the region-gate crops; not tracked).
- `swiftc -O -o /tmp/sf-glyph-match script/sketch/sf-glyph-match.swift && /tmp/sf-glyph-match` — resolves SF Symbol names to the private-use code points the UI kit's text layers use (render-and-match, ~45 s): add the names to the script's `names` list first, then append the printed lines to `script/sketch/sf-glyphs.tsv` (name, code point, match distance / next-best).

Read the mask honestly: a straight line in it is a real delta (a separator, a divider, a wrap).
