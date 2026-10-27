import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Turns pictures you choose into profile photos and stickers, and checks
/// images that arrive from other Macs. Everything here is synchronous and can
/// be slow (Vision), so call it off the main actor.
enum ImageProcessing {
    enum Failure: Error, Equatable {
        /// Not an image, or one ImageIO can't decode.
        case unreadable
        /// Still too large after shrinking it.
        case tooLarge
        /// "Remove background" found nothing to keep.
        case noSubject
    }

    /// Image types accepted from other Macs. Decoding is limited to these.
    static let acceptedTypes: Set<String> = [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier]

    /// Profile photos are square JPEGs this many pixels wide.
    static let avatarSide = 256
    /// Stickers fit in a square this many pixels wide.
    static let stickerSide = 320

    // MARK: - Profile photos

    /// A square, centre-cropped JPEG of the picture.
    static func profilePhoto(from data: Data) throws -> Data {
        let image = try decode(data, maxPixels: 1024)
        let side = min(image.width, image.height)
        let crop = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
        guard let square = image.cropping(to: crop) else { throw Failure.unreadable }
        let output = try render(square, width: avatarSide, height: avatarSide, opaque: true)
        return try encode(output, as: .jpeg, quality: 0.85)
    }

    // MARK: - Stickers

    /// A sticker from a picture: the subject cut out (when `removeBackground` and
    /// Vision finds one), trimmed and scaled to fit `stickerSide`, as PNG. A
    /// small animated GIF is kept as it is so it still moves.
    static func sticker(from data: Data, removeBackground: Bool) throws -> Data {
        if isAnimated(data), data.count <= ProtocolLimits.maxMediaBytes, isAcceptableImage(data) {
            return data
        }
        var image = try decode(data, maxPixels: 1600)
        if removeBackground {
            image = try liftSubject(from: image)
        }
        image = trimTransparentEdges(image) ?? image
        for side in [stickerSide, 256, 200] {
            let scale = min(1, CGFloat(side) / CGFloat(max(image.width, image.height)))
            let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
            let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
            let png = try encode(try render(image, width: width, height: height, opaque: false), as: .png)
            if png.count <= ProtocolLimits.maxMediaBytes { return png }
        }
        throw Failure.tooLarge
    }

    /// The foreground subjects of a photo on a transparent background (macOS 14+ Vision).
    static func liftSubject(from image: CGImage) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw Failure.noSubject }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                         croppedToInstancesExtent: true)
        let masked = CIImage(cvPixelBuffer: buffer)
        guard let output = CIContext().createCGImage(masked, from: masked.extent) else { throw Failure.unreadable }
        return output
    }

    // MARK: - Link previews

    /// A link's preview image, at most 600 pixels wide: JPEG, or PNG when it has
    /// transparency (logos).
    static func linkImage(from data: Data) throws -> Data {
        let image = try decode(data, maxPixels: 1200)
        let scale = min(1, 600 / CGFloat(image.width), 1024 / CGFloat(image.height))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard width >= 32, height >= 32 else { throw Failure.unreadable }
        if hasTransparency(image) {
            let png = try encode(try render(image, width: width, height: height, opaque: false), as: .png)
            if png.count <= ProtocolLimits.maxMediaBytes { return png }
        }
        for quality in [0.8, 0.6, 0.4] {
            let jpeg = try encode(try render(image, width: width, height: height, opaque: true), as: .jpeg, quality: quality)
            if jpeg.count <= ProtocolLimits.maxMediaBytes { return jpeg }
        }
        throw Failure.tooLarge
    }

    /// A site's icon as a PNG of at most 64 pixels.
    static func linkIcon(from data: Data) throws -> Data {
        let image = try decode(data, maxPixels: 64)
        return try encode(try render(image, width: image.width, height: image.height, opaque: false), as: .png)
    }

    private static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    // MARK: - Checking

    /// Whether data from another Mac is a PNG, JPEG or GIF that decodes and is
    /// no larger than `maxDimension` either way.
    static func isAcceptableImage(_ data: Data, maxDimension: Int = ProtocolLimits.maxMediaDimension) -> Bool {
        guard data.count <= ProtocolLimits.maxMediaBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, acceptedTypes.contains(type),
              CGImageSourceGetCount(source) >= 1,
              let size = pixelSize(of: source), size.width >= 1, size.height >= 1,
              size.width <= maxDimension, size.height <= maxDimension else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelSize(of: source)
    }

    static func isAnimated(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    // MARK: - Helpers

    private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // EXIF orientations 5–8 are rotated a quarter turn.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    /// Decodes the first frame, upright, no larger than `maxPixels` either way.
    private static func decode(_ data: Data, maxPixels: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw Failure.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw Failure.unreadable }
        return image
    }

    private static func render(_ image: CGImage, width: Int, height: Int, opaque: Bool) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue
                                                         : CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure.unreadable
        }
        context.interpolationQuality = .high
        if opaque {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { throw Failure.unreadable }
        return output
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: CGFloat = 1) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw Failure.unreadable
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.unreadable }
        return data as Data
    }

    /// Crops away fully transparent rows and columns, so stickers sit snugly.
    private static func trimTransparentEdges(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // The bitmap's rows run top to bottom, as `cropping(to:)` expects.
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }
}
