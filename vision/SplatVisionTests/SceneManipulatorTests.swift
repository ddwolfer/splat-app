import simd
import Testing
@testable import SplatVision

// Note: Swift Testing macros cannot wrap mutating calls, so `apply` runs outside `#expect`.
struct SceneManipulatorTests {
    private func active(_ id: Int, _ position: SIMD3<Float>?) -> PinchSample {
        PinchSample(id: AnyHashable(id), phase: .active, position: position)
    }

    private func ended(_ id: Int) -> PinchSample {
        PinchSample(id: AnyHashable(id), phase: .ended, position: nil)
    }

    private func cancelled(_ id: Int) -> PinchSample {
        PinchSample(id: AnyHashable(id), phase: .cancelled, position: nil)
    }

    /// Where the adjustment sends the world direction +X (scaled by the adjustment's scale).
    private func mappedXAxis(_ m: SceneManipulator) -> SIMD3<Float> {
        transformPoint(m.adjustment, [1, 0, 0]) - transformPoint(m.adjustment, .zero)
    }

    private func translation(_ m: SceneManipulator) -> SIMD3<Float> {
        transformPoint(m.adjustment, .zero)
    }

    // MARK: - One hand

    @Test func oneHandDragAmplifiesHorizontalAndKeepsVerticalOneToOne() {
        var m = SceneManipulator()
        m.apply([active(1, [0, 1, -0.5])])
        #expect(!m.isAdjusted)
        m.apply([active(1, [0.1, 0.8, -0.6])])
        #expect(isApprox(translation(m), [0.3, -0.2, -0.3]))
        #expect(isApprox(m.scale, 1))
        #expect(m.isAdjusted)
    }

    @Test func releasingKeepsTheAdjustmentAndTheNextPinchStartsFromIt() {
        var m = SceneManipulator()
        m.apply([active(1, [0, 1, -0.5])])
        m.apply([active(1, [0, 0.7, -0.5])])
        m.apply([ended(1)])
        #expect(isApprox(translation(m), [0, -0.3, 0]))

        // A new pinch somewhere else: no jump on its first sample, then relative motion.
        m.apply([active(2, [0.5, 1.4, -0.2])])
        #expect(isApprox(translation(m), [0, -0.3, 0]))
        m.apply([active(2, [0.5, 1.3, -0.2])])
        #expect(isApprox(translation(m), [0, -0.4, 0]))
    }

    @Test func endWithoutPoseStillRemovesTheHand() {
        var m = SceneManipulator()
        m.apply([active(1, [0, 1, -0.5])])
        m.apply([cancelled(1)])
        // If hand 1 were still counted, this would become a two-hand gesture (no 3x gain).
        m.apply([active(2, [0, 1, -0.5])])
        m.apply([active(2, [0.1, 1, -0.5])])
        #expect(isApprox(translation(m), [0.3, 0, 0]))
    }

    @Test func activeSampleWithoutPoseIsSkipped() {
        var m = SceneManipulator()
        m.apply([active(1, nil)])
        m.apply([active(1, [0, 1, -0.5])])  // first sample with a pose: starts the gesture here
        m.apply([active(1, [0, 1.1, -0.5])])
        #expect(isApprox(translation(m), [0, 0.1, 0]))
    }

    // MARK: - Two hands

    @Test func aHandLosingItsPoseFreezesInsteadOfScaling() {
        var m = SceneManipulator()
        m.apply([active(1, [-0.2, 1, -0.5]), active(2, [0.2, 1, -0.5])])
        // Both hands move right, but hand 1 has no pose this time: must not read as a spread (x1.25).
        m.apply([active(1, nil), active(2, [0.3, 1, -0.5])])
        #expect(!m.isAdjusted)
        // Hand 1 comes back: it rejoins from where it is, without a jump.
        m.apply([active(1, [-0.1, 1, -0.5]), active(2, [0.3, 1, -0.5])])
        #expect(!m.isAdjusted)
        m.apply([active(1, [0, 1, -0.5]), active(2, [0.4, 1, -0.5])])
        #expect(isApprox(translation(m), [0.1, 0, 0]))
        #expect(isApprox(m.scale, 1))
    }

