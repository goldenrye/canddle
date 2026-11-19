import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum CallBranding {
    /// A 40-point alpha template of the current can-and-waves mark.
    /// CallKit tints it itself; the opaque full-color app icon would become a square.
    static func iconTemplate(scale: Int = 3) -> Data? {
        guard (1...3).contains(scale) else { return nil }
        let pixels = 40 * scale
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels,
                  bitsPerComponent: 8, bytesPerRow: pixels * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: CGFloat(pixels) / 720, y: -CGFloat(pixels) / 720)
        context.translateBy(x: -152, y: -200)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))

        // Match Branding/RenderIcon.swift, simplified for a small monochrome glyph.
        context.addPath(CGPath(roundedRect: CGRect(x: 387, y: 400, width: 250, height: 360),
                               cornerWidth: 42, cornerHeight: 42, transform: nil))
        context.fillPath()
        context.fillEllipse(in: CGRect(x: 387, y: 369, width: 250, height: 62))
        context.setLineCap(.round)
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

        // Face and rim are transparent cutouts, not dark pixels in a template.
        context.setBlendMode(.clear)
        for x: CGFloat in [469.5, 554.5] {
            context.fillEllipse(in: CGRect(x: x - 17.5, y: 551.2 - 17.5, width: 35, height: 35))
        }
        context.setLineWidth(16.25)
        context.move(to: CGPoint(x: 474.5, y: 612.4))
        context.addQuadCurve(to: CGPoint(x: 549.5, y: 612.4), control: CGPoint(x: 512, y: 659.2))
        context.strokePath()
        context.setLineWidth(12)
        context.strokeEllipse(in: CGRect(x: 407, y: 387, width: 210, height: 27))
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
