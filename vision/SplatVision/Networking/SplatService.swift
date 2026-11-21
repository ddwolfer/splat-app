import Foundation

/// `GET /health` (API.md).
struct HealthResponse: Codable, Equatable, Sendable {
    var ok: Bool
    var gpu: String?
}

/// `POST /generate` success body (API.md).
struct GenerateResponse: Codable, Equatable, Sendable {
    var id: String
    /// Path relative to the Base URL, e.g. `/splats/<id>.ply`.
    var plyURL: String
    /// Server-side generation time in seconds.
    var seconds: Double

    enum CodingKeys: String, CodingKey {
        case id
        case plyURL = "ply_url"
        case seconds
    }
}

struct DownloadProgress: Equatable, Sendable {
    var receivedBytes: Int64
    /// nil when the server did not send a Content-Length.
    var totalBytes: Int64?

    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }
}

/// The splat-server API (see API.md). Implementations must honour Swift task cancellation.
protocol SplatService: Sendable {
    func health() async throws -> HealthResponse
    func generate(imageURL: URL) async throws -> GenerateResponse
    /// Downloads `plyPath` (a `ply_url` from `generate`) to a new temporary file and returns its URL.
    /// The caller owns (moves or deletes) the returned file.
    func downloadPLY(plyPath: String,
                     progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL
}

enum SplatServiceError: LocalizedError, Equatable {
    /// Non-2xx with an API.md error body: `{"error": "..."}`.
    case server(status: Int, message: String)
    /// Non-2xx without a readable error body.
    case http(status: Int)
    case invalidResponse(String)
    case timedOut
    case cannotConnect(String)

    var errorDescription: String? {
        switch self {
        case let .server(status, message):
            "server 錯誤（\(status)）：\(message)"
        case let .http(status):
            "server 回應 HTTP \(status)"
        case let .invalidResponse(detail):
            "server 回應格式不正確：\(detail)"
        case .timedOut:
            "逾時：server 沒有在時限內回應"
        case let .cannotConnect(detail):
            "連不到 server（\(detail)）。請確認設定裡的 Base URL、server 已啟動，且頭戴裝置與電腦在同一個區網；"
                + "若曾拒絕權限，請到「設定 > 隱私權與安全性 > 區域網路」允許 Splat Vision。"
        }
    }

    /// Maps transport errors to user-facing ones; passes everything else through.
    static func map(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return SplatServiceError.timedOut
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet,
             .dnsLookupFailed, .resourceUnavailable, .internationalRoamingOff, .dataNotAllowed:
            return SplatServiceError.cannotConnect(urlError.localizedDescription)
        default:
            return error
        }
    }
}
