// Generates Anicat's "index cut" symbol set: one custom-symbol template per
// icon in icons.swift, written as .symbolset folders into an asset catalog.
// Run through scripts/build-symbols.sh, never by hand.
//
// Two constraints shape it. The symbol template accepts filled outlines only
// -- a stroke attribute is dropped and the icon renders empty -- so every
// stroke is outlined with CoreGraphics before it is written. And outlining at
// different widths gives every weight a different point structure, which
// rules out the template's interpolated weights: each of the 27 weight and
// size variants is written out in full instead.
import Foundation
import CoreGraphics

// Minimal absolute SVG path parser: M L H V C Q Z.
func parse(_ d: String) -> CGMutablePath {
    let p = CGMutablePath()
    var toks: [String] = []; var cur = ""
    for ch in d {
        if ch.isLetter { if !cur.isEmpty { toks.append(cur); cur = "" }; toks.append(String(ch)) }
        else if ch == " " || ch == "," { if !cur.isEmpty { toks.append(cur); cur = "" } }
        else if ch == "-" && !cur.isEmpty && !cur.hasSuffix("e") { toks.append(cur); cur = "-" }
        else { cur.append(ch) }
    }
    if !cur.isEmpty { toks.append(cur) }
    var i = 0; var cmd = "M"; var pt = CGPoint.zero
    func n() -> CGFloat { defer { i += 1 }; return CGFloat(Double(toks[i])!) }
    while i < toks.count {
        if Double(toks[i]) == nil { cmd = toks[i]; i += 1; if cmd == "Z" { p.closeSubpath(); continue } }
        switch cmd {
        case "M": pt = CGPoint(x: n(), y: n()); p.move(to: pt); cmd = "L"
        case "L": pt = CGPoint(x: n(), y: n()); p.addLine(to: pt)
        case "H": pt.x = n(); p.addLine(to: pt)
        case "V": pt.y = n(); p.addLine(to: pt)
        case "C": let c1 = CGPoint(x: n(), y: n()), c2 = CGPoint(x: n(), y: n()); pt = CGPoint(x: n(), y: n()); p.addCurve(to: pt, control1: c1, control2: c2)
        case "Q": let c = CGPoint(x: n(), y: n()); pt = CGPoint(x: n(), y: n()); p.addQuadCurve(to: pt, control: c)
        default: fatalError("unsupported \(cmd)")
        }
    }
    return p
}

/// One drawing element on the 24-unit grid: a stroked line, a filled shape,
/// or a cut: `x` clears a gap around a line (the slash variants), `h` cuts a
/// stroke-wide line out of a fill, `xf` cuts a filled shape out of a fill.
enum El { case s(CGPath); case f(CGPath); case x(CGPath); case xf(CGPath); case h(CGPath) }
func P(_ d: String) -> CGPath { parse(d) }
func arc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ a0: CGFloat, _ a1: CGFloat, cw: Bool = false) -> CGPath {
    let p = CGMutablePath(); p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: a0 * .pi / 180, endAngle: a1 * .pi / 180, clockwise: cw); return p
}
func mirror(_ els: [El]) -> [El] {
    var t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 24, ty: 0)
    func m(_ p: CGPath) -> CGPath { p.copy(using: &t)! }
    return els.map { switch $0 { case .s(let p): return .s(m(p)); case .f(let p): return .f(m(p)); case .x(let p): return .x(m(p)); case .xf(let p): return .xf(m(p)); case .h(let p): return .h(m(p)) } }
}
let strokeW: CGFloat = 1.3

func outline(_ els: [El], _ w: CGFloat = strokeW) -> CGPath {
    var acc: CGPath? = nil
    for e in els {
        let piece: CGPath
        switch e {
        case .s(let p): piece = p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 4)
        case .f(let p):
            // Filled shapes get the same round-join stroke as outlines so their
            // silhouette matches the stroked icons' corner softness.
            piece = p.union(p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 4))
        case .x(let p):
            // A knockout: the stroke plus a gap of one stroke width either side.
            let hole = p.copy(strokingWithWidth: w * 2.6, lineCap: .round, lineJoin: .round, miterLimit: 4)
            acc = acc?.subtracting(hole); continue
        case .h(let p):
            // A line cut out of a filled shape, as wide as the drawn stroke.
            acc = acc?.subtracting(p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 4)); continue
        case .xf(let p):
            // A filled shape punched out of a filled one, at its drawn size.
            acc = acc?.subtracting(p.union(p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 4))); continue
        }
        acc = acc.map { $0.union(piece) } ?? piece
    }
    return acc!
}

