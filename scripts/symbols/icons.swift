import CoreGraphics

// Index cut: every enclosure is a box with its top-right corner clipped.
func tab(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGFloat = 3.5) -> String {
    "M\(x) \(y)H\(x + w - c)L\(x + w) \(y + c)V\(y + h)H\(x)Z"
}
func tabP(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGFloat = 3.5) -> CGPath { P(tab(x, y, w, h, c)) }

// Shared pieces.
let playTri = "M7 4L17.5 10.2V13.8L7 20Z"
let smallPlay = "M9.6 8.2L15 11.4V12.6L9.6 15.8Z"
let speaker = "M3.5 9.5H7L11.5 5.5V18.5L7 14.5H3.5Z"
let wave1 = "M14.5 9.2Q16.2 12 14.5 14.8"
let wave2 = "M17.4 6.6Q20.6 12 17.4 17.4"
let slash = "M4 4L20 20"
// Skip intro (chosen variant C): an arrow jumping over the intro block.
let skipBase: [El] = [.s(P("M2.5 19.5H21.5")), .s(P("M4 12C6 4.5 15.5 4 18.5 10.5")), .s(P("M15.4 9.8L18.6 10.8L19.6 7.6"))]
let skipBlock = "M7 19.5V14.5H13L15 16.5V19.5"
// Go-forward loop: a clipped box whose clipped corner is the gap.
let goLoop = "M20 11V18Q20 20 18 20H6Q4 20 4 18V8Q4 6 6 6H14"
let goHead = "M11.4 3.2L14.2 6L11.4 8.8"
func digits(_ s: String, _ cx: CGFloat, _ cy: CGFloat) -> [El] {
    // Tiny stroked numerals, 4 wide by 6 tall, for the seek icons.
    let glyph: [Character: String] = [
        "1": "M-1 -2L0.6 -3V3",
        "0": "M-1.6 -1.6Q-1.6 -3 0 -3Q1.6 -3 1.6 -1.6V1.6Q1.6 3 0 3Q-1.6 3 -1.6 1.6Z",
        "5": "M1.6 -3H-1.4L-1.6 -0.2Q0 -0.9 1 -0.4Q1.8 0.2 1.6 1.6Q1.2 3 -0.2 3Q-1.3 3 -1.8 2.2",
    ]
    let adv: CGFloat = 4.2
    var out: [El] = []
    for (i, ch) in s.enumerated() {
        var t = CGAffineTransform(translationX: cx + (CGFloat(i) - CGFloat(s.count - 1) / 2) * adv, y: cy)
        out.append(.s(P(glyph[ch]!).copy(using: &t)!))
    }
    return out
}
func rays(_ cx: CGFloat, _ cy: CGFloat, _ r0: CGFloat, _ r1: CGFloat, _ n: Int, _ start: CGFloat = 0) -> [El] {
    (0..<n).map { i in
        let a = (start + CGFloat(i) * 360 / CGFloat(n)) * .pi / 180
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cx + cos(a) * r0, y: cy + sin(a) * r0))
        p.addLine(to: CGPoint(x: cx + cos(a) * r1, y: cy + sin(a) * r1))
        return .s(p)
    }
}


