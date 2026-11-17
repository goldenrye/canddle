import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ProfileImage {
    static let maximumInputBytes = 25 * 1024 * 1024

    static func sharedImage(_ data: Data) -> CGImage? {
        guard !data.isEmpty, DeviceProfile.validPhoto(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...160).contains(width), width == height else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Decode a bounded thumbnail, center-crop, and re-encode pixels only.
    /// No EXIF, GPS, contact identifiers, or original image properties survive.
    static func prepare(_ data: Data) throws -> Data {
        guard data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 30000, height <= 30000,
              Double(width) * Double(height) <= 100_000_000,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw VoiceError.packet }
        for size in [160, 128, 96] {
            guard let context = CGContext(data: nil, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw VoiceError.packet }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let scale = CGFloat(size) / CGFloat(min(thumbnail.width, thumbnail.height))
            let w = CGFloat(thumbnail.width) * scale, h = CGFloat(thumbnail.height) * scale
            context.interpolationQuality = .high
            context.draw(thumbnail, in: CGRect(x: (CGFloat(size) - w) / 2,
                y: (CGFloat(size) - h) / 2, width: w, height: h))
            guard let image = context.makeImage() else { throw VoiceError.packet }
            for quality in [0.75, 0.55, 0.35] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    output, UTType.jpeg.identifier as CFString, 1, nil) else { throw VoiceError.packet }
                CGImageDestinationAddImage(destination, image, [
                    kCGImageDestinationLossyCompressionQuality: quality
                ] as CFDictionary)
                if CGImageDestinationFinalize(destination), output.length <= DeviceProfile.maximumPhotoBytes {
                    return output as Data
                }
            }
        }
        throw VoiceError.packet
    }
}
