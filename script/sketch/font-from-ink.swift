// CoreText font matcher: renders every measured string at candidate sizes and weights (SF Pro or SF Mono) and
// prints the best three by ink width, height, and coverage. Build: swiftc -O -o /tmp/font-from-ink script/sketch/font-from-ink.swift
// Run: /tmp/font-from-ink measured.json. Width is the decisive signal; weight is reliable on primary-colored text only.
import Foundation
import AppKit
struct Item: Decodable { let id: String; let name: String; let text: String; let style: String?; let color: String?; let mono: Bool?; let inkW: Double?; let inkH: Double?; let cov: Double?; let skip: String? }
let weights: [(String, NSFont.Weight)] = [("regular", .regular), ("medium", .medium), ("semibold", .semibold), ("bold", .bold)]
let sizes: [Double] = [10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 26]
func render(_ text: String, _ size: Double, _ weight: NSFont.Weight, _ mono: Bool) -> (Double, Double, Double) {
    let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
    let scale = 2.0; let tw = attr.size().width
    let W = Int((tw + 20) * scale), H = Int((size * 3) * scale)
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0, 0) }
    ctx.scaleBy(x: scale, y: scale)
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false); NSGraphicsContext.current = gc
    attr.draw(at: NSPoint(x: 5, y: size))
    NSGraphicsContext.current = nil
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var minX = W, maxX = -1, minY = H, maxY = -1, dark = 0
    for y in 0..<H { for x in 0..<W { if data[(y * W + x) * 4 + 3] >= 128 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } } }
    if maxX < 0 { return (0, 0, 0) }
    for y in minY...maxY { for x in minX...maxX { if data[(y * W + x) * 4 + 3] >= 128 { dark += 1 } } }
    let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
    return (bw / scale, bh / scale, Double(dark) / (bw * bh))
}
let items = try! JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
var cache: [String: (Double, Double, Double)] = [:]
for it in items {
    guard let iw = it.inkW, let ih = it.inkH, let ic = it.cov else { print("\(it.name)\t\(it.text)\tSKIP \(it.skip ?? "")"); continue }
    var best: [(Double, String)] = []
    for s in sizes { for (wn, w) in weights {
        let key = "\(it.text)|\(s)|\(wn)|\(it.mono ?? false)"
        let r = cache[key] ?? render(it.text, s, w, it.mono ?? false); cache[key] = r
        if r.0 == 0 { continue }
        let err = abs(r.0 - iw) / iw * 3 + abs(r.1 - ih) / ih + abs(r.2 - ic) * 2
        best.append((err, String(format: "%.0f %@ (w %.1f h %.1f cov %.2f)", s, wn, r.0, r.1, r.2)))
    } }
    best.sort { $0.0 < $1.0 }
    print(String(format: "%@\t%@\tink w %.1f h %.1f cov %.2f\t=> %@\t| %@\t| %@", it.name, it.text, iw, ih, ic, best[0].1, best[1].1, best[2].1))
}