// The "circle" enclosure of SF Symbols, as an index-cut box.
let encl = tabP(3.5, 3.5, 17, 17, 4)
func dot(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat = 0.85) -> CGPath { P("M\(cx - r) \(cy - r)H\(cx + r)V\(cy + r)H\(cx - r)Z") }
func gear(_ cx: CGFloat, _ cy: CGFloat, _ ro: CGFloat, _ ri: CGFloat, _ n: Int) -> CGPath {
    let p = CGMutablePath()
    let step = 2 * CGFloat.pi / CGFloat(n)
    for i in 0..<n {
        let a = CGFloat(i) * step
        let pts: [(CGFloat, CGFloat)] = [(ri, a - step * 0.5), (ri, a - step * 0.22), (ro, a - step * 0.14), (ro, a + step * 0.14), (ri, a + step * 0.22)]
        for (k, (r, ang)) in pts.enumerated() {
            let q = CGPoint(x: cx + cos(ang) * r, y: cy + sin(ang) * r)
            if i == 0 && k == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
    }
    p.closeSubpath(); return p
}
let wifiArcs: [El] = [.s(arc(12, 19, 5, 225, 315)), .s(arc(12, 19, 9.5, 225, 315)), .s(arc(12, 19, 14, 232, 308)), .f(dot(12, 19, 1.1))]
let bookClosed = "M5 4.5Q5 3 6.5 3H15.5L19 6.5V21H6.5Q5 21 5 19.5Z"
let bookOpen = "M12 6.5Q8.5 4 3 4.5V18.5Q8.5 18 12 20.5Q15.5 18 21 18.5V8L17.5 4.5Q14.5 4.5 12 6.5Z"
let heartP = "M12 20L4.2 12.2Q2.5 10.5 2.8 8Q3.4 4.8 6.6 4.6Q9.6 4.5 12 7.4Q14.4 4.5 17.2 4.6L21.2 8.6Q21.3 10.7 19.8 12.2Z"
let triP = "M10.6 4H13.4L21 19.5H3Z"

func makeIcons() -> [String: [El]] {
var icons: [String: [El]] = [:]
func fan(_ cx: CGFloat, _ cy: CGFloat, _ r0: CGFloat, _ r1: CGFloat, _ angles: [CGFloat]) -> [El] {
    angles.flatMap { rays(cx, cy, r0, r1, 1, $0) }
}

// MARK: Player
icons["play.fill"] = [.f(P(playTri))]
icons["pause.fill"] = [.f(tabP(5.5, 4, 4.5, 16, 0)), .f(tabP(14, 4, 4.5, 16, 2))]
icons["playpause"] = [.f(P("M3 6L10.5 11.2V12.8L3 18Z")), .s(P("M14.5 6V18")), .s(P("M19 7.5V18")), .s(P("M17.6 6H19"))]
icons["play.circle"] = [.s(tabP(3.5, 3.5, 17, 17, 4)), .f(P(smallPlay))]
icons["play.circle.fill"] = [.f(tabP(3.5, 3.5, 17, 17, 4)), .xf(P(smallPlay))]
icons["play.rectangle"] = [.s(tabP(2.5, 5, 19, 14, 4)), .f(P(smallPlay))]
icons["play.slash"] = [.s(P(playTri)), .x(P(slash)), .s(P(slash))]
icons["play.square.stack"] = [.s(tabP(3, 8, 14.5, 13, 3)), .s(P("M6.5 4.8H18L21 7.8V17.5")), .f(P("M8 11.4L12.8 14.2V15.2L8 18Z"))]
icons["play.square.stack.fill"] = [.f(tabP(3, 8, 14.5, 13, 3)), .s(P("M6.5 4.8H18L21 7.8V17.5")), .xf(P("M8 11.4L12.8 14.2V15.2L8 18Z"))]
icons["forward.fill"] = [.f(P("M3 5L11 10.4V13.6L3 19Z")), .f(P("M12.5 5L20.5 10.4V13.6L12.5 19Z"))]
icons["forward.end"] = [.s(P("M5 5L13 10.4V13.6L5 19Z")), .s(P("M18 5V19"))]
icons["forward.end.fill"] = [.f(P("M5 5L13 10.4V13.6L5 19Z")), .s(P("M18 5V19"))]
icons["backward.end"] = mirror(icons["forward.end"]!)
icons["backward.end.fill"] = mirror(icons["forward.end.fill"]!)
icons["forward.frame"] = skipBase + [.s(P(skipBlock))]
icons["forward.circle"] = skipBase + [.s(P(skipBlock))]
icons["forward.circle.fill"] = skipBase + [.f(P(skipBlock))]
icons["goforward"] = [.s(P(goLoop)), .s(P(goHead))]
icons["goforward.5"] = icons["goforward"]! + digits("5", 12, 13.5)
icons["goforward.10"] = icons["goforward"]! + digits("10", 12, 13.5)
icons["gobackward"] = mirror(icons["goforward"]!)
icons["gobackward.5"] = icons["gobackward"]! + digits("5", 12, 13.5)
icons["gobackward.10"] = icons["gobackward"]! + digits("10", 12, 13.5)
icons["speaker.fill"] = [.f(P(speaker))]
icons["speaker.wave.1.fill"] = [.f(P(speaker)), .s(P(wave1))]
icons["speaker.wave.2"] = [.s(P(speaker)), .s(P(wave1)), .s(P(wave2))]
icons["speaker.wave.2.fill"] = [.f(P(speaker)), .s(P(wave1)), .s(P(wave2))]
icons["speaker.slash"] = [.s(P(speaker)), .s(P(wave1)), .x(P("M3 4L19 20")), .s(P("M3 4L19 20"))]
icons["speaker.slash.fill"] = [.f(P(speaker)), .s(P(wave1)), .x(P("M3 4L19 20")), .s(P("M3 4L19 20"))]
icons["captions.bubble"] = [.s(P("M3 4.5H17L21 8.5V16H10L6 19.5V16H3Z")), .s(P("M6.5 9.5H11M13.5 9.5H17.5M6.5 12.5H14.5"))]
icons["pip.enter"] = [.s(tabP(2.5, 4.5, 19, 15, 4)), .f(P("M12 12.5H18V16.5H12Z")), .s(P("M6 8L9.5 11.5M9.5 8.5V11.5H6.5"))]
icons["arrow.up.left.and.arrow.down.right"] = [.s(P("M4 10V6.5L6.5 4H10")), .s(P("M4.5 4.5L10 10")), .s(P("M20 14V20H14")), .s(P("M19.5 19.5L14 14"))]
icons["arrow.down.right.and.arrow.up.left"] = [.s(P("M4 10H7.5L10 7.5V4")), .s(P("M9.5 9.5L4 4")), .s(P("M20 14H14V20")), .s(P("M14.5 14.5L20 20"))]
icons["rotate.right"] = [.s(tabP(4, 10, 11.5, 10, 3)), .s(P("M9.5 6C13.5 3.4 18.4 4.8 19.8 9")), .s(P("M17 8.6L19.9 9.4L20.7 6.5"))]
icons["tv"] = [.s(tabP(2.5, 4.5, 19, 13.5, 4)), .s(P("M8 21H16"))]
icons["4k.tv"] = icons["tv"]! + [.s(P("M8.6 8.6L6.4 12.6H10M9 9V15")), .s(P("M12.6 8.6V15M16.4 8.6L13 11.8L16.4 15"))]
icons["light.max"] = [.s(tabP(5, 12, 14, 8, 3))] + fan(12, 12, 4, 8, [200, 235, 270, 305, 340])
icons["light.min"] = [.s(tabP(5, 12, 14, 8, 3))] + fan(12, 12, 5, 6.4, [215, 270, 325])
icons["sun.max"] = [.s(arc(12, 12, 4, 0, 360))] + rays(12, 12, 7, 9.8, 8)
icons["sun.min"] = [.s(arc(12, 12, 4, 0, 360))] + rays(12, 12, 7, 7.8, 8)
icons["speedometer"] = [.s(arc(12, 15, 9, 180, 0)), .s(P("M3 15H5.5M18.5 15H21")), .s(P("M12 15L16.5 9")), .f(P("M10.8 13.8H13.2V16.2H10.8Z"))]
icons["list.bullet"] = [.f(P("M3.5 5.5H5.5V7.5H3.5Z")), .f(P("M3.5 11H5.5V13H3.5Z")), .f(P("M3.5 16.5H5.5V18.5H3.5Z")), .s(P("M9 6.5H20.5M9 12H20.5M9 17.5H20.5"))]
icons["list.number"] = [.s(P("M3.6 5.2L5 4.2V8.6")), .s(P("M3.4 11Q4.4 9.8 5.6 10.5Q6.4 11.4 5.2 12.4L3.4 14H6.2")), .s(P("M3.4 15.6H6L4.6 17.2Q6.4 17.2 6.2 18.6Q5.4 20 3.4 19.2")), .s(P("M9.5 6.5H20.5M9.5 12H20.5M9.5 17.5H20.5"))]
icons["rectangle.stack"] = [.s(tabP(3, 9.5, 18, 10.5, 3.5)), .s(P("M5 6.5H19")), .s(P("M7 3.8H17"))]
icons["square.stack.3d.up"] = [.s(P("M12 4L18.4 7.2V8.8L12 12L4 8Z")), .s(P("M4 12L12 16L20 12")), .s(P("M4 16L12 20L20 16"))]
icons["square.stack.3d.up.slash"] = icons["square.stack.3d.up"]! + [.x(P(slash)), .s(P(slash))]
icons["list.and.film"] = [.s(tabP(3, 5, 8.5, 14, 2.5)), .s(P("M3 9.5H5.5M3 14.5H5.5")), .s(P("M15 7H21M15 12H21M15 17H21"))]
icons["hourglass"] = [.s(P("M6 3.5H18M6 20.5H18")), .s(P("M7.5 3.5V6Q7.5 9 12 12Q16.5 15 16.5 18V20.5")), .s(P("M16.5 3.5V6Q16.5 9 12 12Q7.5 15 7.5 18V20.5"))]

// MARK: Navigation and common
icons["circle"] = [.s(encl)]
icons["checkmark"] = [.s(P("M5 12.5L9.8 17.2L19 7"))]
let chk = P("M8 12.2L11 15.2L16.5 9")
icons["checkmark.circle"] = [.s(encl), .s(chk)]
icons["checkmark.circle.fill"] = [.f(encl), .h(chk)]
icons["xmark"] = [.s(P("M6 6L18 18M18 6L6 18"))]
icons["xmark.circle.fill"] = [.f(encl), .h(P("M9 9L15 15M15 9L9 15"))]
icons["minus.circle"] = [.s(encl), .s(P("M8 12H16"))]
icons["info.circle"] = [.s(encl), .s(P("M12 11V16.5")), .f(dot(12, 8))]
icons["questionmark.circle"] = [.s(encl), .s(P("M9.6 9.6Q9.8 7.4 12 7.4Q14.4 7.4 14.4 9.6Q14.4 11 12.6 11.8Q12 12.2 12 13.4")), .f(dot(12, 16.4))]
icons["exclamationmark.circle"] = [.s(encl), .s(P("M12 7.5V13")), .f(dot(12, 16.2))]
icons["exclamationmark.triangle"] = [.s(P(triP)), .s(P("M12 9.5V13.5")), .f(dot(12, 16.4, 0.75))]
icons["exclamationmark.triangle.fill"] = [.f(P(triP)), .h(P("M12 9.5V13.5")), .xf(dot(12, 16.4, 0.4))]
icons["ellipsis"] = [.f(dot(5.5, 12, 1.1)), .f(dot(12, 12, 1.1)), .f(dot(18.5, 12, 1.1))]
icons["ellipsis.circle"] = [.s(encl), .f(dot(8, 12)), .f(dot(12, 12)), .f(dot(16, 12))]
icons["chevron.right"] = [.s(P("M9 5L16 12L9 19"))]
icons["chevron.left"] = mirror(icons["chevron.right"]!)
icons["chevron.down"] = [.s(P("M5 9L12 16L19 9"))]
icons["chevron.up"] = [.s(P("M5 15L12 8L19 15"))]
icons["chevron.up.chevron.down"] = [.s(P("M7.5 9L12 4.5L16.5 9M7.5 15L12 19.5L16.5 15"))]
icons["arrow.right"] = [.s(P("M4 12H19M13.5 6.5L19 12L13.5 17.5"))]
icons["arrow.down"] = [.s(P("M12 4V19M6.5 13.5L12 19L17.5 13.5"))]
icons["arrow.up.right"] = [.s(P("M7 17L17 7M9 7H17V15"))]
let downIn = P("M12 7.5V16M8.5 12.5L12 16L15.5 12.5")
icons["arrow.down.circle"] = [.s(encl), .s(downIn)]
icons["arrow.down.circle.fill"] = [.f(encl), .h(downIn)]
icons["arrow.up.circle.fill"] = [.f(encl), .h(P("M12 16.5V8M8.5 11.5L12 8L15.5 11.5"))]
icons["arrow.triangle.2.circlepath"] = [.s(P("M4.5 11.5V7.5Q4.5 5.5 6.5 5.5H17")), .s(P("M14.5 3L17 5.5L14.5 8")), .s(P("M19.5 12.5V15L16.5 18.5H7")), .s(P("M9.5 16L7 18.5L9.5 21"))]
icons["clock.arrow.circlepath"] = icons["gobackward"]! + [.s(P("M12 9.5V13H14.5"))]
icons["shuffle"] = [.s(P("M3.5 7H7.5L15.5 17H20M3.5 17H7.5L9.8 14.1M13.2 9.9L15.5 7H20")), .s(P("M17.5 4.5L20 7L17.5 9.5M17.5 14.5L20 17L17.5 19.5"))]
icons["link"] = [.s(P("M10 7.5H6.5Q3 7.5 3 12Q3 16.5 6.5 16.5H10")), .s(P("M14 7.5H17.5L21 11V16.5H14")), .s(P("M8 12H16"))]
icons["magnifyingglass"] = [.s(tabP(3.5, 3.5, 12.5, 12.5, 3.5)), .s(P("M15.5 15.5L20.5 20.5"))]
icons["trash"] = [.s(P("M3.5 6.5H20.5")), .s(P("M9 6.5V4H13.5L15 5.5V6.5")), .s(P("M5.5 6.5L6.5 20.5H17.5L18.5 6.5")), .s(P("M10 10.5V16.5M14 10.5V16.5"))]
icons["doc.on.doc"] = [.s(tabP(8.5, 7.5, 12, 13.5, 3.5)), .s(P("M5.5 16.5V3.5H12L14.5 6"))]
icons["doc.text"] = [.s(tabP(5, 3, 14, 18, 4.5)), .s(P("M8.5 11H15.5M8.5 14H15.5M8.5 17H12.5"))]
icons["folder"] = [.s(P("M3 6H9.5L11.5 8.5H17.5L21 12V19.5H3Z"))]
icons["square.and.arrow.up"] = [.s(P("M9 9.5H5V20.5H19V13L15.5 9.5H15")), .s(P("M12 15V3.5M8.5 7L12 3.5L15.5 7"))]
icons["heart"] = [.s(P(heartP))]
icons["heart.fill"] = [.f(P(heartP))]
let lines3 = P("M7.5 9H16.5M9 12.5H15M10.5 16H13.5")
icons["line.3.horizontal.decrease.circle"] = [.s(encl), .s(lines3)]
icons["line.3.horizontal.decrease.circle.fill"] = [.f(encl), .h(lines3)]

// MARK: Status, settings and devices
icons["gearshape"] = [.s(gear(12, 12, 9.3, 7, 8)), .s(tabP(9.3, 9.3, 5.4, 5.4, 1.6))]
icons["gearshape.fill"] = [.f(gear(12, 12, 9.3, 7, 8)), .xf(tabP(9.8, 9.8, 4.4, 4.4, 1.3))]
icons["wrench.and.screwdriver.fill"] = [.f(P("M14.5 3.5Q11 4 11 7.5Q11 8.3 11.3 9L3.8 16.5Q3 17.5 3.8 18.5L5.5 20.2Q6.5 21 7.5 20.2L15 12.7Q15.7 13 16.5 13Q20 13 20.5 9.5L17.8 10.2L16 8L16.8 5.2Z"))]
icons["person.fill"] = [.f(tabP(8.5, 3.5, 7, 7, 2)), .f(P("M4.5 20.5Q4.5 13.5 12 13.5Q19.5 13.5 19.5 20.5Z"))]
icons["person.crop.circle"] = [.s(encl), .s(tabP(9.6, 7, 4.8, 4.8, 1.4)), .s(P("M7.2 17.4Q7.7 14.4 12 14.4Q16.3 14.4 16.8 17.4"))]
icons["hand.raised"] = [.s(P("M8 13V5.5Q8 4.3 9.2 4.3Q10.4 4.3 10.4 5.5V11M10.4 10.5V4.2Q10.4 3 11.6 3Q12.8 3 12.8 4.2V10.5M12.8 10.5V5Q12.8 3.8 14 3.8Q15.2 3.8 15.2 5V11M15.2 11V7.4Q15.2 6.2 16.4 6.2Q17.6 6.2 17.6 7.4V14Q17.6 20.5 12 20.5Q8.5 20.5 7 17.5L4.8 13.6Q4.2 12.4 5.3 11.8Q6.3 11.3 7 12.2L8 13.6"))]
icons["xmark.shield"] = [.s(P("M4 5.5L12 3H16.5L20 5.5V11Q20 17.5 12 21Q4 17.5 4 11Z")), .s(P("M9.5 9.5L14.5 14.5M14.5 9.5L9.5 14.5"))]
let antenna: [El] = [.s(P("M12 11.5V20.5")), .f(dot(12, 10.3, 1.1)), .s(P("M8.5 7.5L6.8 10.5L8.5 13.5M15.5 7.5L17.2 10.5L15.5 13.5")), .s(P("M5.4 4.5L2.6 10.5L5.4 16.5M18.6 4.5L21.4 10.5L18.6 16.5"))]
icons["antenna.radiowaves.left.and.right"] = antenna
icons["antenna.radiowaves.left.and.right.slash"] = antenna + [.x(P(slash)), .s(P(slash))]
icons["wifi"] = wifiArcs
icons["wifi.slash"] = wifiArcs + [.x(P("M4 4L20 20")), .s(P("M4 4L20 20"))]
icons["wifi.exclamationmark"] = [.s(arc(10, 19, 4.5, 225, 315)), .s(arc(10, 19, 9, 225, 315)), .f(dot(10, 19, 1.1)), .s(P("M20.5 9V15")), .f(dot(20.5, 18.6, 0.9))]
icons["iphone"] = [.s(tabP(6.5, 2.5, 11, 19, 3)), .s(P("M10.5 18.3H13.5"))]
icons["macbook"] = [.s(tabP(4.5, 5, 15, 11, 3)), .s(P("M2 19H22"))]
icons["macbook.and.iphone"] = [.s(tabP(2.5, 5.5, 12, 9, 2.5)), .s(P("M1 17.5H15.5")), .s(tabP(17.5, 8.5, 5.5, 11.5, 1.6))]
icons["server.rack"] = [.s(tabP(3, 4, 18, 7, 3)), .s(tabP(3, 13, 18, 7, 0)), .f(dot(7, 7.5)), .f(dot(7, 16.5)), .s(P("M11 7.5H17M11 16.5H17"))]
icons["chart.bar"] = [.s(tabP(3.5, 12, 4, 8, 0)), .s(tabP(10, 7.5, 4, 12.5, 0)), .s(tabP(16.5, 3.5, 4, 16.5, 1.6))]

// MARK: Library and reader
icons["textformat.size"] = [.s(P("M2.5 19L7.2 5H8.8L13.5 19M4.6 14H11.4")), .s(P("M14.5 19L17.4 10.5H18.6L21.5 19M15.8 16H20.2"))]
icons["book"] = [.s(P(bookOpen)), .s(P("M12 6.5V20.5"))]
icons["book.fill"] = [.f(P(bookOpen)), .h(P("M12 7.5V20"))]
icons["book.closed"] = [.s(P(bookClosed)), .s(P("M5 18.2Q5 16.8 6.5 16.8H19"))]
icons["book.closed.fill"] = [.f(P(bookClosed)), .h(P("M6 16.8H19"))]
icons["character.book.closed"] = icons["book.closed"]! + [.s(P("M9.4 13.2L11.6 6.8H12.4L14.6 13.2M10.2 11H13.8"))]
icons["pawprint.fill"] = [.f(P("M12 13Q14.6 13 16.4 15.8Q18 18.6 16.6 19.9Q15.4 20.8 12 20.1Q8.6 20.8 7.4 19.9Q6 18.6 7.6 15.8Q9.4 13 12 13Z")), .f(tabP(3.3, 8.6, 2.4, 3.2, 0.9)), .f(tabP(8.1, 3.8, 2.4, 3.8, 0.9)), .f(tabP(13.5, 3.8, 2.4, 3.8, 0.9)), .f(tabP(18.3, 8.6, 2.4, 3.2, 0.9))]
return icons
}
