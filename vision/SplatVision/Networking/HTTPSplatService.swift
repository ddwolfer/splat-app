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

    func generate(upload: PreparedUpload,
                  progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> GenerateResponse {
        let body = try Multipart.writeBody(fileURL: upload.fileURL, filename: upload.filename, mimeType: upload.mimeType)
        defer { try? FileManager.default.removeItem(at: body.fileURL) }
        var request = URLRequest(url: try endpoint("/generate"))
        request.httpMethod = "POST"
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(body.length), forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = Self.generateTimeout

        let box = TaskBox()
        let (data, response): (Data, URLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.uploadTask(with: request, fromFile: body.fileURL) { data, response, error in
                    box.invalidateObservation()
                    if let error {
                        continuation.resume(throwing: SplatServiceError.map(error))
                    } else if let response {
                        continuation.resume(returning: (data ?? Data(), response))
                    } else {
                        continuation.resume(throwing: SplatServiceError.invalidResponse("上傳沒有回應"))
                    }
                }
                let observation = task.observe(\.countOfBytesSent, options: [.new]) { task, _ in
                    let expected = task.countOfBytesExpectedToSend
                    progress(TransferProgress(completedBytes: task.countOfBytesSent,
                                              totalBytes: expected > 0 ? expected : body.length))
                }
                box.start(task, observation: observation)
            }
        } onCancel: {
            box.cancel()
        }
        return try decodeResponse(data: data, response: response, as: GenerateResponse.self)
    }

    func downloadPLY(plyPath: String,
                     progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> URL {
        var request = URLRequest(url: try endpoint(plyPath))
        request.timeoutInterval = Self.downloadIdleTimeout
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-\(UUID().uuidString).ply")

        let box = TaskBox()
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
                // URLSessionTask's byte counters are KVO-observable (task.progress units are not always bytes).
                let observation = task.observe(\.countOfBytesReceived, options: [.new]) { task, _ in
                    let expected = task.countOfBytesExpectedToReceive
                    progress(TransferProgress(completedBytes: task.countOfBytesReceived,
                                              totalBytes: expected > 0 ? expected : nil))
                }
                box.start(task, observation: observation)
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
        return try decodeResponse(data: data, response: response, as: type)
    }

    private func decodeResponse<T: Decodable>(data: Data, response: URLResponse, as type: T.Type) throws -> T {
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

/// Holds a URLSession task so cancellation and progress observation can reach it from any thread.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var observation: NSKeyValueObservation?
    private var cancelled = false

    func start(_ task: URLSessionTask, observation: NSKeyValueObservation) {
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
