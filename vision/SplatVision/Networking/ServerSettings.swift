import Foundation
import Observation

/// Validation for the server Base URL typed in Settings.
enum BaseURL {
    enum ValidationError: LocalizedError, Equatable {
        case empty
        case malformed
        case unsupportedScheme
        case missingHost
        case hasQueryOrFragment

        var errorDescription: String? {
            switch self {
            case .empty: "請輸入 Base URL，例如 http://192.168.1.20:8000"
            case .malformed: "網址格式不正確"
            case .unsupportedScheme: "只支援 http:// 或 https://"
            case .missingHost: "網址缺少主機（IP 或名稱）"
            case .hasQueryOrFragment: "Base URL 不能包含 ? 或 #"
            }
        }
    }

    /// Trims whitespace and trailing slashes; requires http(s) and a host. A bare "host:port" means http.
    static func validate(_ text: String) -> Result<URL, ValidationError> {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        // "192.168.1.20:8000" → assume plain HTTP (the LAN server).
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            return .failure(.malformed)
        }
        guard scheme == "http" || scheme == "https" else { return .failure(.unsupportedScheme) }
        guard let host = components.host, !host.isEmpty else { return .failure(.missingHost) }
        guard components.query == nil, components.fragment == nil else { return .failure(.hasQueryOrFragment) }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { return .failure(.malformed) }
        return .success(url)
    }
}

/// Which backend a generation talks to. Captured once when a generation starts, so changing
/// Settings mid-way cannot split one generation across two servers.
enum ServiceConfig: Equatable, Sendable {
    case mock
    case server(URL)

    func makeService() -> any SplatService {
        switch self {
        case .mock: MockSplatService()
        case let .server(url): HTTPSplatService(baseURL: url)
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    enum Keys {
        static let baseURL = "serverBaseURL"
        static let useMock = "useMockService"
        static let splatBudget = "splatBudget"
    }

    /// Settings > 顯示品質 choices (0 = all splats).
    static let splatBudgetOptions: [(value: Int, label: String)] = [
        (0, "全部（約 118 萬）"), (800_000, "80 萬"), (500_000, "50 萬"), (300_000, "30 萬"),
    ]

    @ObservationIgnored private let defaults: UserDefaults

    /// Saved, validated Base URL ("" when not set yet).
    private(set) var baseURLString: String
    var useMock: Bool {
        didSet { defaults.set(useMock, forKey: Keys.useMock) }
    }
    /// Max splats to keep when loading (0 = all). Applies the next time a splat is opened.
    var splatBudget: Int {
        didSet { defaults.set(splatBudget, forKey: Keys.splatBudget) }
    }

    var maxSplats: Int? { splatBudget > 0 ? splatBudget : nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Keys.useMock: true])
        baseURLString = defaults.string(forKey: Keys.baseURL) ?? ""
        useMock = defaults.bool(forKey: Keys.useMock)
        splatBudget = defaults.integer(forKey: Keys.splatBudget)
    }

    /// Validates and saves; turns Mock mode off once a real server is configured.
    @discardableResult
    func saveBaseURL(_ text: String) -> Result<URL, BaseURL.ValidationError> {
        let result = BaseURL.validate(text)
        if case let .success(url) = result {
            baseURLString = url.absoluteString
            defaults.set(baseURLString, forKey: Keys.baseURL)
            useMock = false
        }
        return result
    }

    /// The backend to use right now, or nil if Mock is off and no valid Base URL is saved.
    func currentConfig() -> ServiceConfig? {
        if useMock { return .mock }
        guard case let .success(url) = BaseURL.validate(baseURLString) else { return nil }
        return .server(url)
    }
}
