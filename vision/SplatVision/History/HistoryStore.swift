import Foundation
import Observation

struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    /// Where the PLY came from, so a missing file is re-downloaded from the right place
    /// (not from whatever server is configured now).
    enum Origin: Codable, Equatable, Sendable {
        case mock
        case server(baseURL: URL, plyPath: String)
    }

    /// Server-assigned id (API.md `id`); also the file name stem.
    var id: String
    var imageURL: String
    var createdAt: Date
    var serverSeconds: Double
    var totalSeconds: Double
    var fileSize: Int64
    var origin: Origin

    var fileName: String { "\(id).ply" }
}

enum HistoryError: LocalizedError {
    case invalidID(String)

    var errorDescription: String? {
        switch self {
        case let .invalidID(id): "server 回傳的 id 不能當檔名：\(id)"
        }
    }
}

/// Generated splats kept on disk: `<root>/history.json` + `<root>/splats/<id>.ply`.
///
/// Commit order keeps the two consistent: move the PLY in → atomically write the JSON → only then
/// prune old entries (JSON first, files after). If the JSON write fails, the new file is removed.
/// Files are only ever deleted for entries we know about (delete, prune) or by "全部清除";
/// unindexed files are counted, never removed automatically.
@MainActor
@Observable
final class HistoryStore {
    static let maxEntries = 10

    /// Newest first.
    private(set) var entries: [HistoryEntry] = []
    /// Entries whose PLY file is missing on disk.
    private(set) var missingFileIDs: Set<String> = []

