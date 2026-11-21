// Render loop adapted from MetalSplatter SampleApp's VisionSceneRenderer
// (https://github.com/scier/MetalSplatter), MIT License, Copyright (c) 2026 Sean Cier.
// See vision/THIRD_PARTY_NOTICES.md.

import ARKit
import CompositorServices
import Metal
import MetalSplatter
import os
import QuartzCore
import simd
import SplatIO
import Synchronization

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

/// Renders one splat into a CompositorServices layer for the lifetime of one immersive-space session.
///
/// Threading (hence `@unchecked Sendable`):
/// - `renderThread*` state is only touched by the render task (runs on `RendererTaskExecutor`).
/// - State shared with the loading task and the UI lives in `shared` (a `Mutex`).
/// - Events go to the UI through an `AsyncStream`, so they arrive in order.
final class SplatSceneRenderer: @unchecked Sendable {
    private static let log = Logger(subsystem: "io.github.ddwolfer.SplatVision", category: "SplatSceneRenderer")
    private static let maxSimultaneousRenders = 3

    private let layerRenderer: LayerRenderer
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let colorFormat: MTLPixelFormat
    private let depthFormat: MTLPixelFormat
    private let maxViewCount: Int
    private let isLayered: Bool
    private let request: SplatRequest?
    private let events: AsyncStream<RendererEvent>.Continuation

    private let inFlightSemaphore = DispatchSemaphore(value: SplatSceneRenderer.maxSimultaneousRenders)
    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()

    private struct Shared {
        var splatRenderer: SplatRenderer?
        var loadTask: Task<Void, Never>?
        var recenterRequested = false
        var isShutDown = false
    }
    private let shared = Mutex(Shared())

    // Render-thread-only state.
    private var renderThreadTrackingRunning = false
    private var renderThreadHeadResolver = HeadPoseResolver()
    private var renderThreadPlacement = PlacementController()
    private var renderThreadReportedStatus: HeadPoseResolver.Status?

