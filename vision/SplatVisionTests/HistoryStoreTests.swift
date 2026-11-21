import Foundation
import Testing
@testable import SplatVision

@MainActor
struct HistoryStoreTests {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("history-test-\(UUID().uuidString)", isDirectory: true)

    private func makeDownload(_ bytes: Int = 1000) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString).ply")
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    private func entry(_ id: String, at seconds: TimeInterval = 0) -> HistoryEntry {
        HistoryEntry(id: id, imageURL: "https://example.com/\(id).jpg", createdAt: Date(timeIntervalSince1970: seconds),
                     serverSeconds: 9, totalSeconds: 12, fileSize: 0,
                     origin: .server(baseURL: URL(string: "http://192.168.1.20:8000")!, plyPath: "/splats/\(id).ply"))
    }

    @Test func commitPersistsAndReloads() throws {
        let store = HistoryStore(rootDirectory: root)
        store.load()
        let saved = try store.commit(downloadedFile: try makeDownload(1234), entry: entry("a"))
        #expect(saved.fileSize == 1234)
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: saved).path))

        let reloaded = HistoryStore(rootDirectory: root)
        reloaded.load()
        #expect(reloaded.entries == [saved])
        #expect(reloaded.missingFileIDs.isEmpty)
    }

    @Test func failedJSONWriteRemovesTheNewFile() throws {
        let store = HistoryStore(rootDirectory: root)
        store.load()
        struct DiskFull: Error {}
        store.writeJSON = { _, _ in throw DiskFull() }
        let download = try makeDownload()
        #expect(throws: DiskFull.self) { try store.commit(downloadedFile: download, entry: entry("a")) }
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.splatsDirectory.appendingPathComponent("a.ply").path))
    }

    @Test func pruneKeepsNewestAndSkipsProtected() throws {
        let store = HistoryStore(rootDirectory: root)
        store.load()
        for i in 0..<HistoryStore.maxEntries {
            try store.commit(downloadedFile: try makeDownload(), entry: entry("e\(i)", at: Double(i)))
        }
        // The oldest one (e0) is on screen right now.
        let oldest = try #require(store.entries.last)
        #expect(oldest.id == "e0")
        let protected: Set<URL> = [store.fileURL(for: oldest).standardizedFileURL]

        try store.commit(downloadedFile: try makeDownload(), entry: entry("new", at: 100), protectedFiles: protected)

        #expect(store.entries.count == HistoryStore.maxEntries)
        #expect(store.entries.first?.id == "new")
        #expect(store.entries.contains { $0.id == "e0" })        // protected, kept
        #expect(!store.entries.contains { $0.id == "e1" })       // next oldest, pruned
        #expect(!FileManager.default.fileExists(atPath: store.splatsDirectory.appendingPathComponent("e1.ply").path))
    }

    @Test func deleteRemovesRecordAndFile() throws {
        let store = HistoryStore(rootDirectory: root)
        store.load()
        let saved = try store.commit(downloadedFile: try makeDownload(), entry: entry("a"))
        try store.delete(saved)
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: saved).path))
    }

    @Test func loadFlagsMissingFilesAndKeepsOrphans() throws {
        let store = HistoryStore(rootDirectory: root)
        store.load()
        let kept = try store.commit(downloadedFile: try makeDownload(), entry: entry("kept"))
        let gone = try store.commit(downloadedFile: try makeDownload(), entry: entry("gone"))
        try FileManager.default.removeItem(at: store.fileURL(for: gone))
        let orphan = store.splatsDirectory.appendingPathComponent("orphan.ply")
        try Data([1, 2, 3]).write(to: orphan)

        let reloaded = HistoryStore(rootDirectory: root)
        reloaded.load()
        #expect(reloaded.entries.map(\.id).sorted() == ["gone", "kept"])
        #expect(reloaded.missingFileIDs == ["gone"])
        #expect(FileManager.default.fileExists(atPath: orphan.path))   // never auto-deleted
        #expect(reloaded.unindexedFileCount == 1)
        #expect(FileManager.default.fileExists(atPath: reloaded.fileURL(for: kept).path))
    }

    private func splatFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("splats").path).sorted()
    }

    @Test func unreadableIndexNeverCostsFilesAcrossLaterLaunches() throws {
        let store = HistoryStore(rootDirectory: root)
        store.load()
        try store.commit(downloadedFile: try makeDownload(), entry: entry("precious"))
        try Data("{ not json".utf8).write(to: root.appendingPathComponent("history.json"))

        let second = HistoryStore(rootDirectory: root)
        second.load()
        #expect(second.loadError != nil)
        #expect(second.unindexedFileCount == 1)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("history.unreadable-") }
        #expect(backups.count == 1)

        // A new generation after the failure, then two more launches: the old file must survive.
        try second.commit(downloadedFile: try makeDownload(), entry: entry("new"))
        let third = HistoryStore(rootDirectory: root)
        third.load()
        let fourth = HistoryStore(rootDirectory: root)
        fourth.load()
        #expect(fourth.entries.map(\.id) == ["new"])
        #expect(try splatFiles() == ["new.ply", "precious.ply"])
        #expect(fourth.unindexedFileCount == 1)
    }

    @Test func filesWithoutAnyIndexAreKeptAndCounted() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("splats"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("splats/lost.ply"))
        let store = HistoryStore(rootDirectory: root)
        store.load()
        #expect(store.unindexedFileCount == 1)
        #expect(store.unindexedBytes == 3)
        #expect(try splatFiles() == ["lost.ply"])
    }

    @Test func deleteAllRemovesUnindexedFilesAndBackups() throws {
        let store = HistoryStore(rootDirectory: root)
        store.load()
        try store.commit(downloadedFile: try makeDownload(), entry: entry("a"))
        try Data([1]).write(to: root.appendingPathComponent("splats/lost.ply"))
        try Data("{ bad".utf8).write(to: root.appendingPathComponent("history.json"))
        store.load()  // unreadable → backup + unindexed files

        try store.deleteAll()
        #expect(try splatFiles().isEmpty)
        #expect(store.unindexedFileCount == 0)
        #expect(store.loadError == nil)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("history.unreadable-") }
        #expect(backups.isEmpty)
    }

    @Test(arguments: ["../evil", "a/b", "", "名字"])
    func unsafeIDsAreRejected(id: String) throws {
        let store = HistoryStore(rootDirectory: root)
        store.load()
        #expect(throws: HistoryError.self) { try store.commit(downloadedFile: try makeDownload(), entry: entry(id)) }
        #expect(store.entries.isEmpty)
    }
}
