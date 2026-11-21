import simd
import Testing
@testable import SplatVision

struct SceneTransformsTests {
    private let standingHead = headTransform(position: [0, 1.6, 0])

    @Test func openCVPointInFrontAndAboveLandsInFrontAndAboveTheUser() throws {
        // OpenCV: 4 m in front of the camera, 1 m up (y is down in OpenCV).
        let placement = try #require(SceneTransforms.placement(fromHead: standingHead))
        let world = transformPoint(SceneTransforms.modelMatrix(placement: placement), [0, -1, 4])
        #expect(isApprox(world, [0, 2.6, -4]))
    }

    @Test func openCVRightStaysRight() throws {
        let placement = try #require(SceneTransforms.placement(fromHead: standingHead))
        let world = transformPoint(SceneTransforms.modelMatrix(placement: placement), [1, 0, 4])
        #expect(isApprox(world, [1, 1.6, -4]))
    }

    @Test func cameraOriginIsAtTheHead() throws {
        let head = headTransform(position: [0.3, 1.5, -0.2], yaw: 0.7)
        let placement = try #require(SceneTransforms.placement(fromHead: head))
        let world = transformPoint(SceneTransforms.modelMatrix(placement: placement), .zero)
        #expect(isApprox(world, [0.3, 1.5, -0.2]))
    }

    @Test func turningLeftPlacesTheSceneOnTheLeft() throws {
        let head = headTransform(position: [0, 1.6, 0], yaw: .pi / 2)  // +90° about +Y = facing −x
        let placement = try #require(SceneTransforms.placement(fromHead: head))
        let world = transformPoint(SceneTransforms.modelMatrix(placement: placement), [0, 0, 4])
        #expect(isApprox(world, [-4, 1.6, 0]))
    }

    @Test(arguments: [Float(-0.6), -0.3, 0.3, 0.6])
    func pitchAndRollDoNotAffectYaw(tilt: Float) throws {
        let head = headTransform(position: [0, 1.6, 0], yaw: 0.5, pitch: tilt, roll: tilt)
        let yaw = try #require(SceneTransforms.yaw(ofHead: head))
        #expect(isApprox(yaw, 0.5))
    }

    @Test(arguments: [Float.pi / 2, -Float.pi / 2, 1.45, -1.45])
    func lookingStraightUpOrDownRefusesToPlace(pitch: Float) {
        let head = headTransform(position: [0, 1.6, 0], yaw: 0.3, pitch: pitch)
        #expect(SceneTransforms.yaw(ofHead: head) == nil)
        #expect(SceneTransforms.placement(fromHead: head) == nil)
    }

    @Test func openCVConversionIsAProperRotation() {
        #expect(isApprox(simd_determinant(SceneTransforms.openCVToVisionOS), 1))
    }
}
