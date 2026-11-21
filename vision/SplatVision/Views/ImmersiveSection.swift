import SwiftUI

struct ImmersiveSection: View {
    @Environment(ImmersiveController.self) private var immersive
    @Environment(HistoryStore.self) private var history

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button("顯示內建範例", systemImage: "cube.transparent") {
                    immersive.show(.bundledMock)
                }
                Button("重新置中", systemImage: "scope") {
                    immersive.recenter()
                }
                .disabled(immersive.state != .open)
                Button("關閉", systemImage: "xmark") {
                    immersive.close()
                }
                .disabled(immersive.state == .closed && !immersive.isTransitioning)
            }
            // Several buttons in one List row: give them their own hit areas, or one tap fires them all.
            .buttonStyle(.bordered)

            status
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = immersive.displayedSource {
                Label("顯示：\(name(of: source))", systemImage: "eye")
            } else {
                Label("未開啟", systemImage: "eye.slash")
                    .foregroundStyle(.secondary)
            }
            if immersive.isTransitioning {
                Label(immersive.pendingSource.map { "切換中 → \(name(of: $0))" } ?? "切換中…",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            loadStatus
            if let tracking = immersive.trackingStatus {
                trackingStatus(tracking)
            }
            if let error = immersive.lastOpenError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if immersive.state != .closed {
                PerformanceView(stats: immersive.renderStats)
            }
        }
        .font(.callout)
    }

    private func loadDetail(_ report: LoadReport) -> String {
        var parts = ["解析 \(Format.seconds(report.parseSeconds))", "加入 \(Format.seconds(report.addChunkSeconds))"]
        if let first = report.firstSortSeconds { parts.append("首次排序完成 \(Format.seconds(first))") }
        parts.append(report.usedFastPath ? "快速讀檔" : "SplatIO")
        var dropped: [String] = []
        if report.invalid > 0 { dropped.append("無效 \(report.invalid.formatted())") }
        if report.droppedTransparent > 0 { dropped.append("透明 \(report.droppedTransparent.formatted())") }
        if report.droppedByBudget > 0 { dropped.append("抽樣 \(report.droppedByBudget.formatted())") }
        if !dropped.isEmpty { parts.append("略過：" + dropped.joined(separator: "、")) }
        return parts.joined(separator: "｜")
    }

    /// History entries are shown by their image URL rather than the server's UUID.
    private func name(of source: SplatSource) -> String {
        if case let .localFile(url) = source, let entry = history.entry(forFile: url) {
            return entry.displayTitle
        }
        return source.displayName
    }

    @ViewBuilder
    private var loadStatus: some View {
        switch immersive.loadState {
        case .idle:
            EmptyView()
        case .loading:
            Label("讀取 splat 中…", systemImage: "hourglass")
        case let .loaded(report):
            VStack(alignment: .leading, spacing: 4) {
                Label("已載入 \(report.splatCount.formatted()) 個 splat", systemImage: "checkmark.circle")
                Text(loadDetail(report))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func trackingStatus(_ status: HeadPoseResolver.Status) -> some View {
        switch status {
        case .waiting:
            Label("等待頭部追蹤…", systemImage: "eye")
        case .tracking:
            Label("頭部追蹤中", systemImage: "eye")
        case let .simulated(reason):
            Label("使用模擬視角：\(reason)", systemImage: "eye.slash").foregroundStyle(.orange)
        }
    }
}

/// Render numbers from the renderer plus app memory, refreshed every second.
private struct PerformanceView: View {
    let stats: RenderStats?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 2) {
                if let stats {
                    Text("提交 \(stats.submittedFPS.formatted(.number.precision(.fractionLength(0)))) 幀/秒"
                         + "｜GPU 平均 \(ms(stats.gpuMillisAverage))・最大 \(ms(stats.gpuMillisMax))"
                         + "｜跳過 \(stats.skippedFrames)"
                         + (stats.lastSortMillis.map { "｜排序 \(ms($0))" } ?? ""))
                }
                Text(memoryText)
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private func ms(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " ms"
    }

    private var memoryText: String {
        let used = MemoryStats.physFootprint().map { Format.bytes(Int64($0)) } ?? "?"
        let available = MemoryStats.available()
        // os_proc_available_memory() returns 0 where it is not supported (e.g. the simulator).
        let availableText = available > 0 ? Format.bytes(Int64(available)) : "—（模擬器不提供）"
        return "記憶體 \(used)｜還可用 \(availableText)"
    }
}
