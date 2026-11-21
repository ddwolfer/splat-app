import Foundation

/// Where a splat comes from.
enum SplatSource: Codable, Hashable, Sendable {
    /// `mock_sharp.ply`, generated into the app bundle at build time by `tools/make_mock_ply.py`.
    case bundledMock
    /// A downloaded PLY kept in the history store.
    case localFile(URL)

    var displayName: String {
        switch self {
        case .bundledMock: "範例（mock）"
        case let .localFile(url): url.deletingPathExtension().lastPathComponent
        }
    }

    func resolveURL() throws -> URL {
        switch self {
        case .bundledMock:
            guard let url = Bundle.main.url(forResource: "mock_sharp", withExtension: "ply") else {
                throw SplatSourceError.missingBundledMock
            }
            return url
        case let .localFile(url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw SplatSourceError.missingFile(url.lastPathComponent)
            }
            return url
        }
    }
}

enum SplatSourceError: LocalizedError {
    case missingBundledMock
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .missingBundledMock: "App 內找不到 mock_sharp.ply（建置時的 Generate mock PLY 步驟沒有執行？）"
        case let .missingFile(name): "找不到檔案 \(name)，可在歷史清單重新下載"
        }
    }
}

/// One request to show a splat. Each opening of the immersive space gets a fresh `id`, so results
/// from an older (closed) session can be recognised and ignored.
struct SplatRequest: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let source: SplatSource

    init(source: SplatSource, id: UUID = UUID()) {
        self.id = id
        self.source = source
    }
}
