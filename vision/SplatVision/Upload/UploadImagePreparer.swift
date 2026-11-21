import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image ready to upload with `POST /generate` (multipart, field `file`).
struct PreparedUpload: Sendable {
    /// File to send: the picked original, or a converted JPEG.
    let fileURL: URL
    /// Safe file name whose extension matches the data actually sent.
    let filename: String
    let mimeType: String
    let byteCount: Int64
    /// Small JPEG for the history list (temporary; the history store moves it).
    let thumbnailURL: URL?
    /// Why the original was not sent as-is (nil = original bytes, EXIF untouched).
    let conversionReason: String?
}

enum ImagePrepareError: LocalizedError, Equatable {
    case notAnImage
    case conversionFailed
    case stillTooLarge(Int64)

    var errorDescription: String? {
        switch self {
        case .notAnImage: "選到的檔案不是可讀取的圖片"
        case .conversionFailed: "圖片轉換失敗"
        case let .stillTooLarge(bytes): "圖片縮小後仍有 \(bytes.formatted(.byteCount(style: .file)))，超過 server 上限"
        }
    }
}

/// Checks a picked image against API.md's limits and converts it only when needed.
///
/// - Sent as-is (keeps the original bytes, so EXIF focal length — which the server uses for metric
///   scale — survives): JPEG / PNG / HEIC / WebP within the byte and pixel limits.
/// - Otherwise: downsampled straight from the file, composited on white (transparent areas must not
///   turn black), oriented upright, written as JPEG with the original metadata (EXIF) copied.
enum UploadImagePreparer {
    struct Limits: Sendable {
        /// API.md limits: file ≤ 20 MiB (20,971,520 bytes), ≤ 40,000,000 pixels.
        var maxBytes: Int64 = 20 * 1024 * 1024
        var maxPixels = 40_000_000
        var maxLongEdge = 4096
        var thumbnailEdge = 256
    }

    static let passthroughTypes: Set<String> = [
        UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.webP.identifier,
    ]

    /// Runs synchronously; call it off the main actor. Creates new temporary files; never modifies `file`.
    static func prepare(file: URL, suggestedName: String?, limits: Limits = Limits()) throws -> PreparedUpload {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw ImagePrepareError.notAnImage
        }
        try Task.checkCancellation()

        // Files created here are deleted on any failure or cancellation, unless handed to the caller.
        var created: [URL] = []
        var delivered = false
        defer { if !delivered { created.forEach { try? FileManager.default.removeItem(at: $0) } } }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
        let pixels = width.multipliedReportingOverflow(by: height)
        let tooManyPixels = pixels.overflow || pixels.partialValue > limits.maxPixels
        let thumbnail = try? writeThumbnail(source: source, edge: limits.thumbnailEdge)
        if let thumbnail { created.append(thumbnail) }
        try Task.checkCancellation()
        let baseName = sanitizedBaseName(suggestedName ?? file.deletingPathExtension().lastPathComponent)

        var reasons: [String] = []
        if !passthroughTypes.contains(typeIdentifier) { reasons.append("格式 \(typeIdentifier) 不在 server 支援清單") }
        if bytes > limits.maxBytes { reasons.append("檔案超過 \(limits.maxBytes / 1_000_000) MB") }
        if tooManyPixels { reasons.append("像素超過 \(limits.maxPixels / 1_000_000) MP") }

        if reasons.isEmpty, let type = UTType(typeIdentifier),
           let ext = type.preferredFilenameExtension, let mime = type.preferredMIMEType {
            delivered = true
            return PreparedUpload(fileURL: file, filename: "\(baseName).\(ext)", mimeType: mime, byteCount: bytes,
                                  thumbnailURL: thumbnail, conversionReason: nil)
        }
        if reasons.isEmpty { reasons.append("無法判斷檔案格式") }

        // Convert: downsample from the file (never decodes the full image into memory first).
        let scale = tooManyPixels ? (Double(limits.maxPixels) / (Double(width) * Double(height))).squareRoot() : 1
        let longEdge = Double(max(width, height)) * min(scale, 1)
        let edge = max(1, min(limits.maxLongEdge, Int(longEdge.rounded(.down))))
        let output = temporaryURL(extension: "jpg")
        created.append(output)
        try writeJPEG(source: source, maxEdge: edge, metadata: properties, to: output)
        try Task.checkCancellation()
        let outputBytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
        guard outputBytes <= limits.maxBytes else { throw ImagePrepareError.stillTooLarge(outputBytes) }
        delivered = true
        return PreparedUpload(fileURL: output, filename: "\(baseName).jpg", mimeType: "image/jpeg", byteCount: outputBytes,
                              thumbnailURL: thumbnail, conversionReason: reasons.joined(separator: "、"))
    }

    // MARK: - Helpers

    /// Keeps letters, digits, '-' and '_' (ASCII); everything else becomes '_'. Never empty.
    static func sanitizedBaseName(_ name: String) -> String {
        let stem = (name as NSString).lastPathComponent
        let cleaned = String(stem.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
                ? Character(scalar) : "_"
        }.prefix(64))
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_")).isEmpty ? "photo" : cleaned
    }

    static func temporaryURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).\(ext)")
    }

    /// Upright, downsampled image drawn over opaque white.
    private static func whiteBackedImage(source: CGImageSource, maxEdge: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // apply EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ImagePrepareError.conversionFailed
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flattened = context.makeImage() else { throw ImagePrepareError.conversionFailed }
        return flattened
    }

    private static func writeJPEG(source: CGImageSource, maxEdge: Int, metadata: [CFString: Any], to url: URL) throws {
        let image = try whiteBackedImage(source: source, maxEdge: maxEdge)
        try Task.checkCancellation()
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImagePrepareError.conversionFailed
        }
        // Copy the original metadata (EXIF focal length etc.), but the pixels are now upright and resized.
        var properties = metadata
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = nil
        properties[kCGImagePropertyPixelHeight] = nil
        properties[kCGImagePropertyHasAlpha] = nil
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        properties[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw ImagePrepareError.conversionFailed
        }
    }

    private static func writeThumbnail(source: CGImageSource, edge: Int) throws -> URL {
        let image = try whiteBackedImage(source: source, maxEdge: edge)
        let url = temporaryURL(extension: "jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImagePrepareError.conversionFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)  // may be partially written
            throw ImagePrepareError.conversionFailed
        }
        return url
    }
}
