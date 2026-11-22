// Run from the repository root:
// swift iphone/Branding/RenderIcon.swift \
//     iphone/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png \
//     iphone/App/Assets.xcassets/BrandLogo.imageset/BrandLogo.png
import AppKit

let size = 1024
let outputs = Array(CommandLine.arguments.dropFirst())
guard !outputs.isEmpty else { fatalError("Provide one or more output PNG paths.") }
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(colorSpace: cs, components: [r/255, g/255, b/255, 1])! }
let bg = color(88, 86, 200), ink = color(28, 27, 56), cream = color(250, 246, 236)
let sky = color(140, 200, 245), skyDark = color(105, 170, 230), orange = color(255, 168, 48), blush = color(255, 150, 175)
let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size*4,
                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
c.translateBy(x: 0, y: CGFloat(size)); c.scaleBy(x: 1, y: -1)
// Full-bleed opaque artwork: iOS supplies the Home Screen corner mask.
c.setFillColor(bg); c.fill(CGRect(x: 0, y: 0, width: size, height: size))
c.setLineJoin(.round); c.setLineCap(.round)
// Scale and center the dolphin and its sound waves.
c.translateBy(x: 512, y: 512); c.scaleBy(x: 1.14, y: 1.14); c.translateBy(x: -458, y: -500)
func paint(_ p: CGPath, _ fill: CGColor, stroke: CGFloat = 20) {
    c.addPath(p); c.setFillColor(fill); c.fillPath()
    if stroke > 0 { c.addPath(p); c.setStrokeColor(ink); c.setLineWidth(stroke); c.strokePath() }
}
func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

// Sound waves coming from the smile.
c.setStrokeColor(orange); c.setLineWidth(32)
for r: CGFloat in [75, 140] {
    let ctr = pt(245, 555), s: CGFloat = 0.6, x = ctr.x - r*cos(s)
    c.move(to: pt(x, ctr.y - r*sin(s)))
    c.addQuadCurve(to: pt(x, ctr.y + r*sin(s)), control: pt(ctr.x - r/cos(s), ctr.y))
}
c.strokePath()

// Soft, rounded dorsal fin and tail flukes sit behind the body.
let fin = CGMutablePath()
fin.move(to: pt(515, 425)); fin.addQuadCurve(to: pt(578, 318), control: pt(515, 345))
fin.addQuadCurve(to: pt(630, 450), control: pt(615, 350)); fin.closeSubpath()
paint(fin, skyDark)
let fluke = CGMutablePath()
fluke.move(to: pt(690, 585))
fluke.addQuadCurve(to: pt(778, 488), control: pt(720, 500))
fluke.addQuadCurve(to: pt(765, 590), control: pt(810, 540))
fluke.addQuadCurve(to: pt(820, 668), control: pt(820, 620))
fluke.addQuadCurve(to: pt(690, 615), control: pt(740, 680))
fluke.closeSubpath()
paint(fluke, skyDark)

// Chubby body with a big round head and a short rounded snout.
let body = CGMutablePath()
body.move(to: pt(310, 512))
body.addQuadCurve(to: pt(450, 378), control: pt(318, 388))
body.addQuadCurve(to: pt(710, 575), control: pt(625, 385))
body.addLine(to: pt(700, 622))
body.addQuadCurve(to: pt(425, 672), control: pt(600, 692))
body.addQuadCurve(to: pt(300, 592), control: pt(330, 668))
body.addQuadCurve(to: pt(252, 555), control: pt(250, 598))
body.addQuadCurve(to: pt(310, 512), control: pt(256, 512))
body.closeSubpath()
c.addPath(body); c.setFillColor(sky); c.fillPath()
c.saveGState(); c.addPath(body); c.clip()
c.setFillColor(cream); c.fillEllipse(in: CGRect(x: 230, y: 565, width: 420, height: 190))
c.restoreGState()
c.addPath(body); c.setStrokeColor(ink); c.setLineWidth(20); c.strokePath()

// Little side flipper.
c.saveGState(); c.translateBy(x: 505, y: 612); c.rotate(by: 0.6)
paint(CGPath(ellipseIn: CGRect(x: -26, y: -55, width: 52, height: 110), transform: nil), skyDark, stroke: 16)
c.restoreGState()

// Face: big sparkly eye, rosy cheek, happy smile.
c.setFillColor(ink); c.fillEllipse(in: CGRect(x: 370, y: 470, width: 60, height: 64))
c.setFillColor(cream); c.fillEllipse(in: CGRect(x: 396, y: 480, width: 20, height: 20))
c.fillEllipse(in: CGRect(x: 384, y: 509, width: 9, height: 9))
c.setFillColor(blush); c.fillEllipse(in: CGRect(x: 338, y: 548, width: 54, height: 30))
c.setStrokeColor(ink); c.setLineWidth(14)
c.move(to: pt(268, 566)); c.addQuadCurve(to: pt(342, 588), control: pt(300, 600))
c.addQuadCurve(to: pt(350, 572), control: pt(352, 582))
c.strokePath()


let bitmap = NSBitmapImageRep(cgImage: c.makeImage()!)
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon.")
}
for output in outputs {
    try png.write(to: URL(fileURLWithPath: output), options: .atomic)
}
print("Rendered opaque \(size)x\(size) app icon.")
