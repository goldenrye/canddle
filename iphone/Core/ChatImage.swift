import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ChatImage {
    static let maximumInputBytes = 25 * 1024 * 1024
    static let maximumDimension = 1280
    private static let cache: NSCache<NSData, CGImage> = {
        let cache = NSCache<NSData, CGImage>()
        cache.countLimit = 16
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func image(_ data: Data) -> CGImage? {
        guard (1...ChatProtocol.maximumPhotoBytes).contains(data.count) else { return nil }
        let key = data as NSData
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maximumDimension).contains(width), (1...maximumDimension).contains(height) else { return nil }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// File-backed loading checks the source size before reading provider bytes.
    @discardableResult
    static func prepare(provider: NSItemProvider,
                        completion: @escaping @Sendable (Result<Data, Error>) -> Void) -> Progress? {
        guard let type = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else {
            completion(.failure(VoiceError.packet))
            return nil
        }
        return provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
            completion(Result {
                guard let url,
                      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      (1...maximumInputBytes).contains(size) else { throw VoiceError.packet }
                return try prepare(Data(contentsOf: url))
            })
        }
    }

    /// Re-render oriented pixels without copying EXIF/GPS or the source filename.
    static func prepare(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 30000, height <= 30000,
              Double(width) * Double(height) <= 100_000_000 else { throw VoiceError.packet }
        for dimension in [maximumDimension, 1024, 800, 640] {
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary),
            let context = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height,
                bitsPerComponent: 8, bytesPerRow: thumbnail.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw VoiceError.packet }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height))
            guard let pixels = context.makeImage() else { throw VoiceError.packet }
            for quality in [0.8, 0.65, 0.5, 0.35] {
                let result = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    result, UTType.jpeg.identifier as CFString, 1, nil) else { throw VoiceError.packet }
                CGImageDestinationAddImage(destination, pixels, [
                    kCGImageDestinationLossyCompressionQuality: quality
                ] as CFDictionary)
                if CGImageDestinationFinalize(destination), result.length <= ChatProtocol.maximumPhotoBytes {
                    return result as Data
                }
            }
        }
        throw VoiceError.packet
    }
}
