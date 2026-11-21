import simd
import Testing
@testable import SplatVision

// Note: Swift Testing macros cannot wrap mutating calls, so each `resolve` result goes into a local first.
struct HeadPoseResolverTests {
    private let tracked = headTransform(position: [0.2, 1.7, 0.1], yaw: 0.4)

    @Test func waitsThenFallsBackAfterTimeout() throws {
        var resolver = HeadPoseResolver()
        let atStart = resolver.resolve(trackedHead: nil, now: 10)
        let beforeTimeout = resolver.resolve(trackedHead: nil, now: 11.9)
        #expect(atStart == nil)
        #expect(beforeTimeout == nil)
        #expect(resolver.status == .waiting)

        let afterTimeout = resolver.resolve(trackedHead: nil, now: 12)
        let pose = try #require(afterTimeout)
        #expect(pose.isSimulated)
        #expect(isApprox(pose.transform, HeadPoseResolver.simulatedHead))
        guard case .simulated = resolver.status else {
            Issue.record("expected simulated status, got \(resolver.status)")
            return
        }
    }

    @Test func unavailableTrackingFallsBackImmediately() throws {
        var resolver = HeadPoseResolver()
        resolver.markTrackingUnavailable(reason: "test")
        let result = resolver.resolve(trackedHead: nil, now: 0)
        let pose = try #require(result)
        #expect(pose.isSimulated)
        #expect(resolver.status == .simulated(reason: "test"))
    }

    @Test func realPoseWinsAfterFallback() throws {
        var resolver = HeadPoseResolver()
        _ = resolver.resolve(trackedHead: nil, now: 0)
        _ = resolver.resolve(trackedHead: nil, now: 5)  // simulated now
        let result = resolver.resolve(trackedHead: tracked, now: 6)
        let pose = try #require(result)
        #expect(!pose.isSimulated)
        #expect(isApprox(pose.transform, tracked))
        #expect(resolver.status == .tracking)
    }

    @Test func holdsLastTrackedPoseWhenTrackingDrops() throws {
        var resolver = HeadPoseResolver()
        _ = resolver.resolve(trackedHead: tracked, now: 0)
        let result = resolver.resolve(trackedHead: nil, now: 100)
        let pose = try #require(result)
        #expect(pose.kind == .held)
        #expect(isApprox(pose.transform, tracked))
    }

    @Test func cameraAndPlacementAgreeInSimulation() throws {
        // The scene origin (SHARP camera) must coincide with the simulated eye, not sit 1.6 m above it.
        var resolver = HeadPoseResolver()
        resolver.markTrackingUnavailable(reason: "test")
        let resolved = resolver.resolve(trackedHead: nil, now: 0)
        let pose = try #require(resolved)
        var controller = PlacementController()
        let placed = controller.update(head: pose.transform, isSimulated: pose.isSimulated)
        let placement = try #require(placed)
        let originInWorld = transformPoint(SceneTransforms.modelMatrix(placement: placement), .zero)
        let originInView = transformPoint(pose.transform.inverse, originInWorld)
        #expect(isApprox(originInView, .zero))
    }
}
