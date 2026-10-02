// Sketch run_code script: every visible text layer (through symbol instances, string and visibility
// overrides honored) and every enabled fill in one frame, as absolute frame-relative points.
// Set FRAME_ID and MIN_X; paste the whole file as one run_code call. Output: {"texts":[[name, text,
// x, y, w, h, textColor, sharedStyleName, alignment], …], "fills":[[name, x, y, w, h, colors, radii], …]}.
// Feed the JSON to script/sketch/measure_ink.py; the API cannot read font size or weight.
const sketch = require('sketch'); const doc = sketch.getSelectedDocument();
var FRAME_ID = 'F9DDBD95-D6E6-423C-BFAB-B74F3EC7EE66', MIN_X = 460;
var frame = sketch.find('#' + FRAME_ID, doc)[0]; var texts = [], fills = [];
function ovs(inst){ var s = {}, v = {}; inst.overrides.forEach(function(o){ if (o.property === 'stringValue') s[o.path] = o.value; if (o.property === 'isVisible') v[o.path] = o.value; }); return {s: s, v: v}; }
function walk(l, ox, oy, path, os, ov, depth){ if (l.hidden) return; var p = path.concat(l.id).join('/'); if (ov[p] === false) return; var f = l.frame; var ax = ox + f.x, ay = oy + f.y;
  if (l.type === 'Text') { var t = os[p] !== undefined ? os[p] : l.text; texts.push([l.name, String(t).slice(0,44), Math.round(ax*2)/2, Math.round(ay*2)/2, f.width, f.height, l.style.textColor, l.sharedStyle ? l.sharedStyle.name : null, l.style.alignment]); return; }
  if (l.type === 'SymbolInstance') { var o = ovs(l); var ms = {}, mv = {}; Object.keys(os).forEach(function(k){ if (k.indexOf(l.id + '/') === 0) ms[k.slice(l.id.length + 1)] = os[k]; }); Object.keys(ov).forEach(function(k){ if (k.indexOf(l.id + '/') === 0) mv[k.slice(l.id.length + 1)] = ov[k]; }); Object.keys(o.s).forEach(function(k){ ms[k] = o.s[k]; }); Object.keys(o.v).forEach(function(k){ mv[k] = o.v[k]; }); if (l.master && depth < 6) { if (l.master.background && l.master.background.enabled) fills.push([l.name + ' (master bg)', Math.round(ax*2)/2, Math.round(ay*2)/2, f.width, f.height, l.master.background.color, null]); l.master.layers.forEach(function(c){ walk(c, ax, ay, [], ms, mv, depth + 1); }); } return; }
  if (l.style && l.style.fills) { var fl = l.style.fills.filter(function(x){ return x.enabled; }).map(function(x){ return x.color; }); if (fl.length && l.type !== 'Group') fills.push([l.name, Math.round(ax*2)/2, Math.round(ay*2)/2, f.width, f.height, fl.join(','), l.style.corners ? l.style.corners.radii : null]); }
  if (l.layers) l.layers.forEach(function(c){ walk(c, ax, ay, path, os, ov, depth); }); }
frame.layers.forEach(function(c){ walk(c, 0, 0, [], {}, {}, 0); });
console.log(JSON.stringify({texts: texts.filter(function(t){ return t[2] >= MIN_X; }), fills: fills.filter(function(t){ return t[1] >= MIN_X && t[3] > 8; })}));
