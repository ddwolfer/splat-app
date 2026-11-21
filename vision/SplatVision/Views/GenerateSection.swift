import SwiftUI

struct GenerateSection: View {
    @Environment(GenerationController.self) private var generation
    @Environment(SettingsStore.self) private var settings
    @State private var urlText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TextField("貼上圖片網址（https://…）", text: $urlText)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(generate)
                    .disabled(generation.phase.isRunning)

                if generation.phase.isRunning {
                    Button("取消", systemImage: "stop.circle", role: .cancel) {
                        generation.cancel()
                    }
                } else {
                    Button("生成", systemImage: "wand.and.stars", action: generate)
                        .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .buttonStyle(.bordered)

            Text(backendDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            PhaseView(phase: generation.phase)
        }
        .padding(.vertical, 4)
    }

    private var backendDescription: String {
        switch settings.currentConfig() {
        case .mock: "目前：Mock 模式（不連網路，回傳內建範例）"
        case let .server(url): "目前 server：\(url.absoluteString)"
        case nil: "尚未設定 server：請按右上角「設定」"
        }
    }

    private func generate() {
        generation.start(imageURLText: urlText)
    }
}

private struct PhaseView: View {
    let phase: GenerationController.Phase

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case let .generating(startedAt):
            TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
                HStack(spacing: 8) {
                    ProgressView()
                    Text("server 生成中… 已等 \(Format.seconds(context.date.timeIntervalSince(startedAt)))")
                        .monospacedDigit()
                }
            }
        case let .downloading(startedAt, progress):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
                    Text(downloadText(progress, elapsed: context.date.timeIntervalSince(startedAt)))
                        .monospacedDigit()
                }
            }
        case let .finished(summary):
            Label {
                Text(summaryText(summary))
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Label("已取消", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func downloadText(_ progress: DownloadProgress, elapsed: TimeInterval) -> String {
        var text = "下載中 "
        if let fraction = progress.fraction, let total = progress.totalBytes {
            text += "\(Int(fraction * 100))%（\(Format.bytes(progress.receivedBytes)) / \(Format.bytes(total))）"
        } else {
            text += Format.bytes(progress.receivedBytes)
        }
        return text + "・\(Format.seconds(elapsed))"
    }

    private func summaryText(_ summary: GenerationController.Summary) -> String {
        var parts: [String] = []
        if summary.serverSeconds > 0 { parts.append("server 生成 \(Format.seconds(summary.serverSeconds))") }
        parts.append("下載 \(Format.seconds(summary.downloadSeconds))")
        parts.append("總計 \(Format.seconds(summary.totalSeconds))")
        return "完成：" + parts.joined(separator: "｜") + "（\(Format.bytes(summary.fileSize))）"
    }
}
