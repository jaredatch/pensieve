import AppKit
let names = ["tray","folder","square.stack","square.grid.2x2","tag","display","checkmark.circle","person","doc.text","sidebar.leading","line.3.horizontal.decrease","ellipsis","plus","chevron.down","chevron.left.forwardslash.chevron.right","clock.arrow.circlepath","trash","magnifyingglass","sparkles","arrow.triangle.2.circlepath","arrow.triangle.branch","xmark.circle.fill","terminal","terminal.fill","doc.plaintext","pawprint","scroll","chevron.down","checkmark.circle.fill","circle.dashed","questionmark.circle"]
let N = 28
func norm(_ img: NSImage) -> [Float]? {
  let w = 160, h = 160
  guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSColor.white.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
  let sz = img.size
  let scale = min(120.0 / max(sz.width, 1), 120.0 / max(sz.height, 1))
  let dw = sz.width * scale, dh = sz.height * scale
  img.draw(in: NSRect(x: (160 - dw) / 2, y: (160 - dh) / 2, width: dw, height: dh), from: .zero, operation: .sourceOver, fraction: 1)
  NSGraphicsContext.restoreGraphicsState()
  var minx = w, miny = h, maxx = -1, maxy = -1
  var gray = [Float](repeating: 0, count: w * h)
  let data = rep.bitmapData!; let bpr = rep.bytesPerRow
  for y in 0..<h { for x in 0..<w { let p = data + y * bpr + x * 4; let a = Float(p[3]) / 255; let lum = (Float(p[0]) + Float(p[1]) + Float(p[2])) / (3 * 255); let v = a * (1 - lum) + (1 - a) * 0; gray[y * w + x] = v; if v > 0.3 { minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y) } } }
  if maxx < 0 { return nil }
  let bw = maxx - minx + 1, bh = maxy - miny + 1
  var out = [Float](repeating: 0, count: N * N)
  let side = max(bw, bh)
  let ox = minx - (side - bw) / 2, oy = miny - (side - bh) / 2
  for j in 0..<N { for i in 0..<N {
    let x0 = ox + i * side / N, x1 = ox + (i + 1) * side / N, y0 = oy + j * side / N, y1 = oy + (j + 1) * side / N
    var s: Float = 0; var c: Float = 0
    for y in max(y0,0)..<min(max(y1,y0+1),h) { for x in max(x0,0)..<min(max(x1,x0+1),w) { s += gray[y * w + x]; c += 1 } }
    out[j * N + i] = c > 0 ? s / c : 0
  } }
  return out
}
func textImage(_ s: String) -> NSImage {
  let font = NSFont.systemFont(ofSize: 64, weight: .regular)
  let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.black])
  let sz = attr.size()
  let img = NSImage(size: NSSize(width: max(sz.width, 1), height: max(sz.height, 1)))
  img.lockFocus(); attr.draw(at: .zero); img.unlockFocus()
  return img
}
let base = NSFont.systemFont(ofSize: 64) as CTFont
let probe = "\u{100215}" as CFString
let fb = CTFontCreateForString(base, probe, CFRangeMake(0, 2))
var cands: [(UInt32, [Float])] = []
for cp in UInt32(0x100000)...UInt32(0x101FFF) {
  guard let sc = UnicodeScalar(cp) else { continue }
  var ch = Array(String(sc).utf16); var gl = [CGGlyph](repeating: 0, count: 2)
  _ = CTFontGetGlyphsForCharacters(fb, &ch, &gl, 2)
  if gl[0] == 0 { continue }
  if let v = norm(textImage(String(sc))) { cands.append((cp, v)) }
}
FileHandle.standardError.write("candidates: \(cands.count)\n".data(using: .utf8)!)
for n in names {
  guard let img = NSImage(systemSymbolName: n, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 64, weight: .regular)), let v = norm(img) else { print("\(n)\tNOIMG"); continue }
  var best: [(Float, UInt32)] = []
  for (cp, c) in cands { var d: Float = 0; for i in 0..<(N*N) { d += abs(c[i] - v[i]) }; best.append((d, cp)) }
  best.sort { $0.0 < $1.0 }
  print(String(format: "%@\tU+%X\t%.1f\tnext U+%X %.1f", n, best[0].1, best[0].0, best[1].1, best[1].0))
}
