import Foundation

/// splat-server client over HTTP, following API.md.
struct HTTPSplatService: SplatService {
    static let generateTimeout: TimeInterval = 300
    static let requestTimeout: TimeInterval = 15
    /// Time allowed between bytes while downloading a (~63 MB) PLY.
    static let downloadIdleTimeout: TimeInterval = 60

    /// Validated base URL without a trailing slash (see `BaseURL.validate`).
    let baseURL: URL
    let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func health() async throws -> HealthResponse {
        var request = URLRequest(url: try endpoint("/health"))
        request.timeoutInterval = Self.requestTimeout
        return try await send(request, as: HealthResponse.self)
    }

    func generate(imageURL: URL) async throws -> GenerateResponse {
        var request = URLRequest(url: try endpoint("/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.generateTimeout
        request.httpBody = try JSONEncoder().encode(["image_url": imageURL.absoluteString])
        return try await send(request, as: GenerateResponse.self)
    }

    func downloadPLY(plyPath: String,
                     progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        var request = URLRequest(url: try endpoint(plyPath))
        request.timeoutInterval = Self.downloadIdleTimeout
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-\(UUID().uuidString).ply")

        let box = DownloadTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                let task = session.downloadTask(with: request) { location, response, error in
                    box.invalidateObservation()
                    if let error {
                        continuation.resume(throwing: SplatServiceError.map(error))
                        return
                    }
                    guard let location, let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: SplatServiceError.invalidResponse("下載沒有回應"))
                        return
                    }
                    // `location` is deleted when this handler returns, so read or move it now.
                    guard (200..<300).contains(http.statusCode) else {
                        let body = try? Data(contentsOf: location)
                        continuation.resume(throwing: Self.statusError(http.statusCode, body: body))
                        return
                    }
                    do {
                        try FileManager.default.moveItem(at: location, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.start(task, progress: progress)
            }
        } onCancel: {
            box.cancel()
        }
    }

    // MARK: - Helpers

    /// Joins the base URL and an API path. API.md paths (and `ply_url`) are relative to the Base URL,
    /// which may itself carry a path prefix, so this is a string join rather than URL resolution.
    func endpoint(_ path: String) throws -> URL {
        guard !path.isEmpty, !path.contains("://"), !path.hasPrefix("//") else {
            throw SplatServiceError.invalidResponse("不是相對路徑：\(path)")
        }
        let joined = baseURL.absoluteString + (path.hasPrefix("/") ? path : "/" + path)
        guard let url = URL(string: joined) else {
            throw SplatServiceError.invalidResponse("無法組成網址：\(path)")
        }
        return url
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SplatServiceError.map(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SplatServiceError.invalidResponse("不是 HTTP 回應")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.statusError(http.statusCode, body: data)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SplatServiceError.invalidResponse(String(describing: error))
        }
    }

    static func statusError(_ status: Int, body: Data?) -> SplatServiceError {
        struct ErrorBody: Decodable { var error: String }
        if let body, let decoded = try? JSONDecoder().decode(ErrorBody.self, from: body) {
            return .server(status: status, message: decoded.error)
        }
        return .http(status: status)
    }
}

/// Holds the download task so cancellation and progress observation can reach it from any thread.
private final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    func start(_ task: URLSessionDownloadTask, progress: @escaping @Sendable (DownloadProgress) -> Void) {
        // URLSessionTask's byte counters are KVO-observable (task.progress units are not always bytes).
        let observation = task.observe(\.countOfBytesReceived, options: [.new]) { task, _ in
            let expected = task.countOfBytesExpectedToReceive
            progress(DownloadProgress(receivedBytes: task.countOfBytesReceived,
                                      totalBytes: expected > 0 ? expected : nil))
        }
        let shouldCancel = lock.withLock {
            self.task = task
            self.observation = observation
            return cancelled
        }
        task.resume()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }

    func invalidateObservation() {
        let observation = lock.withLock {
            let current = self.observation
            self.observation = nil
            return current
        }
        observation?.invalidate()
    }
}
