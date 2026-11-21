import Foundation
import Observation

/// Runs "image URL or picked photo → POST /generate → download PLY → save to history → show".
///
/// Each run has its own generation id; every side effect (progress, history commit, auto-show) first
/// checks that the id is still current, so a cancelled run can never leak into the next one.
@MainActor
@Observable
final class GenerationController {
    struct Summary: Equatable {
        var serverSeconds: Double
        var downloadSeconds: Double
        var totalSeconds: Double
        var fileSize: Int64
    }

    enum Phase: Equatable {
        case idle
        /// Getting the picked photo from Photos/iCloud and checking/converting it.
        case preparing(startedAt: Date)
        case uploading(startedAt: Date, progress: TransferProgress)
        case generating(startedAt: Date)
        case downloading(startedAt: Date, progress: TransferProgress)
        case finished(Summary)
        case failed(message: String)
        case cancelled

        var isRunning: Bool {
            switch self {
            case .preparing, .uploading, .generating, .downloading: true
            default: false
            }
        }
    }

    private(set) var phase: Phase = .idle

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let immersive: ImmersiveController
    @ObservationIgnored private var currentID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Injectable for tests.
    @ObservationIgnored var makeService: (ServiceConfig) -> any SplatService = { $0.makeService() }

    init(settings: SettingsStore, history: HistoryStore, immersive: ImmersiveController) {
        self.settings = settings
        self.history = history
        self.immersive = immersive
    }

    enum InputError: LocalizedError {
        case invalidImageURL
        case noServerConfigured
        case noImageData

        var errorDescription: String? {
            switch self {
            case .invalidImageURL: "請輸入 http:// 或 https:// 開頭的圖片網址"
            case .noServerConfigured: "尚未設定 server：請到設定輸入 Base URL，或開啟 Mock 模式"
            case .noImageData: "無法從照片取得這張圖片（若在 iCloud，請確認網路後再試）"
            }
        }
    }

    private enum Input {
        case url(URL)
        case upload(PreparedUpload)
    }

