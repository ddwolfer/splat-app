import Foundation
import Observation
import SwiftUI

/// Events the immersive renderer reports back to the UI.
enum RendererEvent: Sendable {
    case loading
    case loaded(splatCount: Int, seconds: Double)
    case failed(message: String)
    case tracking(HeadPoseResolver.Status)
    case closed
}

/// Owns the immersive space. Every "show X" / "close" goes through one serialized queue where the
/// latest request replaces any not-yet-started one. A transition waits for the current splat to finish
/// loading (so two big PLY parses never overlap) and for the old renderer to report `.closed`
/// (its GPU/sorter resources released) before opening the next one. A wait that times out aborts the
/// transition with an error instead of pretending the work finished.
@MainActor
@Observable
final class ImmersiveController {
    enum State: Equatable {
        case closed, opening, open, closing
    }

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(splatCount: Int, seconds: Double)
        case failed(message: String)
    }

    private enum Command {
        case show(SplatSource)
        case close
    }

    enum MaintenanceError: LocalizedError {
        case couldNotClose

        var errorDescription: String? {
            switch self {
            case .couldNotClose: "沉浸空間沒有在時限內關閉，已取消操作"
            }
        }
    }

    enum OpenOutcome {
        case opened, userCancelled, failed
    }

    static let spaceID = "splat"
    /// Covers renderer shutdown (it waits for in-flight GPU work and releases the sorter).
    @ObservationIgnored var closeTimeout: Duration = .seconds(30)
    /// A real SHARP PLY (~63 MB, 1.18 M splats) should load well within this on device.
    @ObservationIgnored var loadSettleTimeout: Duration = .seconds(120)

    private(set) var state: State = .closed
    private(set) var loadState: LoadState = .idle
    private(set) var trackingStatus: HeadPoseResolver.Status?
    private(set) var currentRequest: SplatRequest?
    private(set) var lastOpenError: String?
    /// True while the queue is working (opening/closing/waiting for a load).
    private(set) var isTransitioning = false
    /// Shown as "切換中 → …": the queued source, or the one currently being switched to.
    private(set) var pendingSource: SplatSource?

    @ObservationIgnored private weak var renderer: SplatSceneRenderer?
    @ObservationIgnored private var rendererEverReported = false
    /// The space was dismissed but its renderer has not confirmed shutdown (resources may still be held).
    @ObservationIgnored private var resourcesPending = false
    @ObservationIgnored private var pending: Command?
    /// The source a running transition is switching to; protected from deletion until it is
    /// opened, fails, or is superseded.
    @ObservationIgnored private var activeTarget: SplatSource?
    @ObservationIgnored private var isLocked = false
    @ObservationIgnored private var openSpace: (@MainActor (SplatRequest) async -> OpenOutcome)?
    @ObservationIgnored private var dismissSpace: (@MainActor () async -> Void)?

    /// The source currently displayed or being loaded (nil when closed).
    var displayedSource: SplatSource? {
        state == .closed ? nil : currentRequest?.source
    }

    /// File URLs that must not be deleted right now: displayed/loading, being switched to, or queued.
    var protectedFiles: Set<URL> {
        var files = Set<URL>()
        for source in [displayedSource, activeTarget, pendingSource] {
            if case let .localFile(url)? = source { files.insert(url.standardizedFileURL) }
        }
        return files
    }

    func configure(open: OpenImmersiveSpaceAction, dismiss: DismissImmersiveSpaceAction) {
        configure(open: { request in
            switch await open(id: Self.spaceID, value: request) {
            case .opened: .opened
            case .userCancelled: .userCancelled
            case .error: .failed
            @unknown default: .failed
            }
        }, dismiss: {
            await dismiss()
        })
    }

    /// Injection point (tests use fakes that also play the renderer's events).
    func configure(open: @escaping @MainActor (SplatRequest) async -> OpenOutcome,
                   dismiss: @escaping @MainActor () async -> Void) {
        openSpace = open
        dismissSpace = dismiss
    }

    func show(_ source: SplatSource) {
        guard !isLocked else {
            lastOpenError = "正在清除歷史，請稍後再試"
            return
        }
        enqueue(.show(source))
    }

    func close() {
        enqueue(.close)
    }

    func recenter() {
        renderer?.requestRecenter()
    }

    /// Closes the space, blocks new `show` requests, and runs `work` only if the space really closed.
    func closeForMaintenance(_ work: () throws -> Void) async -> Result<Void, any Error> {
        isLocked = true
        defer { isLocked = false }
        enqueue(.close)
        let closed = await waitUntil(timeout: closeTimeout + loadSettleTimeout) {
            !self.isTransitioning && self.state == .closed && !self.resourcesPending
        }
        guard closed else { return .failure(MaintenanceError.couldNotClose) }
        return Result { try work() }
    }

    // MARK: - Renderer callbacks

    func attach(_ renderer: SplatSceneRenderer, requestID: UUID) {
        guard requestID == currentRequest?.id else { return }
        self.renderer = renderer
        rendererEverReported = true
    }

    func handle(_ event: RendererEvent, requestID: UUID) {
        guard requestID == currentRequest?.id else { return }
        rendererEverReported = true
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
            state = .closed
            resourcesPending = false
            renderer = nil
            if loadState == .loading { loadState = .idle }
        }
    }

    // MARK: - Queue

    private func enqueue(_ command: Command) {
        pending = command
        if case let .show(source) = command { pendingSource = source } else { pendingSource = nil }
        guard !isTransitioning else { return }
        isTransitioning = true
        Task { await drain() }
    }

    private func drain() async {
        defer {
            isTransitioning = false
            pendingSource = nil
            activeTarget = nil
        }
        while let command = pending {
            if case let .show(source) = command { activeTarget = source }

            // Let the current splat finish loading first: MetalSplatter's PLY parse cannot be cancelled.
            let settled = await waitUntil(timeout: loadSettleTimeout) {
                self.state == .closed || self.loadState != .loading
            }
            guard settled else {
                abortQueue("目前的場景還在讀取，請稍後再試")
                return
            }

            // Re-read after every wait: rapid taps collapse into the newest command.
            guard let next = pending else { return }
            pending = nil
            pendingSource = nil
            if case let .show(source) = next { activeTarget = source } else { activeTarget = nil }

            guard await closeCurrent() else {
                abortQueue("前一個場景的資源沒有在時限內釋放，請稍後再試")
                return
            }
            // A newer command arrived while closing: skip the stale one and loop.
            if pending != nil { continue }

            if case let .show(source) = next {
                await open(source)
            }
            activeTarget = nil
        }
    }

    private func abortQueue(_ message: String) {
        pending = nil
        lastOpenError = message
    }

    /// Returns false if the renderer did not confirm shutdown in time (also on a later attempt,
    /// until it finally does).
    private func closeCurrent() async -> Bool {
        if state != .closed {
            state = .closing
            await dismissSpace?()
            // Nothing ever started for this request (no renderer, no events): nothing to wait for.
            guard rendererEverReported else {
                state = .closed
                return true
            }
            if state != .closed { resourcesPending = true }
        }
        guard resourcesPending else { return true }
        let released = await waitUntil(timeout: closeTimeout) { !self.resourcesPending }
        if !released {
            // The space itself is dismissed; keep `resourcesPending` so nothing new opens until the
            // renderer confirms (its `.closed` event clears the flag).
            state = .closed
            renderer = nil
        }
        return released
    }

    private func open(_ source: SplatSource) async {
        guard let openSpace else { return }
        let request = SplatRequest(source: source)
        currentRequest = request
        loadState = .idle
        trackingStatus = nil
        lastOpenError = nil
        renderer = nil
        rendererEverReported = false
        state = .opening
        let result = await openSpace(request)
        guard request.id == currentRequest?.id else { return }
        switch result {
        case .opened:
            if state == .opening { state = .open }
        case .userCancelled:
            state = .closed
            lastOpenError = "已取消開啟沉浸空間"
        case .failed:
            state = .closed
            lastOpenError = "無法開啟沉浸空間"
        }
    }

    /// Polls `condition` until it holds (true) or the timeout passes (false).
    private func waitUntil(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}
