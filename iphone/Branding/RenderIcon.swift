// Run from the repository root:
// swift iphone/Branding/RenderIcon.swift \
//     iphone/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png \
//     iphone/App/Assets.xcassets/BrandLogo.imageset/BrandLogo.png
import AppKit

let size = 1024
let outputs = Array(CommandLine.arguments.dropFirst())
guard !outputs.isEmpty else { fatalError("Provide one or more output PNG paths.") }
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r / 255, g / 255, b / 255, 1])!
}
let indigo = color(42, 40, 82), ink = color(28, 27, 56)
let cream = color(246, 242, 232), creamTop = color(222, 215, 198), orange = color(255, 168, 48)

// Full-bleed opaque artwork: iOS supplies the Home Screen corner mask.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)
context.setFillColor(indigo)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Lift the artwork so the can and waves sit optically centered.
context.translateBy(x: 0, y: -48)

// One large can character, kept simple so it stays legible at notification sizes.
let body = CGPath(roundedRect: CGRect(x: 387, y: 400, width: 250, height: 360),
                  cornerWidth: 42, cornerHeight: 42, transform: nil)
let rim = CGRect(x: 387, y: 369, width: 250, height: 62)
context.setStrokeColor(ink)
context.setLineWidth(20)
context.addPath(body)
context.setFillColor(cream)
context.fillPath()
context.addPath(body)
context.strokePath()
context.addEllipse(in: rim)
context.setFillColor(creamTop)
context.fillPath()
context.addEllipse(in: rim)
context.strokePath()

context.setFillColor(ink)
for x: CGFloat in [469.5, 554.5] {
    context.fillEllipse(in: CGRect(x: x - 17.5, y: 551.2 - 17.5, width: 35, height: 35))
}
context.setLineCap(.round)
context.setLineWidth(16.25)
context.move(to: CGPoint(x: 474.5, y: 612.4))
context.addQuadCurve(to: CGPoint(x: 549.5, y: 612.4), control: CGPoint(x: 512, y: 659.2))
context.strokePath()

// Signal waves on both sides: the family connection.
context.setStrokeColor(orange)
context.setLineWidth(34)
let center = CGPoint(x: 512, y: 570), spread: CGFloat = 0.55
for radius: CGFloat in [215, 300] {
    for side: CGFloat in [1, -1] {
        let x = center.x + side * radius * cos(spread)
        context.move(to: CGPoint(x: x, y: center.y - radius * sin(spread)))
        context.addQuadCurve(to: CGPoint(x: x, y: center.y + radius * sin(spread)),
                             control: CGPoint(x: center.x + side * radius / cos(spread), y: center.y))
    }
}
context.strokePath()

let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon.")
}
for output in outputs {
    try png.write(to: URL(fileURLWithPath: output), options: .atomic)
}
print("Rendered opaque \(size)x\(size) app icon.")
