import Foundation
import Testing
@testable import SplatVision

/// End-to-end against `tools/mock_server.py`. Runs only when the server's Base URL is given, e.g.
///   python3 vision/tools/mock_server.py &
///   TEST_RUNNER_SPLAT_MOCK_SERVER=http://<Mac LAN IP>:8765 xcodebuild test ...
/// Using the Mac's LAN IP (not 127.0.0.1) also exercises the ATS local-networking exception.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SPLAT_MOCK_SERVER"] != nil))
struct MockServerIntegrationTests {
    private var service: HTTPSplatService {
        get throws {
            let text = ProcessInfo.processInfo.environment["SPLAT_MOCK_SERVER"] ?? ""
            return HTTPSplatService(baseURL: try BaseURL.validate(text).get())
        }
    }

    @Test func healthGenerateDownloadAndParse() async throws {
        let api = try service
        let health = try await api.health()
        #expect(health.ok)

        let generated = try await api.generate(imageURL: URL(string: "https://example.com/photo.jpg")!)
        let file = try await api.downloadPLY(plyPath: generated.plyURL) { _ in }
        defer { try? FileManager.default.removeItem(at: file) }

        let points = try await SplatLoader.loadPoints(from: file)
        #expect(points.count >= 18_903)
    }

    @Test func multipartUploadGenerateDownload() async throws {
        let api = try service
        let image = try TestImage.write(type: .jpeg, width: 120, height: 90)
        let prepared = try UploadImagePreparer.prepare(file: image, suggestedName: "upload test")
        let generated = try await api.generate(upload: prepared) { _ in }
        let file = try await api.downloadPLY(plyPath: generated.plyURL) { _ in }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64 ?? 0 > 1000)
    }

    @Test func nonImageUploadIsRejectedByTheServer() async throws {
        let api = try service
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data("definitely not an image".utf8).write(to: file)
        let upload = PreparedUpload(fileURL: file, filename: "x.jpg", mimeType: "image/jpeg", byteCount: 23,
                                    thumbnailURL: nil, conversionReason: nil)
        await #expect {
            try await api.generate(upload: upload) { _ in }
        } throws: { error in
            if case .server(400, _) = error as? SplatServiceError { return true }
            return false
        }
    }

    @Test func serverErrorsAreSurfaced() async throws {
        let api = try service
        await #expect(throws: SplatServiceError.server(status: 503, message: "server busy, try again later")) {
            try await api.generate(imageURL: URL(string: "https://example.com/busy.jpg")!)
        }
    }
}