    @Test func secondHandJoiningAndLeavingDoesNotJump() {
        var m = SceneManipulator()
        m.apply([active(1, [-0.2, 1, -0.5])])
        m.apply([active(1, [-0.2, 0.9, -0.5])])
        let afterDrag = m.adjustment

        // Hand 1 moves again in the same batch in which hand 2 joins: that motion still counts.
        m.apply([active(1, [-0.2, 0.8, -0.5]), active(2, [0.2, 0.8, -0.5])])
        #expect(isApprox(translation(m), [0, -0.2, 0]))
        #expect(!isApprox(m.adjustment, afterDrag))

        let beforeRelease = m.adjustment
        m.apply([ended(2)])
        #expect(isApprox(m.adjustment, beforeRelease))
        m.apply([active(1, [-0.1, 0.8, -0.5])])  // back to one hand: 3x horizontal
        #expect(isApprox(translation(m), [0.3, -0.2, 0]))
    }

    @Test func twoHandTwistRotatesAboutTheMidpoint() {
        var m = SceneManipulator()
        m.apply([active(1, [-0.2, 1, -0.5]), active(2, [0.2, 1, -0.5])])
        // Turn the hand line from +X to +Z (seen from above): a rotation of -90° about +Y.
        m.apply([active(1, [0, 1, -0.7]), active(2, [0, 1, -0.3])])
        let midpoint: SIMD3<Float> = [0, 1, -0.5]
        #expect(isApprox(transformPoint(m.adjustment, midpoint), midpoint))
        #expect(isApprox(transformPoint(m.adjustment, midpoint + [1, 0, 0]), midpoint + [0, 0, 1]))
        #expect(isApprox(m.scale, 1))
    }

    @Test func twoHandSpreadScalesAboutTheMidpoint() {
        var m = SceneManipulator()
        m.apply([active(1, [-0.1, 1, -0.5]), active(2, [0.1, 1, -0.5])])
        m.apply([active(1, [-0.2, 1, -0.5]), active(2, [0.2, 1, -0.5])])
        #expect(isApprox(m.scale, 2))
        let midpoint: SIMD3<Float> = [0, 1, -0.5]
        #expect(isApprox(transformPoint(m.adjustment, midpoint), midpoint))
        #expect(isApprox(transformPoint(m.adjustment, midpoint + [0, 0, -1]), midpoint + [0, 0, -2]))
    }

    @Test func twoHandMidpointMovesTheSceneOneToOne() {
        var m = SceneManipulator()
        m.apply([active(1, [-0.2, 1, -0.5]), active(2, [0.2, 1, -0.5])])
        m.apply([active(1, [-0.1, 0.9, -0.5]), active(2, [0.3, 0.9, -0.5])])
        #expect(isApprox(translation(m), [0.1, -0.1, 0]))
    }

    @Test func totalScaleIsClamped() {
        var m = SceneManipulator()
        m.apply([active(1, [-0.1, 1, -0.5]), active(2, [0.1, 1, -0.5])])
        m.apply([active(1, [-1, 1, -0.5]), active(2, [1, 1, -0.5])])  // x10
        #expect(isApprox(m.scale, SceneManipulator.scaleRange.upperBound))
        m.apply([ended(1), ended(2)])

        // The limit applies to the total, not to each gesture.
        m.apply([active(1, [-0.5, 1, -0.5]), active(2, [0.5, 1, -0.5])])
        m.apply([active(1, [-0.06, 1, -0.5]), active(2, [0.06, 1, -0.5])])  // x0.12 → 0.48 total
        #expect(isApprox(m.scale, 0.48, tolerance: 1e-3))
        m.apply([ended(1), ended(2)])
        m.apply([active(1, [-0.5, 1, -0.5]), active(2, [0.5, 1, -0.5])])
        m.apply([active(1, [-0.03, 1, -0.5]), active(2, [0.03, 1, -0.5])])  // x0.06 → below 0.1
        #expect(isApprox(m.scale, SceneManipulator.scaleRange.lowerBound))
    }

