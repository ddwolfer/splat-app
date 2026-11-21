import Foundation
import Testing
@testable import SplatVision

/// Fake backend. An image URL containing "stubborn" ignores cancellation and still returns after a delay,
/// like a server response that arrives after the user pressed Cancel.
private struct FakeService: SplatService {
    func health() async throws -> HealthResponse { HealthResponse(ok: true, gpu: "fake") }

    func generate(imageURL: URL) async throws -> GenerateResponse {
        let stubborn = imageURL.absoluteString.contains("stubborn")
        let delay: Duration = stubborn ? .milliseconds(400) : .milliseconds(50)
        if stubborn {
            let deadline = ContinuousClock.now + delay
            while ContinuousClock.now < deadline { await Task.yield() }
        } else {
            try await Task.sleep(for: delay)
        }
        let id = stubborn ? "stubborn" : "fresh"
        return GenerateResponse(id: id, plyURL: "/splats/\(id).ply", seconds: 1)
    }

    func downloadPLY(plyPath: String, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).ply")
        try Data(repeating: 1, count: 100).write(to: url)
        progress(DownloadProgress(receivedBytes: 100, totalBytes: 100))
        return url
    }
}

@MainActor
struct GenerationControllerTests {
    private func makeController() -> (GenerationController, HistoryStore) {
        let defaults = UserDefaults(suiteName: "gen-test-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)  // Mock mode by default
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gen-test-\(UUID().uuidString)")
        let history = HistoryStore(rootDirectory: root)
        history.load()
        let controller = GenerationController(settings: settings, history: history, immersive: ImmersiveController())
        controller.makeService = { _ in FakeService() }
        return (controller, history)
    }

    private func waitUntilIdle(_ controller: GenerationController) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.phase.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func successfulRunIsSavedToHistory() async throws {
        let (controller, history) = makeController()
        controller.start(imageURLText: "https://example.com/photo.jpg")
        await waitUntilIdle(controller)
        guard case .finished = controller.phase else {
            Issue.record("expected finished, got \(controller.phase)")
            return
        }
        #expect(history.entries.map(\.id) == ["fresh"])
        #expect(history.entries.first?.origin == .mock)
    }

    @Test func cancelledRunNeverLeaksIntoTheNextOne() async throws {
        let (controller, history) = makeController()
        controller.start(imageURLText: "https://example.com/stubborn.jpg")
        try await Task.sleep(for: .milliseconds(50))
        controller.cancel()
        #expect(controller.phase == .cancelled)

        controller.start(imageURLText: "https://example.com/photo.jpg")
        await waitUntilIdle(controller)
        // Give the stubborn (cancelled) run time to come back and try to commit.
        try await Task.sleep(for: .milliseconds(600))

        #expect(history.entries.map(\.id) == ["fresh"])
        guard case .finished = controller.phase else {
            Issue.record("expected finished, got \(controller.phase)")
            return
        }
    }

    @Test func failedCommitLeavesNoTempFile() async throws {
        let (controller, history) = makeController()
        let recorder = TempFileRecorder()
        controller.makeService = { _ in BadIDService(recorder: recorder) }
        controller.start(imageURLText: "https://example.com/photo.jpg")
        await waitUntilIdle(controller)
        guard case .failed = controller.phase else {
            Issue.record("expected failed, got \(controller.phase)")
            return
        }
        #expect(history.entries.isEmpty)
        let file = try #require(recorder.url)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test(arguments: ["", "not a url", "ftp://example.com/a.jpg", "file:///etc/passwd"])
    func invalidImageURLsAreRejected(text: String) {
        let (controller, _) = makeController()
        controller.start(imageURLText: text)
        guard case .failed = controller.phase else {
            Issue.record("expected failed for \(text), got \(controller.phase)")
            return
        }
    }
}

private final class TempFileRecorder: @unchecked Sendable {
    var url: URL?
}

/// Returns an id that is not a safe file name, so the history commit fails after the download.
private struct BadIDService: SplatService {
    let recorder: TempFileRecorder

    func health() async throws -> HealthResponse { HealthResponse(ok: true, gpu: nil) }

    func generate(imageURL: URL) async throws -> GenerateResponse {
        GenerateResponse(id: "../escape", plyURL: "/splats/x.ply", seconds: 1)
    }

    func downloadPLY(plyPath: String, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).ply")
        try Data(repeating: 1, count: 100).write(to: url)
        recorder.url = url
        return url
    }
}
