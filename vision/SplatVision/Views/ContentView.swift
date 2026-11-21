import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("Splat Vision")
                    .font(.extraLargeTitle2)
                Text("單張照片生成的 3D Gaussian Splat")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Button("顯示範例", systemImage: "cube.transparent") {
                    Task { await open(.bundledMock) }
                }
                .disabled(appModel.immersiveState != .closed)

                Button("重新置中", systemImage: "scope") {
                    appModel.recenter()
                }
                .disabled(appModel.immersiveState != .open)

                Button("關閉", systemImage: "xmark") {
                    Task { await close() }
                }
                .disabled(appModel.immersiveState != .open)
            }

            StatusView()
        }
        .padding(40)
        .task {
            // Dev/automation hook: `-autoOpenMock YES` launch argument opens the mock on start,
            // so the simulator can be screenshotted without clicking.
            if UserDefaults.standard.bool(forKey: "autoOpenMock"), appModel.immersiveState == .closed {
                await open(.bundledMock)
            }
        }
    }

    private func open(_ source: SplatSource) async {
        let request = appModel.beginRequest(for: source)
        switch await openImmersiveSpace(id: AppModel.immersiveSpaceID, value: request) {
        case .opened:
            appModel.opened(request)
        case .userCancelled:
            appModel.openFailed(request, message: "已取消開啟沉浸空間")
        case .error:
            appModel.openFailed(request, message: "無法開啟沉浸空間")
        @unknown default:
            appModel.openFailed(request, message: "無法開啟沉浸空間")
        }
    }

    private func close() async {
        appModel.immersiveState = .closing
        await dismissImmersiveSpace()
        // The renderer also reports `.closed` when its layer is invalidated; this covers the case
        // where it never started.
        if appModel.immersiveState == .closing {
            appModel.immersiveState = .closed
        }
    }
}

private struct StatusView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let request = appModel.currentRequest {
                Label(request.source.displayName, systemImage: "doc")
            }
            loadStatus
            if let tracking = appModel.trackingStatus {
                trackingStatus(tracking)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var loadStatus: some View {
        switch appModel.loadState {
        case .idle:
            EmptyView()
        case .loading:
            Label("讀取中…", systemImage: "hourglass")
        case let .loaded(count, seconds):
            Label("已載入 \(count.formatted()) 個 splat（\(seconds.formatted(.number.precision(.fractionLength(2)))) 秒）",
                  systemImage: "checkmark.circle")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
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
            Label("使用模擬視角：\(reason)", systemImage: "eye.slash")
                .foregroundStyle(.orange)
        }
    }
}
