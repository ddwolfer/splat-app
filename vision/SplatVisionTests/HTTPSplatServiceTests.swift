import Foundation
import Synchronization
import Testing
@testable import SplatVision

struct HTTPSplatServiceTests {
    private let session = StubURLProtocol.makeSession()

    private func service(_ handler: @escaping StubURLProtocol.Handler) -> HTTPSplatService {
        HTTPSplatService(baseURL: StubURLProtocol.register(handler), session: session)
    }

    @Test func healthDecodes() async throws {
        let api = service { request, _ in
            #expect(request.url?.path() == "/health")
            #expect(request.httpMethod == "GET")
            return .json(200, #"{"ok": true, "gpu": "NVIDIA GeForce RTX 4060"}"#)
        }
        let health = try await api.health()
        #expect(health == HealthResponse(ok: true, gpu: "NVIDIA GeForce RTX 4060"))
    }

    @Test func generateSendsJSONAndDecodes() async throws {
        let api = service { request, body in
            #expect(request.url?.path() == "/generate")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.timeoutInterval >= 120)
            let json = try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: String]
            #expect(json == ["image_url": "https://example.com/photo.jpg?x=1"])
            return .json(200, #"{"id": "8bfcd029-4d6d-4859-b75a-a8780d90afe4", "ply_url": "/splats/8bfcd029-4d6d-4859-b75a-a8780d90afe4.ply", "seconds": 9.2}"#)
        }
        let result = try await api.generate(imageURL: URL(string: "https://example.com/photo.jpg?x=1")!)
        #expect(result.id == "8bfcd029-4d6d-4859-b75a-a8780d90afe4")
        #expect(result.plyURL == "/splats/8bfcd029-4d6d-4859-b75a-a8780d90afe4.ply")
        #expect(result.seconds == 9.2)
    }

    @Test(arguments: [
        (503, #"{"error": "server busy, try again later"}"#, SplatServiceError.server(status: 503, message: "server busy, try again later")),
        (400, #"{"error": "not an image"}"#, SplatServiceError.server(status: 400, message: "not an image")),
        (500, "<html>oops</html>", SplatServiceError.http(status: 500)),
    ])
    func errorBodiesBecomeMessages(status: Int, body: String, expected: SplatServiceError) async {
        let api = service { _, _ in .json(status, body) }
        await #expect(throws: expected) {
            try await api.generate(imageURL: URL(string: "https://example.com/a.jpg")!)
        }
    }

    @Test func invalidSuccessBodyIsReported() async {
        let api = service { _, _ in .json(200, #"{"id": 1}"#) }
        await #expect {
            try await api.generate(imageURL: URL(string: "https://example.com/a.jpg")!)
        } throws: { error in
            if case .invalidResponse = error as? SplatServiceError { return true }
            return false
        }
    }

    @Test(arguments: [
        ("http://192.168.1.20:8000", "/splats/a.ply", "http://192.168.1.20:8000/splats/a.ply"),
        ("http://192.168.1.20:8000", "splats/a.ply", "http://192.168.1.20:8000/splats/a.ply"),
        ("http://host.local/api", "/splats/a.ply", "http://host.local/api/splats/a.ply"),
    ])
    func endpointJoinsBaseAndRelativePath(base: String, path: String, expected: String) throws {
        let api = HTTPSplatService(baseURL: URL(string: base)!)
        #expect(try api.endpoint(path).absoluteString == expected)
    }

    @Test(arguments: ["http://evil.example/x.ply", "//evil.example/x.ply", ""])
    func endpointRejectsNonRelativePaths(path: String) {
        let api = HTTPSplatService(baseURL: URL(string: "http://192.168.1.20:8000")!)
        #expect(throws: SplatServiceError.self) { try api.endpoint(path) }
    }

    @Test func downloadWritesFileAndReportsProgress() async throws {
        let first = Data(repeating: 0xAB, count: 300_000)
        let second = Data(repeating: 0xCD, count: 200_000)
        let api = service { request, _ in
            #expect(request.url?.path() == "/splats/abc.ply")
            return StubURLProtocol.Reply(status: 200, headers: ["Content-Type": "application/octet-stream"],
                                         chunks: [first, second])
        }
        let seen = Mutex<[DownloadProgress]>([])
        let file = try await api.downloadPLY(plyPath: "/splats/abc.ply") { progress in
            seen.withLock { $0.append(progress) }
        }
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try Data(contentsOf: file) == first + second)
        let maxReceived = seen.withLock { $0.map(\.receivedBytes).max() ?? 0 }
        #expect(maxReceived == Int64(first.count + second.count))
    }

    @Test func downloadErrorStatusIsReported() async {
        let api = service { _, _ in .json(404, #"{"error": "splat not found"}"#) }
        await #expect(throws: SplatServiceError.server(status: 404, message: "splat not found")) {
            try await api.downloadPLY(plyPath: "/splats/gone.ply") { _ in }
        }
    }

    @Test func downloadCanBeCancelled() async {
        let api = service { _, _ in
            StubURLProtocol.Reply(status: 200, chunks: [Data(count: 10)], hang: true)
        }
        let task = Task { try await api.downloadPLY(plyPath: "/splats/slow.ply") { _ in } }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

struct BaseURLTests {
    @Test(arguments: [
        ("http://192.168.1.20:8000", "http://192.168.1.20:8000"),
        ("  http://192.168.1.20:8000/  ", "http://192.168.1.20:8000"),
        ("https://splat.local/api//", "https://splat.local/api"),
        ("192.168.1.20:8000", "http://192.168.1.20:8000"),
    ])
    func validURLsAreNormalised(input: String, expected: String) throws {
        let url = try BaseURL.validate(input).get()
        #expect(url.absoluteString == expected)
    }

    @Test(arguments: [
        ("", BaseURL.ValidationError.empty),
        ("ftp://192.168.1.20", .unsupportedScheme),
        ("file:///etc/hosts", .unsupportedScheme),
        ("http://", .missingHost),
        ("http://host:8000/?a=1", .hasQueryOrFragment),
    ])
    func invalidURLsAreRejected(input: String, expected: BaseURL.ValidationError) {
        guard case let .failure(error) = BaseURL.validate(input) else {
            Issue.record("expected failure for \(input)")
            return
        }
        #expect(error == expected)
    }
}
