import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SplatVision

// MARK: - Test images

enum TestImage {
    /// Writes a `width`×`height` image. Left half red, right half blue; `alpha` < 1 makes it translucent.
    static func write(type: UTType, width: Int, height: Int, alpha: CGFloat = 1,
                      focalLength35mm: Int? = 26, orientation: Int = 1) throws -> URL {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: alpha))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        let image = context.makeImage()!

        let ext = type.preferredFilenameExtension ?? "img"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).\(ext)")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if let focalLength35mm {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifFocalLenIn35mmFilm: focalLength35mm,
                kCGImagePropertyExifFocalLength: 4.2,
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImagePrepareError.conversionFailed }
        return url
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    }

    static func typeIdentifier(_ url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    /// RGBA of the pixel at (x, y) from the top-left, after decoding.
    static func pixel(_ url: URL, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (data[0], data[1], data[2])
    }
}

// MARK: - UploadImagePreparer

struct UploadImagePreparerTests {
    @Test(arguments: [UTType.jpeg, .png, .heic])
    func supportedSmallImagesAreSentAsIs(type: UTType) throws {
        let file = try TestImage.write(type: type, width: 64, height: 48)
        let prepared = try UploadImagePreparer.prepare(file: file, suggestedName: "IMG 1234")
        #expect(prepared.fileURL == file)  // original bytes, EXIF untouched
        #expect(prepared.conversionReason == nil)
        #expect(prepared.mimeType == type.preferredMIMEType)
        #expect(prepared.filename == "IMG_1234.\(type.preferredFilenameExtension!)")
        #expect(prepared.thumbnailURL != nil)
    }

    @Test func unsupportedFormatIsConvertedToJPEGKeepingFocalLength() throws {
        let file = try TestImage.write(type: .tiff, width: 64, height: 48, focalLength35mm: 26)
        let prepared = try UploadImagePreparer.prepare(file: file, suggestedName: "scan")
        #expect(prepared.fileURL != file)
        #expect(prepared.mimeType == "image/jpeg")
        #expect(prepared.filename == "scan.jpg")
        #expect(TestImage.typeIdentifier(prepared.fileURL) == UTType.jpeg.identifier)
        let exif = TestImage.properties(prepared.fileURL)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int == 26)
    }

    @Test func oversizedImageIsDownsampledUnderThePixelLimit() throws {
        let file = try TestImage.write(type: .jpeg, width: 400, height: 300)
        var limits = UploadImagePreparer.Limits()
        limits.maxPixels = 30_000
        let prepared = try UploadImagePreparer.prepare(file: file, suggestedName: nil, limits: limits)
        let properties = TestImage.properties(prepared.fileURL)
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        #expect(width * height <= 30_000)
        #expect(prepared.conversionReason?.contains("像素") == true)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int == 26)
    }

    @Test func conversionAppliesOrientation() throws {
        // Orientation 6 = rotate 90° CW to display: a 64×48 file is shown as 48×64.
        let file = try TestImage.write(type: .tiff, width: 64, height: 48, orientation: 6)
        let prepared = try UploadImagePreparer.prepare(file: file, suggestedName: nil)
        let properties = TestImage.properties(prepared.fileURL)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 48)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 64)
        #expect((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    @Test func transparentAreasBecomeWhiteNotBlack() throws {
        let file = try TestImage.write(type: .png, width: 64, height: 48, alpha: 0)  // fully transparent
        var limits = UploadImagePreparer.Limits()
        limits.maxPixels = 3_000  // 64×48 = 3072: forces a conversion
        let prepared = try UploadImagePreparer.prepare(file: file, suggestedName: nil, limits: limits)
        #expect(prepared.mimeType == "image/jpeg")
        let pixel = TestImage.pixel(prepared.fileURL, x: 5, y: 5)
        #expect(pixel.r > 240 && pixel.g > 240 && pixel.b > 240)
    }

    @Test func byteLimitMatchesTheServer() {
        #expect(UploadImagePreparer.Limits().maxBytes == 20 * 1024 * 1024)  // server/config.py max_upload_bytes
        #expect(UploadImagePreparer.Limits().maxPixels == 40_000_000)
    }

    @Test func cancelledPreparationLeavesNoFiles() async throws {
        let file = try TestImage.write(type: .tiff, width: 64, height: 48)  // would be converted
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("upload-") })
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try UploadImagePreparer.prepare(file: file, suggestedName: nil)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("upload-") })
        #expect(after.subtracting(before).isEmpty)
    }

    @Test func nonImageIsRejected() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data("not an image".utf8).write(to: file)
        #expect(throws: ImagePrepareError.notAnImage) {
            try UploadImagePreparer.prepare(file: file, suggestedName: nil)
        }
    }

    @Test(arguments: [("../../etc/passwd", "passwd"), ("a\"b\r\nc", "a_b__c"), ("照片", "photo"), ("", "photo")])
    func fileNamesAreSanitised(input: String, expected: String) {
        #expect(UploadImagePreparer.sanitizedBaseName(input) == expected)
    }
}