    private init(_ layerRenderer: LayerRenderer, request: SplatRequest?, events: AsyncStream<RendererEvent>.Continuation) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        guard let commandQueue = layerRenderer.device.makeCommandQueue() else {
            fatalError("Unable to create a Metal command queue")
        }
        self.commandQueue = commandQueue
        self.colorFormat = layerRenderer.configuration.colorFormat
        self.depthFormat = layerRenderer.configuration.depthFormat
        self.maxViewCount = layerRenderer.properties.viewCount
        self.isLayered = layerRenderer.configuration.layout == .layered
        self.request = request
        self.events = events
    }

    /// Entry point from the `CompositorLayer` closure.
    static func start(_ layerRenderer: LayerRenderer, request: SplatRequest?, appModel: AppModel) {
        let (stream, continuation) = AsyncStream.makeStream(of: RendererEvent.self)
        let renderer = SplatSceneRenderer(layerRenderer, request: request, events: continuation)

        if let requestID = request?.id {
            Task { @MainActor in
                appModel.attach(renderer, requestID: requestID)
                for await event in stream {
                    appModel.handle(event, requestID: requestID)
                }
            }
        } else {
            // Space restored without a request (should not happen): render nothing until it is closed.
            continuation.finish()
        }

        renderer.startLoading()
        renderer.startRenderLoop()
    }

    /// Called from the UI: re-anchor the scene in front of the user on the next valid head pose.
    func requestRecenter() {
        shared.withLock { $0.recenterRequested = true }
    }

    // MARK: - Loading

    private func startLoading() {
        guard let source = request?.source else { return }
        let task = Task.detached(priority: .userInitiated) { [self] in
            await self.load(source)
        }
        shared.withLock { $0.loadTask = task }
    }

    private func load(_ source: SplatSource) async {
        events.yield(.loading)
        let start = Date()
        do {
            let url = try source.resolveURL()
            let points = try await SplatLoader.loadPoints(from: url)
            try Task.checkCancellation()

            let splatRenderer = try SplatRenderer(device: device,
                                                  colorFormat: colorFormat,
                                                  depthFormat: depthFormat,
                                                  sampleCount: 1,
                                                  maxViewCount: maxViewCount,
                                                  maxSimultaneousRenders: Self.maxSimultaneousRenders)
            let chunk = try SplatChunk(device: device, from: points)
            await splatRenderer.addChunk(chunk)

            // Publish only if the session is still alive. Otherwise release the chunks right away:
            // MetalSplatter's sorter loop keeps itself and its buffers alive while it has chunks.
            let published = shared.withLock { state -> Bool in
                guard !state.isShutDown, !Task.isCancelled else { return false }
                state.splatRenderer = splatRenderer
                return true
            }
            guard published else {
                await splatRenderer.removeAllChunks()
                return
            }
            events.yield(.loaded(splatCount: points.count, seconds: Date().timeIntervalSince(start)))
        } catch is CancellationError {
            // Session closed while loading; nothing to report.
        } catch {
            Self.log.error("Loading splat failed: \(error.localizedDescription, privacy: .public)")
            events.yield(.failed(message: error.localizedDescription))
        }
    }

    // MARK: - Render loop

    private func startRenderLoop() {
        Task(executorPreference: RendererTaskExecutor.shared) { [self] in
            await self.startTracking()
            self.renderLoop()
            await self.shutdown()
        }
    }

    private func startTracking() async {
        guard WorldTrackingProvider.isSupported else {
            renderThreadHeadResolver.markTrackingUnavailable(reason: "此裝置不支援頭部追蹤")
            return
        }
        do {
            try await arSession.run([worldTracking])
            renderThreadTrackingRunning = true
        } catch {
            Self.log.error("ARKitSession.run failed: \(error.localizedDescription, privacy: .public)")
            renderThreadHeadResolver.markTrackingUnavailable(reason: "頭部追蹤啟動失敗：\(error.localizedDescription)")
        }
    }

    private func renderLoop() {
        while true {
            switch layerRenderer.state {
            case .invalidated:
                return
            case .paused:
                layerRenderer.waitUntilRunning()
            default:
                autoreleasepool { renderFrame() }
            }
        }
    }

    private func shutdown() async {
        arSession.stop()
        let (loadTask, splatRenderer) = shared.withLock { state -> (Task<Void, Never>?, SplatRenderer?) in
            state.isShutDown = true
            defer {
                state.loadTask = nil
                state.splatRenderer = nil
            }
            return (state.loadTask, state.splatRenderer)
        }
        loadTask?.cancel()
        // Stop MetalSplatter's background sort loop and free its buffers (it only exits when empty).
        await splatRenderer?.removeAllChunks()
        events.yield(.closed)
        events.finish()
    }

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        let drawables = frame.queryDrawables()
        guard let primaryDrawable = drawables.first else { return }

        // Head pose for this frame: real tracking if available, otherwise a simulated head that is
        // used for BOTH the camera and the placement.
        let presentationTime = LayerRenderer.Clock.Instant.epoch
            .duration(to: primaryDrawable.frameTiming.presentationTime).timeInterval
        let deviceAnchor = renderThreadTrackingRunning
            ? worldTracking.queryDeviceAnchor(atTimestamp: presentationTime)
            : nil
        let trackedHead = (deviceAnchor?.isTracked ?? false) ? deviceAnchor?.originFromAnchorTransform : nil
        let pose = renderThreadHeadResolver.resolve(trackedHead: trackedHead, now: CACurrentMediaTime())
        reportTrackingStatusIfChanged()

        let recenter = shared.withLock { state -> Bool in
            defer { state.recenterRequested = false }
            return state.recenterRequested
        }
        if recenter {
            renderThreadPlacement.requestRecenter()
        }
        let placement = pose.flatMap { renderThreadPlacement.update(with: $0) }
        let splatRenderer = shared.withLock { $0.splatRenderer }

        guard let pose, let placement, let splatRenderer else {
            presentCleared(frame: frame, drawables: drawables, deviceAnchor: deviceAnchor)
            return
        }

        // Take an in-flight slot BEFORE drawing, so GPU back-pressure makes us wait instead of
        // showing an empty frame. (SplatRenderer.render also waits briefly for its own capacity.)
        _ = inFlightSemaphore.wait(timeout: .distantFuture)
        frame.startSubmission()

        let model = SceneTransforms.modelMatrix(placement: placement)
        for (index, drawable) in drawables.enumerated() {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                fatalError("Failed to create command buffer")
            }
            drawable.deviceAnchor = deviceAnchor

            // Release the in-flight slot when the last drawable's work completes.
            if index == drawables.count - 1 {
                let semaphore = inFlightSemaphore
                commandBuffer.addCompletedHandler { _ in semaphore.signal() }
            }

            let viewports = drawable.views.enumerated().map { viewIndex, view in
                SplatRenderer.ViewportDescriptor(
                    viewport: view.textureMap.viewport,
                    projectionMatrix: drawable.computeProjection(viewIndex: viewIndex),
                    viewMatrix: (pose.transform * view.transform).inverse * model,
                    screenSize: SIMD2(x: Int(view.textureMap.viewport.width),
                                      y: Int(view.textureMap.viewport.height)))
            }

            let rendered: Bool
            do {
                rendered = try splatRenderer.render(viewports: viewports,
                                                    colorTexture: drawable.colorTextures[0],
                                                    colorStoreAction: .store,
                                                    depthTexture: drawable.depthTextures[0],
                                                    rasterizationRateMap: drawable.rasterizationRateMaps.first,
                                                    renderTargetArrayLength: isLayered ? drawable.views.count : 1,
                                                    to: commandBuffer)
            } catch {
                Self.log.error("Unable to render scene: \(error.localizedDescription, privacy: .public)")
                rendered = false
            }
            if !rendered {
                // Skipped (e.g. no sorted index buffer yet) or failed: never present undefined contents.
                encodeClear(drawable, into: commandBuffer)
            }

            drawable.encodePresent(commandBuffer: commandBuffer)
            commandBuffer.commit()
        }

        frame.endSubmission()
    }

    /// Completes the frame lifecycle without a splat (still loading / waiting for tracking), clearing the
    /// drawables so no stale content is shown and CompositorServices does not run out of frames.
    private func presentCleared(frame: LayerRenderer.Frame,
                                drawables: [LayerRenderer.Drawable],
                                deviceAnchor: DeviceAnchor?) {
        frame.startSubmission()
        for drawable in drawables {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                fatalError("Failed to create command buffer")
            }
            drawable.deviceAnchor = deviceAnchor
            encodeClear(drawable, into: commandBuffer)
            drawable.encodePresent(commandBuffer: commandBuffer)
            commandBuffer.commit()
        }
        frame.endSubmission()
    }

    /// Clears a drawable's colour (transparent) and depth.
    private func encodeClear(_ drawable: LayerRenderer.Drawable, into commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.colorTextures[0]
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = drawable.depthTextures[0]
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0.0  // reverse-Z, same as MetalSplatter
        pass.depthAttachment.storeAction = .store
        pass.rasterizationRateMap = drawable.rasterizationRateMaps.first
        pass.renderTargetArrayLength = isLayered ? drawable.views.count : 1
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }

    private func reportTrackingStatusIfChanged() {
        let status = renderThreadHeadResolver.status
        guard status != renderThreadReportedStatus else { return }
        renderThreadReportedStatus = status
        events.yield(.tracking(status))
    }
}
