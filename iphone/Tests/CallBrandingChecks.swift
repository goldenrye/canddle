import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct CallBrandingChecks {
    static func main() throws {
        precondition(CallBranding.iconTemplate(scale: 0) == nil)
        precondition(CallBranding.iconTemplate(scale: 4) == nil)
        for scale in 1...3 {
            let data = CallBranding.iconTemplate(scale: scale)!
            precondition(data.count < 16000)
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            precondition(CGImageSourceGetType(source) as String? == UTType.png.identifier)
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            let size = 40 * scale
            precondition(image.width == size && image.height == size)
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            pixels.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: size, height: size,
                    bitsPerComponent: 8, bytesPerRow: size * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            }
            var visible = 0, opaque = 0
            for y in 0..<size {
                for x in 0..<size {
                    let offset = (y * size + x) * 4
                    let alpha = pixels[offset + 3]
                    if alpha > 0 { visible += 1 }
                    if alpha == 255 { opaque += 1 }
                    precondition(pixels[offset] == alpha && pixels[offset + 1] == alpha
                                 && pixels[offset + 2] == alpha, "Only white alpha-template pixels")
                    if x == 0 || y == 0 || x == size - 1 || y == size - 1 {
                        precondition(alpha == 0, "Transparent margin, not an opaque app-icon square")
                    }
                }
            }
            precondition(opaque > size * size / 10 && visible < size * size / 2)
            if scale == 3, let path = CommandLine.arguments.dropFirst().first {
                let preview = CGContext(data: nil, width: 240, height: 240, bitsPerComponent: 8,
                    bytesPerRow: 960, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                preview.setFillColor(CGColor(red: 0.165, green: 0.157, blue: 0.322, alpha: 1))
                preview.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
                preview.draw(image, in: CGRect(x: 0, y: 0, width: 240, height: 240))
                let output = NSMutableData()
                let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, preview.makeImage()!, nil)
                precondition(CGImageDestinationFinalize(destination))
                try (output as Data).write(to: URL(fileURLWithPath: path))
            }
        }
        print("PASS CallKit branding: 40-point PNG templates at 1x/2x/3x, transparent margins and white artwork")
    }
}
