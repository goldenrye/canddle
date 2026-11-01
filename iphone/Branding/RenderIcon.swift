// Run from the repository root:
// swift iphone/Branding/RenderIcon.swift iphone/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit

let size = 1024
let output = CommandLine.arguments.dropFirst().first
guard let output else { fatalError("Provide the output PNG path.") }
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r / 255, g / 255, b / 255, 1])!
}

// Full-bleed opaque artwork: iOS supplies the Home Screen corner mask.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)
let background = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(17, 65, 80), color(8, 28, 47)] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    background, start: CGPoint(x: 80, y: 0), end: CGPoint(x: 944, y: 1024),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)

// A generous shield silhouette remains legible at notification-icon sizes.
let shield = CGMutablePath()
shield.move(to: CGPoint(x: 512, y: 188))
shield.addCurve(to: CGPoint(x: 766, y: 282),
                control1: CGPoint(x: 594, y: 238), control2: CGPoint(x: 675, y: 267))
shield.addLine(to: CGPoint(x: 766, y: 478))
shield.addCurve(to: CGPoint(x: 512, y: 830),
                control1: CGPoint(x: 766, y: 642), control2: CGPoint(x: 654, y: 764))
shield.addCurve(to: CGPoint(x: 258, y: 478),
                control1: CGPoint(x: 370, y: 764), control2: CGPoint(x: 258, y: 642))
shield.addLine(to: CGPoint(x: 258, y: 282))
shield.addCurve(to: CGPoint(x: 512, y: 188),
                control1: CGPoint(x: 349, y: 267), control2: CGPoint(x: 430, y: 238))
shield.closeSubpath()
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: 14), blur: 32, color: color(5, 23, 36).copy(alpha: 0.25))
context.addPath(shield)
context.setFillColor(color(243, 253, 251))
context.fillPath()
context.restoreGState()

// Speech bubble with a single clear tail, containing a voice waveform.
let bubble = CGMutablePath()
bubble.move(to: CGPoint(x: 414, y: 350))
bubble.addLine(to: CGPoint(x: 610, y: 350))
bubble.addCurve(to: CGPoint(x: 676, y: 416),
                control1: CGPoint(x: 650, y: 350), control2: CGPoint(x: 676, y: 376))
bubble.addLine(to: CGPoint(x: 676, y: 518))
bubble.addCurve(to: CGPoint(x: 610, y: 584),
                control1: CGPoint(x: 676, y: 558), control2: CGPoint(x: 650, y: 584))
bubble.addLine(to: CGPoint(x: 483, y: 584))
bubble.addLine(to: CGPoint(x: 400, y: 646))
bubble.addLine(to: CGPoint(x: 410, y: 584))
bubble.addCurve(to: CGPoint(x: 348, y: 518),
                control1: CGPoint(x: 372, y: 582), control2: CGPoint(x: 348, y: 556))
bubble.addLine(to: CGPoint(x: 348, y: 416))
bubble.addCurve(to: CGPoint(x: 414, y: 350),
                control1: CGPoint(x: 348, y: 376), control2: CGPoint(x: 374, y: 350))
bubble.closeSubpath()
context.addPath(bubble)
context.setFillColor(color(13, 48, 64))
context.fillPath()

context.setStrokeColor(color(82, 224, 191))
context.setLineWidth(28)
context.setLineCap(.round)
for (x, height): (CGFloat, CGFloat) in [(440, 46), (512, 110), (584, 70)] {
    context.move(to: CGPoint(x: x, y: 467 - height / 2))
    context.addLine(to: CGPoint(x: x, y: 467 + height / 2))
}
context.strokePath()

let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon.")
}
try png.write(to: URL(fileURLWithPath: output), options: .atomic)
print("Rendered opaque \(size)x\(size) app icon.")
