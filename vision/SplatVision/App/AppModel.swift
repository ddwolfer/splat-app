import Foundation
import Observation

/// Events the immersive renderer reports back to the UI.
enum RendererEvent: Sendable {
    case loading
    case loaded(splatCount: Int, seconds: Double)
    case failed(message: String)
    case tracking(HeadPoseResolver.Status)
    case closed
}

@MainActor
@Observable
final class AppModel {
    enum ImmersiveState: Equatable {
        case closed, opening, open, closing
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(splatCount: Int, seconds: Double)
        case failed(message: String)
    }

    static let immersiveSpaceID = "splat"

    var immersiveState: ImmersiveState = .closed
    private(set) var loadState: LoadState = .idle
    private(set) var trackingStatus: HeadPoseResolver.Status?
    private(set) var currentRequest: SplatRequest?

    @ObservationIgnored private weak var renderer: SplatSceneRenderer?

    /// Starts a new session: any event from an older request id is ignored from now on.
    func beginRequest(for source: SplatSource) -> SplatRequest {
        let request = SplatRequest(source: source)
        currentRequest = request
        loadState = .idle
        trackingStatus = nil
        renderer = nil
        immersiveState = .opening
        return request
    }

    func openFailed(_ request: SplatRequest, message: String) {
        guard request.id == currentRequest?.id else { return }
        immersiveState = .closed
        loadState = .failed(message: message)
    }

    func opened(_ request: SplatRequest) {
        guard request.id == currentRequest?.id, immersiveState == .opening else { return }
        immersiveState = .open
    }

    func attach(_ renderer: SplatSceneRenderer, requestID: UUID) {
        guard requestID == currentRequest?.id else { return }
        self.renderer = renderer
    }

    func handle(_ event: RendererEvent, requestID: UUID) {
        guard requestID == currentRequest?.id else { return }
        switch event {
        case .loading:
            loadState = .loading
        case let .loaded(count, seconds):
            loadState = .loaded(splatCount: count, seconds: seconds)
        case let .failed(message):
            loadState = .failed(message: message)
        case let .tracking(status):
            trackingStatus = status
        case .closed:
            immersiveState = .closed
            renderer = nil
        }
    }

    func recenter() {
        renderer?.requestRecenter()
    }
}
