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

    @Test func serverErrorsAreSurfaced() async throws {
        let api = try service
        await #expect(throws: SplatServiceError.server(status: 503, message: "server busy, try again later")) {
            try await api.generate(imageURL: URL(string: "https://example.com/busy.jpg")!)
        }
    }
}