    static func validateImageURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              let url = components.url else { return nil }
        return url
    }

    /// Starts a generation. Ignored while one is running (the button is disabled then).
    func start(imageURLText: String) {
        guard !phase.isRunning else { return }
        guard let imageURL = Self.validateImageURL(imageURLText) else {
            phase = .failed(message: InputError.invalidImageURL.localizedDescription)
            return
        }
        guard let config = settings.currentConfig() else {
            phase = .failed(message: InputError.noServerConfigured.localizedDescription)
            return
        }
        let id = UUID()
        currentID = id
        let service = makeService(config)
        let start = Date()
        // Set synchronously so the UI (and a second tap) sees "running" immediately.
        phase = .generating(startedAt: start)
        task = Task { await run(id: id, service: service, config: config, input: .url(imageURL), start: start) }
    }

    /// Starts a generation from a picked photo. `loader` fetches it (from Photos/iCloud) to a temporary
    /// file; the generation id covers that step too, so a slow, superseded pick can never be uploaded.
    func startUpload(loader: @escaping @Sendable () async throws -> PickedImageFile?) {
        guard !phase.isRunning else { return }
        guard let config = settings.currentConfig() else {
            phase = .failed(message: InputError.noServerConfigured.localizedDescription)
            return
        }
        let id = UUID()
        currentID = id
        let service = makeService(config)
        let start = Date()
        phase = .preparing(startedAt: start)
        task = Task { await runUpload(id: id, service: service, config: config, loader: loader, start: start) }
    }

    func cancel() {
        guard phase.isRunning else { return }
        currentID = nil
        task?.cancel()
        task = nil
        phase = .cancelled
    }

    /// Re-downloads a history entry whose file is missing, from the place it originally came from.
    func redownload(_ entry: HistoryEntry) {
        guard !phase.isRunning else { return }
        let config: ServiceConfig
        let plyPath: String
        switch entry.origin {
        case .mock:
            config = .mock
            plyPath = "\(MockSplatService.mockPathPrefix)\(entry.id).ply"
        case let .server(baseURL, path):
            config = .server(baseURL)
            plyPath = path
        }
        let id = UUID()
        currentID = id
        let service = makeService(config)
        let start = Date()
        phase = .downloading(startedAt: start, progress: TransferProgress(completedBytes: 0, totalBytes: nil))
        task = Task { await runDownload(id: id, service: service, entry: entry, plyPath: plyPath, start: start) }
    }

    // MARK: - Runs

    private func runUpload(id: UUID, service: any SplatService, config: ServiceConfig,
                           loader: @escaping @Sendable () async throws -> PickedImageFile?, start: Date) async {
        var temporaryFiles: [URL] = []
        defer { temporaryFiles.forEach(Self.removeIfPresent) }
        do {
            guard let picked = try await loader() else { throw InputError.noImageData }
            temporaryFiles.append(picked.url)
            guard isCurrent(id) else { return }
            let prepared = try await Self.prepareInBackground(picked)
            temporaryFiles.append(prepared.fileURL)
            if let thumbnail = prepared.thumbnailURL { temporaryFiles.append(thumbnail) }
            guard isCurrent(id) else { return }
            await run(id: id, service: service, config: config, input: .upload(prepared), start: start)
        } catch {
            finish(id: id, error: error)
        }
    }

    /// Image checks/conversion are CPU and I/O heavy: never on the main actor.
    @concurrent
    private static func prepareInBackground(_ picked: PickedImageFile) async throws -> PreparedUpload {
        try UploadImagePreparer.prepare(file: picked.url, suggestedName: picked.originalName)
    }

    private func run(id: UUID, service: any SplatService, config: ServiceConfig, input: Input, start: Date) async {
        do {
            let generated: GenerateResponse
            let sourceDescription: String
            var thumbnail: URL?
            switch input {
            case let .url(imageURL):
                generated = try await service.generate(imageURL: imageURL)
                sourceDescription = imageURL.absoluteString
            case let .upload(prepared):
                phase = .uploading(startedAt: Date(), progress: TransferProgress(completedBytes: 0, totalBytes: prepared.byteCount))
                generated = try await service.generate(upload: prepared) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.isCurrent(id), case let .uploading(uploadStart, _) = self.phase else { return }
                        if let total = progress.totalBytes, progress.completedBytes >= total {
                            self.phase = .generating(startedAt: Date())  // all bytes sent: now waiting for the server
                        } else {
                            self.phase = .uploading(startedAt: uploadStart, progress: progress)
                        }
                    }
                }
                sourceDescription = "upload:\(prepared.filename)"
                thumbnail = prepared.thumbnailURL
            }
            guard isCurrent(id) else { return }

            let downloadStart = Date()
            let file = try await download(id: id, service: service, plyPath: generated.plyURL, startedAt: downloadStart)
            // Whatever happens next, never leave a ~63 MB temp file behind (a successful commit moves it away).
            defer { Self.removeIfPresent(file) }
            let downloadSeconds = Date().timeIntervalSince(downloadStart)
            guard isCurrent(id) else { return }

            let origin: HistoryEntry.Origin = switch config {
            case .mock: .mock
            case let .server(baseURL): .server(baseURL: baseURL, plyPath: generated.plyURL)
            }
            let entry = HistoryEntry(id: generated.id,
                                     imageURL: sourceDescription,
                                     createdAt: start,
                                     serverSeconds: generated.seconds,
                                     totalSeconds: Date().timeIntervalSince(start),
                                     fileSize: 0,
                                     origin: origin)
            let saved = try history.commit(downloadedFile: file, entry: entry, thumbnailFile: thumbnail,
                                           protectedFiles: immersive.protectedFiles)
            phase = .finished(Summary(serverSeconds: saved.serverSeconds,
                                      downloadSeconds: downloadSeconds,
                                      totalSeconds: saved.totalSeconds,
                                      fileSize: saved.fileSize))
            currentID = nil
            immersive.show(.localFile(history.fileURL(for: saved)))
        } catch {
            finish(id: id, error: error)
        }
    }

    private func runDownload(id: UUID, service: any SplatService, entry: HistoryEntry, plyPath: String, start: Date) async {
        do {
            let file = try await download(id: id, service: service, plyPath: plyPath, startedAt: start)
            defer { Self.removeIfPresent(file) }
            guard isCurrent(id) else { return }
            let saved = try history.commit(downloadedFile: file, entry: entry,
                                           protectedFiles: immersive.protectedFiles)
            let seconds = Date().timeIntervalSince(start)
            phase = .finished(Summary(serverSeconds: 0, downloadSeconds: seconds,
                                      totalSeconds: seconds, fileSize: saved.fileSize))
            currentID = nil
            immersive.show(.localFile(history.fileURL(for: saved)))
        } catch {
            finish(id: id, error: error)
        }
    }

    private func download(id: UUID, service: any SplatService, plyPath: String, startedAt: Date) async throws -> URL {
        phase = .downloading(startedAt: startedAt, progress: TransferProgress(completedBytes: 0, totalBytes: nil))
        return try await service.downloadPLY(plyPath: plyPath) { [weak self] progress in
            Task { @MainActor in
                guard let self, self.isCurrent(id), case .downloading = self.phase else { return }
                self.phase = .downloading(startedAt: startedAt, progress: progress)
            }
        }
    }

    private func finish(id: UUID, error: any Error) {
        guard isCurrent(id) else { return }
        currentID = nil
        if error is CancellationError {
            phase = .cancelled
        } else {
            phase = .failed(message: error.localizedDescription)
        }
    }

    private static func removeIfPresent(_ file: URL) {
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        currentID == id && !Task.isCancelled
    }
}
