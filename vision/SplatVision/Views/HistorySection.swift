import SwiftUI

struct HistorySection: View {
    @Environment(HistoryStore.self) private var history
    @Environment(ImmersiveController.self) private var immersive
    @Environment(GenerationController.self) private var generation
    @State private var confirmingDeleteAll = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if history.entries.isEmpty {
                Text("還沒有生成紀錄")
                    .foregroundStyle(.secondary)
            }
            ForEach(history.entries) { entry in
                let isProtected = immersive.protectedFiles.contains(history.fileURL(for: entry).standardizedFileURL)
                Button {
                    open(entry)
                } label: {
                    HistoryRow(entry: entry,
                               thumbnailURL: history.thumbnailURL(for: entry),
                               isMissing: history.missingFileIDs.contains(entry.id),
                               isDisplayed: isProtected)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    if !isProtected {
                        Button("刪除", systemImage: "trash", role: .destructive) {
                            delete(entry)
                        }
                    }
                }
            }
            if history.unindexedFileCount > 0 {
                Label("另有 \(history.unindexedFileCount) 個未列入紀錄的 splat 檔（\(Format.bytes(history.unindexedBytes))），可用「全部清除」釋放空間",
                      systemImage: "externaldrive.badge.questionmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let loadError = history.loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("歷史（\(history.entries.count) 筆，共 \(Format.bytes(history.totalBytes + history.unindexedBytes))，最多 \(HistoryStore.maxEntries) 筆）")
                Spacer()
                if !history.entries.isEmpty || history.unindexedFileCount > 0 {
                    Button("全部清除", role: .destructive) { confirmingDeleteAll = true }
                        .font(.caption)
                }
            }
        }
        .confirmationDialog("清除全部歷史？", isPresented: $confirmingDeleteAll) {
            Button("全部清除（會先關閉沉浸空間）", role: .destructive) {
                Task { await deleteAll() }
            }
        } message: {
            Text("會刪除 App 內所有已下載的 splat 檔案；server 上的檔案不受影響。")
        }
    }

    private func open(_ entry: HistoryEntry) {
        if history.missingFileIDs.contains(entry.id) {
            generation.redownload(entry)
        } else {
            immersive.show(.localFile(history.fileURL(for: entry)))
        }
    }

    private func delete(_ entry: HistoryEntry) {
        do {
            try history.delete(entry)
            errorMessage = nil
        } catch {
            errorMessage = "刪除失敗：\(error.localizedDescription)"
        }
    }

    private func deleteAll() async {
        // Blocks new "show" requests until we are done, and only deletes once the space is really closed.
        let closed = await immersive.closeForMaintenance {
            try history.deleteAll()
        }
        switch closed {
        case .success:
            errorMessage = nil
        case let .failure(error):
            errorMessage = "清除失敗：\(error.localizedDescription)"
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let thumbnailURL: URL?
    let isMissing: Bool
    let isDisplayed: Bool

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
                .frame(width: 72, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            if isDisplayed {
                Text("顯示中").font(.caption).padding(6).background(.tint.opacity(0.3), in: Capsule())
            }
            if isMissing {
                Label("檔案不存在，點一下重新下載", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .contentShape(Rectangle())
    }

    private var title: String { entry.displayTitle }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumbnailURL, let image = UIImage(contentsOfFile: thumbnailURL.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else if entry.imageURL.hasPrefix("http") {
            AsyncImage(url: URL(string: entry.imageURL)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
        } else {
            Image(systemName: "photo").foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        let origin = switch entry.origin {
        case .mock: "Mock"
        case let .server(baseURL, _): baseURL.host() ?? baseURL.absoluteString
        }
        return [entry.createdAt.formatted(date: .abbreviated, time: .shortened),
                "生成 \(Format.seconds(entry.serverSeconds))",
                "總計 \(Format.seconds(entry.totalSeconds))",
                Format.bytes(entry.fileSize),
                origin].joined(separator: "・")
    }
}

extension HistoryEntry {
    /// "host / file.jpg" from the source image URL, or "上傳：file.jpg" for uploads.
    var displayTitle: String {
        if imageURL.hasPrefix("upload:") { return "上傳：" + imageURL.dropFirst("upload:".count) }
        guard let url = URL(string: imageURL) else { return imageURL }
        let name = url.lastPathComponent
        return [url.host(), name.isEmpty || name == "/" ? nil : name].compactMap { $0 }.joined(separator: " / ")
    }
}
