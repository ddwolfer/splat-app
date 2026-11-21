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
        }
        .font(.callout)
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
        case let .loaded(count, seconds):
            Label("已載入 \(count.formatted()) 個 splat（\(Format.seconds(seconds))）", systemImage: "checkmark.circle")
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
