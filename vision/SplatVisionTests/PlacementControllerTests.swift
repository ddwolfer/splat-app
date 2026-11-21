import simd
import Testing
@testable import SplatVision

// Note: Swift Testing macros cannot wrap mutating calls, so each `update` result goes into a local first.
struct PlacementControllerTests {
    private let start = headTransform(position: [0, 1.6, 0])
    private let moved = headTransform(position: [0.4, 1.5, -0.3], yaw: 0.8)

    @Test func placementIsWorldLocked() throws {
        var controller = PlacementController()
        let firstResult = controller.update(head: start, isSimulated: false)
        let laterResult = controller.update(head: moved, isSimulated: false)
        let first = try #require(firstResult)
        let later = try #require(laterResult)
        #expect(isApprox(first, later))
        #expect(isApprox(first, SceneTransforms.translation([0, 1.6, 0])))
    }

    @Test func recenterUpdatesOnceOnTheNextValidPose() throws {
        var controller = PlacementController()
        controller.update(head: start, isSimulated: false)
        controller.requestRecenter()

        // A pose looking straight down cannot be used, so the old placement is kept and the request stays pending.
        let lookingDown = headTransform(position: [1, 1, 1], pitch: -.pi / 2)
        let stillOldResult = controller.update(head: lookingDown, isSimulated: false)
        let stillOld = try #require(stillOldResult)
        #expect(isApprox(stillOld, SceneTransforms.translation([0, 1.6, 0])))

        let recenteredResult = controller.update(head: moved, isSimulated: false)
        let recentered = try #require(recenteredResult)
        let expected = try #require(SceneTransforms.placement(fromHead: moved))
        #expect(isApprox(recentered, expected))

        // Only once: later head motion does not move it again.
        let afterResult = controller.update(head: start, isSimulated: false)
        let after = try #require(afterResult)
        #expect(isApprox(after, recentered))
    }

    @Test func simulatedPlacementIsReplacedByTheFirstRealPoseOnly() throws {
        var controller = PlacementController()
        let simulatedResult = controller.update(head: HeadPoseResolver.simulatedHead, isSimulated: true)
        let simulated = try #require(simulatedResult)
        #expect(controller.isProvisional)

        let realResult = controller.update(head: moved, isSimulated: false)
        let real = try #require(realResult)
        #expect(!isApprox(real, simulated))
        #expect(!controller.isProvisional)

        let laterResult = controller.update(head: start, isSimulated: false)
        let later = try #require(laterResult)
        #expect(isApprox(later, real))
    }

    @Test func heldPoseDoesNotConsumeARecenter() throws {
        var controller = PlacementController()
        controller.update(head: start, isSimulated: false)
        controller.requestRecenter()

        // Tracking dropped: the held (stale) pose must neither move the scene nor use up the request.
        let held = HeadPoseResolver.Pose(transform: moved, kind: .held)
        let duringDropResult = controller.update(with: held)
        let duringDrop = try #require(duringDropResult)
        #expect(isApprox(duringDrop, SceneTransforms.translation([0, 1.6, 0])))

        // Tracking is back at a new spot: the pending recenter happens now.
        let back = headTransform(position: [1, 1.7, 1], yaw: -0.5)
        let afterResult = controller.update(with: HeadPoseResolver.Pose(transform: back, kind: .tracked))
        let after = try #require(afterResult)
        let expected = try #require(SceneTransforms.placement(fromHead: back))
        #expect(isApprox(after, expected))
    }

    @Test func noPlacementUntilAUsablePose() {
        var controller = PlacementController()
        let lookingUp = headTransform(position: [0, 1.6, 0], pitch: .pi / 2)
        let result = controller.update(head: lookingUp, isSimulated: false)
        #expect(result == nil)
    }

    @Test func newSessionUsesTheNewPose() throws {
        var first = PlacementController()
        first.update(head: start, isSimulated: false)
        var second = PlacementController()
        let result = second.update(head: moved, isSimulated: false)
        let placement = try #require(result)
        let expected = try #require(SceneTransforms.placement(fromHead: moved))
        #expect(isApprox(placement, expected))
    }
}
