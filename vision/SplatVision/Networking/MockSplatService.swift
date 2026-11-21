import Foundation

/// Offline stand-in for splat-server: waits a bit, then "returns" the bundled `mock_sharp.ply`.
struct MockSplatService: SplatService {
    static let mockPathPrefix = "/mock/"
    var generateDelay: Duration = .seconds(1.5)

    func health() async throws -> HealthResponse {
        HealthResponse(ok: true, gpu: "Mock（不連網路）")
    }

    func generate(imageURL: URL) async throws -> GenerateResponse {
        let clock = ContinuousClock()
        let start = clock.now
        try await Task.sleep(for: generateDelay)
        let elapsed = clock.now - start
        let id = "mock-\(UUID().uuidString.prefix(8).lowercased())"
        return GenerateResponse(id: id,
                                plyURL: "\(Self.mockPathPrefix)\(id).ply",
                                seconds: Double(elapsed.components.seconds)
                                    + Double(elapsed.components.attoseconds) / 1e18)
    }

    func downloadPLY(plyPath: String,
                     progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let source = try SplatSource.bundledMock.resolveURL()
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
        // A few progress steps so the UI path is exercised.
        for step in 1...4 {
            try await Task.sleep(for: .milliseconds(100))
            progress(DownloadProgress(receivedBytes: size * Int64(step) / 4, totalBytes: size))
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-\(UUID().uuidString).ply")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
