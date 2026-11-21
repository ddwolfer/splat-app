import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Writes a `multipart/form-data` body with one file field to a temporary file (streamed, so a
/// 20 MB image is never held in memory twice).
enum Multipart {
    struct Body: Sendable {
        let fileURL: URL
        let boundary: String
        let length: Int64

        var contentType: String { "multipart/form-data; boundary=\(boundary)" }
    }

    enum MultipartError: LocalizedError {
        case boundaryCollision

        var errorDescription: String? { "無法產生 multipart 邊界字串" }
    }

    static let chunkSize = 1 << 20

    /// - Parameters: `filename` must already be safe (see `UploadImagePreparer.sanitizedBaseName`).
    static func writeBody(fileURL: URL, fieldName: String = "file", filename: String, mimeType: String) throws -> Body {
        for _ in 0..<3 {
            let boundary = "SplatVision-\(UUID().uuidString)"
            if let body = try write(fileURL: fileURL, fieldName: fieldName, filename: filename,
                                    mimeType: mimeType, boundary: boundary) {
                return body
            }
        }
        throw MultipartError.boundaryCollision
    }

    /// Returns nil if the boundary occurs inside the file (caller retries with another one).
    private static func write(fileURL: URL, fieldName: String, filename: String, mimeType: String,
                              boundary: String) throws -> Body? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-\(UUID().uuidString).bin")
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: output) } }

        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        let reader = try FileHandle(forReadingFrom: fileURL)
        defer { try? reader.close() }

        let head = "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n"
            + "Content-Type: \(mimeType)\r\n\r\n"
        let tail = "\r\n--\(boundary)--\r\n"
        try writer.write(contentsOf: Data(head.utf8))
        var length = Int64(head.utf8.count)

        let marker = Data(boundary.utf8)
        var carry = Data()  // end of the previous chunk, so a boundary split across chunks is still found
        while let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            if (carry + chunk).range(of: marker) != nil { return nil }
            carry = chunk.suffix(marker.count - 1)
            try writer.write(contentsOf: chunk)
            length += Int64(chunk.count)
        }
        try writer.write(contentsOf: Data(tail.utf8))
        length += Int64(tail.utf8.count)
        keep = true
        return Body(fileURL: output, boundary: boundary, length: length)
    }
}

/// A picked photo copied into our temporary folder as a file (not loaded into memory).
struct PickedImageFile: Transferable, Sendable {
    let url: URL
    /// Original file name without extension (e.g. "IMG_1234"), used for the upload's file name.
    let originalName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("picked", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = received.file.pathExtension.isEmpty ? "img" : received.file.pathExtension
            let destination = folder.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedImageFile(url: destination,
                                   originalName: received.file.deletingPathExtension().lastPathComponent)
        }
    }
}