    @ObservationIgnored let rootDirectory: URL
    @ObservationIgnored let splatsDirectory: URL
    @ObservationIgnored private let historyFile: URL
    @ObservationIgnored private let fileManager = FileManager.default
    /// Injectable for tests (to simulate a failed write).
    @ObservationIgnored var writeJSON: (Data, URL) throws -> Void = { data, url in
        try data.write(to: url, options: .atomic)
    }

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        self.splatsDirectory = rootDirectory.appendingPathComponent("splats", isDirectory: true)
        self.historyFile = rootDirectory.appendingPathComponent("history.json")
    }

    static func defaultRootDirectory() -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("SplatVision", isDirectory: true)
    }

    var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.fileSize }
    }

    func fileURL(for entry: HistoryEntry) -> URL {
        splatsDirectory.appendingPathComponent(entry.fileName)
    }

    func entry(forFile url: URL) -> HistoryEntry? {
        entries.first { fileURL(for: $0).standardizedFileURL == url.standardizedFileURL }
    }

    // MARK: - Load

    /// Set when `history.json` exists but could not be read (it is renamed aside, not overwritten).
    private(set) var loadError: String?
    /// PLY files in `splats/` that no entry refers to (e.g. after an index failure or a crash mid-commit).
    /// They are never deleted automatically — only counted, and removed by "全部清除".
    private(set) var unindexedFileCount = 0
    private(set) var unindexedBytes: Int64 = 0

    func load() {
        try? prepareDirectories()
        loadError = nil
        entries = []
        if fileManager.fileExists(atPath: historyFile.path) {
            do {
                let data = try Data(contentsOf: historyFile)
                entries = try Self.decoder.decode([HistoryEntry].self, from: data)
            } catch {
                let backup = rootDirectory.appendingPathComponent(
                    "\(Self.unreadablePrefix)\(Int(Date().timeIntervalSince1970)).json")
                try? fileManager.moveItem(at: historyFile, to: backup)
                loadError = "歷史紀錄讀取失敗（原檔保留為 \(backup.lastPathComponent)）。已下載的 splat 檔都沒有刪除，"
                    + "可用「全部清除」釋放空間。（\(error.localizedDescription)）"
            }
        }
        refreshFileState()
    }

    /// Recomputes missing/unindexed files. Never deletes anything.
    private func refreshFileState() {
        let present = splatFileNames()
        let expected = Set(entries.map(\.fileName))
        missingFileIDs = Set(entries.filter { !present.contains($0.fileName) }.map(\.id))
        let unindexed = present.filter { !expected.contains($0) }
        unindexedFileCount = unindexed.count
        unindexedBytes = unindexed.reduce(0) { total, name in
            let path = splatsDirectory.appendingPathComponent(name).path
            return total + ((try? fileManager.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        }
    }

    private func splatFileNames() -> Set<String> {
        Set((try? fileManager.contentsOfDirectory(atPath: splatsDirectory.path)) ?? [])
    }

    private static let unreadablePrefix = "history.unreadable-"

    // MARK: - Commit

    /// Moves `downloadedFile` into the store and records `entry` (replacing an entry with the same id).
    /// Entries whose file is in `protectedFiles` (e.g. currently displayed) are never pruned.
    @discardableResult
    func commit(downloadedFile: URL, entry: HistoryEntry, protectedFiles: Set<URL> = []) throws -> HistoryEntry {
        guard Self.isSafeFileStem(entry.id) else {
            try? fileManager.removeItem(at: downloadedFile)
            throw HistoryError.invalidID(entry.id)
        }
        try prepareDirectories()

        var entry = entry
        let attributes = try? fileManager.attributesOfItem(atPath: downloadedFile.path)
        entry.fileSize = (attributes?[.size] as? Int64) ?? entry.fileSize

        let destination = fileURL(for: entry)
        let previousEntries = entries
        let hadPreviousFile = fileManager.fileExists(atPath: destination.path)
        if hadPreviousFile {
            // Same id again (e.g. re-download): replace atomically.
            _ = try fileManager.replaceItemAt(destination, withItemAt: downloadedFile)
        } else {
            try fileManager.moveItem(at: downloadedFile, to: destination)
        }

        let updated = [entry] + previousEntries.filter { $0.id != entry.id }
        do {
            try persist(updated)
        } catch {
            if !hadPreviousFile { try? fileManager.removeItem(at: destination) }
            throw error
        }
        entries = updated
        pruneIfNeeded(protectedFiles: protectedFiles.union([destination]))
        refreshFileState()
        return entry
    }

    // MARK: - Delete

    func delete(_ entry: HistoryEntry) throws {
        let remaining = entries.filter { $0.id != entry.id }
        try persist(remaining)
        entries = remaining
        try? fileManager.removeItem(at: fileURL(for: entry))
        refreshFileState()
    }

    /// Deletes every downloaded splat (indexed or not) and unreadable-index backups.
    /// Caller must make sure nothing is displayed/loading first.
    func deleteAll() throws {
        try persist([])
        entries = []
        loadError = nil
        for name in splatFileNames() {
            try? fileManager.removeItem(at: splatsDirectory.appendingPathComponent(name))
        }
        let backups = ((try? fileManager.contentsOfDirectory(atPath: rootDirectory.path)) ?? [])
            .filter { $0.hasPrefix(Self.unreadablePrefix) }
        for name in backups {
            try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(name))
        }
        refreshFileState()
    }

    // MARK: - Internals

    private func pruneIfNeeded(protectedFiles: Set<URL>) {
        guard entries.count > Self.maxEntries else { return }
        let protected = Set(protectedFiles.map(\.standardizedFileURL))
        var kept = entries
        var removed: [HistoryEntry] = []
        // Oldest are at the end.
        var index = kept.count - 1
        while kept.count > Self.maxEntries, index >= 0 {
            if !protected.contains(fileURL(for: kept[index]).standardizedFileURL) {
                removed.append(kept.remove(at: index))
            }
            index -= 1
        }
        guard !removed.isEmpty, (try? persist(kept)) != nil else { return }
        entries = kept
        for entry in removed {
            try? fileManager.removeItem(at: fileURL(for: entry))
        }
    }

    private func persist(_ entries: [HistoryEntry]) throws {
        let data = try Self.encoder.encode(entries)
        try writeJSON(data, historyFile)
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: splatsDirectory, withIntermediateDirectories: true)
        // ~63 MB per splat: keep it out of iCloud backups.
        var root = rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
    }

    /// Server ids become file names; allow only a conservative character set.
    static func isSafeFileStem(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id != "." && id != ".."
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
            && id.unicodeScalars.allSatisfy(\.isASCII)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