// MARK: - Multipart

struct MultipartTests {
    @Test func bodyContainsOneFileFieldWithTheExactBytes() throws {
        let payload = Data((0..<3_000_000).map { UInt8($0 % 251) })  // spans several chunks
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bin")
        try payload.write(to: file)
        let body = try Multipart.writeBody(fileURL: file, filename: "IMG_1.heic", mimeType: "image/heic")
        defer { try? FileManager.default.removeItem(at: body.fileURL) }

        let data = try Data(contentsOf: body.fileURL)
        #expect(Int64(data.count) == body.length)
        let head = "--\(body.boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"IMG_1.heic\"\r\n"
            + "Content-Type: image/heic\r\n\r\n"
        let tail = "\r\n--\(body.boundary)--\r\n"
        #expect(data.prefix(head.utf8.count) == Data(head.utf8))
        #expect(data.suffix(tail.utf8.count) == Data(tail.utf8))
        #expect(data.dropFirst(head.utf8.count).dropLast(tail.utf8.count) == payload)
        #expect(body.contentType == "multipart/form-data; boundary=\(body.boundary)")
    }
}

// MARK: - HTTP upload

struct HTTPUploadTests {
    @Test func uploadSendsMultipartAndDecodes() async throws {
        let session = StubURLProtocol.makeSession()
        let base = StubURLProtocol.register { request, body in
            #expect(request.url?.path() == "/generate")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            if let body {
                #expect(body.range(of: Data("name=\"file\"; filename=\"p.jpg\"".utf8)) != nil)
            }
            return .json(200, #"{"id": "u-1", "ply_url": "/splats/u-1.ply", "seconds": 9}"#)
        }
        let api = HTTPSplatService(baseURL: base, session: session)
        let image = try TestImage.write(type: .jpeg, width: 32, height: 32)
        let upload = PreparedUpload(fileURL: image, filename: "p.jpg", mimeType: "image/jpeg",
                                    byteCount: 100, thumbnailURL: nil, conversionReason: nil)
        let result = try await api.generate(upload: upload) { _ in }
        #expect(result.id == "u-1")
    }

    @Test func uploadErrorsUseTheServerMessage() async throws {
        let session = StubURLProtocol.makeSession()
        let base = StubURLProtocol.register { _, _ in .json(413, #"{"error": "image too large"}"#) }
        let api = HTTPSplatService(baseURL: base, session: session)
        let image = try TestImage.write(type: .jpeg, width: 32, height: 32)
        let upload = PreparedUpload(fileURL: image, filename: "p.jpg", mimeType: "image/jpeg",
                                    byteCount: 100, thumbnailURL: nil, conversionReason: nil)
        await #expect(throws: SplatServiceError.server(status: 413, message: "image too large")) {
            try await api.generate(upload: upload) { _ in }
        }
    }
}