func svgD(_ path: CGPath, _ t: CGAffineTransform) -> String {
    var out = ""
    func f(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
    func P(_ q: CGPoint) -> String { let r = q.applying(t); return "\(f(r.x)) \(f(r.y))" }
    path.applyWithBlock { e in
        let el = e.pointee; let pts = el.points
        switch el.type {
        case .moveToPoint: out += "M\(P(pts[0]))"
        case .addLineToPoint: out += "L\(P(pts[0]))"
        case .addQuadCurveToPoint: out += "Q\(P(pts[0])) \(P(pts[1]))"
        case .addCurveToPoint: out += "C\(P(pts[0])) \(P(pts[1])) \(P(pts[2]))"
        case .closeSubpath: out += "Z"
        @unknown default: break
        }
    }
    return out
}

// Template v3 geometry. All three sizes share a 70.459-unit cap height; a
// symbol's S and L variants are its M drawing scaled by 0.783 and 1.29,
// which is how Apple's own symbols are built. M draws the 24-unit grid at
// 5.1 units per grid unit.
let scale: CGFloat = 5.1
let bearing: CGFloat = 6
let weights: [(String, CGFloat)] = [
    ("Ultralight", 0.45), ("Thin", 0.65), ("Light", 0.95), ("Regular", 1.3), ("Medium", 1.5),
    ("Semibold", 1.7), ("Bold", 1.95), ("Heavy", 2.25), ("Black", 2.55),
]
let sizes: [(String, CGFloat, CGFloat)] = [("S", 0.783, 696), ("M", 1, 1126), ("L", 1.29, 1556)]

func template(_ els: [El]) -> String {
    // Vertical placement comes from the Regular drawing so every weight sits
    // on the same centre line instead of drifting as strokes thicken.
    let midY = outline(els, 1.3).boundingBoxOfPath.midY
    var guides = "", groups = ""
    for (si, (sz, f, baseline)) in sizes.enumerated() {
        for (wi, (wt, w)) in weights.enumerated() {
            let k = scale * f
            // The stroke is set in final template units, so a small symbol's
            // line is not thinned along with its geometry.
            let path = outline(els, w * scale / k)
            let box = path.boundingBoxOfPath
            let t = CGAffineTransform(translationX: bearing - box.minX * k, y: -35.23 - midY * k).scaledBy(x: k, y: k)
            let advance = box.width * k + 2 * bearing
            let x = 263 + CGFloat(wi) * 300
            let y0 = baseline - 95, y1 = baseline + 24
            _ = si
            guides += "  <line id=\"left-margin-\(wt)-\(sz)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5\" x1=\"\(x)\" x2=\"\(x)\" y1=\"\(y0)\" y2=\"\(y1)\"/>\n"
            guides += "  <line id=\"right-margin-\(wt)-\(sz)\" style=\"fill:none;stroke:#00AEEF;stroke-width:0.5\" x1=\"\(x + advance)\" x2=\"\(x + advance)\" y1=\"\(y0)\" y2=\"\(y1)\"/>\n"
            groups += "  <g id=\"\(wt)-\(sz)\" transform=\"matrix(1 0 0 1 \(x) \(baseline))\">\n   <path d=\"\(svgD(path, t))\"/>\n  </g>\n"
        }
    }
    return """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <g id="Notes">
  <text id="template-version" x="3036" y="1933" style="font-family:'LucidaGrande';font-size:13">Template v.3.0</text>
 </g>
 <g id="Guides">
  <line id="Baseline-S" style="fill:none;stroke:#27AAE1;stroke-width:0.5" x1="263" x2="3036" y1="696" y2="696"/>
  <line id="Capline-S" style="fill:none;stroke:#27AAE1;stroke-width:0.5" x1="263" x2="3036" y1="625.541" y2="625.541"/>
  <line id="Baseline-M" style="fill:none;stroke:#27AAE1;stroke-width:0.5" x1="263" x2="3036" y1="1126" y2="1126"/>
  <line id="Capline-M" style="fill:none;stroke:#27AAE1;stroke-width:0.5" x1="263" x2="3036" y1="1055.54" y2="1055.54"/>
  <line id="Baseline-L" style="fill:none;stroke:#27AAE1;stroke-width:0.5" x1="263" x2="3036" y1="1556" y2="1556"/>
  <line id="Capline-L" style="fill:none;stroke:#27AAE1;stroke-width:0.5" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>
\(guides) </g>
 <g id="Symbols">
\(groups) </g>
</svg>

"""
}

let icons = makeIcons()
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, els) in icons {
    let dir = outDir.appendingPathComponent("\(name).symbolset")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! template(els).write(to: dir.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
    let contents = #"{"info":{"author":"xcode","version":1},"symbols":[{"filename":"\#(name).svg","idiom":"universal"}]}"#
    try! contents.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}
print("wrote \(icons.count)")