    @Test func thirdHandIsIgnored() {
        var m = SceneManipulator()
        m.apply([active(1, [-0.2, 1, -0.5]), active(2, [0.2, 1, -0.5])])
        m.apply([active(3, [0, 1.5, -0.5])])
        m.apply([active(3, [5, 5, 5])])
        #expect(!m.isAdjusted)
    }

    @Test func rotationSurvivesADegenerateSpanAndCrossedHands() {
        var m = SceneManipulator()
        m.apply([active(1, [-0.2, 1, -0.5]), active(2, [0.2, 1, -0.5])])
        m.apply([active(1, [0, 1, -0.7]), active(2, [0, 1, -0.3])])  // -90°
        #expect(isApprox(mappedXAxis(m), [0, 0, 1]))

        // Hands stacked vertically: no horizontal line, so the rotation is frozen, not undone.
        m.apply([active(1, [0, 1.2, -0.5]), active(2, [0, 0.8, -0.5])])
        #expect(isApprox(mappedXAxis(m), [0, 0, 1]))

        // Separated again with the hands crossed relative to the start: no 180° jump.
        m.apply([active(1, [0.2, 1, -0.5]), active(2, [-0.2, 1, -0.5])])
        #expect(isApprox(mappedXAxis(m), [0, 0, 1]))

        // Rotation resumes relative to the new line.
        m.apply([active(1, [0, 1, -0.3]), active(2, [0, 1, -0.7])])  // another -90°
        #expect(isApprox(mappedXAxis(m), [-1, 0, 0]))
    }

    @Test func handsStartingStackedDoNotRotateUntilTheyHaveAHorizontalLine() {
        var m = SceneManipulator()
        m.apply([active(1, [0, 1.2, -0.5]), active(2, [0, 0.8, -0.5])])
        m.apply([active(1, [0.2, 1, -0.5]), active(2, [-0.2, 1, -0.5])])
        #expect(isApprox(mappedXAxis(m), [1, 0, 0]))
        m.apply([active(1, [0, 1, -0.3]), active(2, [0, 1, -0.7])])  // -90°
        #expect(isApprox(mappedXAxis(m), [0, 0, 1]))
    }

    @Test func handsTouchingDoNotScaleUntilTheySeparate() {
        var m = SceneManipulator()
        m.apply([active(1, [0, 1, -0.5]), active(2, [0.01, 1, -0.5])])
        m.apply([active(1, [-0.1, 1, -0.5]), active(2, [0.1, 1, -0.5])])  // would be x20 from 1 cm
        #expect(isApprox(m.scale, 1))
        m.apply([active(1, [-0.2, 1, -0.5]), active(2, [0.2, 1, -0.5])])  // x2 from where it became usable
        #expect(isApprox(m.scale, 2))
    }

    // MARK: - Reset

    @Test func resetClearsAndHandsStillHeldRestartWithoutAJump() {
        var m = SceneManipulator()
        m.apply([active(1, [0, 1, -0.5])])
        m.apply([active(1, [0, 0.5, -0.5])])
        m.reset()
        #expect(!m.isAdjusted)
        #expect(isApprox(m.adjustment, matrix_identity_float4x4))

        m.apply([active(1, [0, 0.4, -0.5])])  // same hand, still pinching
        #expect(!m.isAdjusted)
        m.apply([active(1, [0, 0.3, -0.5])])
        #expect(isApprox(translation(m), [0, -0.1, 0]))
    }
}

struct SyntheticGestureTests {
    @Test func scriptedStepsGoThroughTheManipulator() throws {
        var m = SceneManipulator()
        let batches = try #require(SyntheticGesture.batches("drag:0,-0.5,0; spread:2; twist:90"))
        for batch in batches { m.apply(batch) }
        #expect(isApprox(m.scale, 2))
        // Twist 90° (counter-clockwise from above) sends +X to -Z.
        let x = transformPoint(m.adjustment, [1, 0, 0]) - transformPoint(m.adjustment, .zero)
        #expect(isApprox(x, [0, 0, -2]))
    }

    @Test(arguments: ["", "drag:1,2", "jump:1", "twist", "drag:nan,0,0", "spread:inf", "twist:x", "drag:1,,2,3"])
    func invalidSpecsAreRejected(spec: String) {
        #expect(SyntheticGesture.batches(spec) == nil)
    }
}
