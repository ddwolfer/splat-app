import simd

/// Pure math for placing a SHARP (ml-sharp) splat in a visionOS immersive space.
///
/// - ml-sharp PLY uses the OpenCV convention: x right, y DOWN, z FORWARD, camera at the origin, metres.
/// - visionOS (ARKit / ImmersiveSpace) is right-handed: x right, y UP, the user looks along −z.
enum SceneTransforms {
    /// Rotation of 180° about X: (x, y, z) → (x, −y, −z). It is a proper rotation (det = +1),
    /// so it can live in the model matrix without touching each Gaussian's quaternion.
    static let openCVToVisionOS = simd_float4x4(diagonal: SIMD4<Float>(1, -1, -1, 1))

    /// If the head's forward vector projected on the horizontal plane is shorter than this
    /// (looking up/down by more than ~78°), yaw is unreliable and we refuse to place.
    static let minimumHorizontalForward: Float = 0.2

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t, 1)
        return m
    }

    /// Rotation about +Y. Maps (0, 0, −1) to (−sin θ, 0, −cos θ).
    static func rotationY(_ radians: Float) -> simd_float4x4 {
        let c = cos(radians), s = sin(radians)
        return simd_float4x4(columns: (SIMD4<Float>(c, 0, -s, 0),
                                       SIMD4<Float>(0, 1, 0, 0),
                                       SIMD4<Float>(s, 0, c, 0),
                                       SIMD4<Float>(0, 0, 0, 1)))
    }

    /// Horizontal heading of a head (device) transform, or nil when looking (almost) straight up/down.
    /// The device looks along its local −Z axis.
    static func yaw(ofHead head: simd_float4x4) -> Float? {
        let forward = -SIMD3<Float>(head.columns.2.x, head.columns.2.y, head.columns.2.z)
        let horizontal = SIMD2<Float>(forward.x, forward.z)
        guard simd_length(horizontal) >= minimumHorizontalForward else { return nil }
        return atan2(-forward.x, -forward.z)
    }

    /// World transform for the SHARP camera origin: at the head position, facing the head's
    /// horizontal heading, gravity-aligned (pitch and roll are discarded).
    static func placement(fromHead head: simd_float4x4) -> simd_float4x4? {
        guard let yaw = yaw(ofHead: head) else { return nil }
        let position = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        return translation(position) * rotationY(yaw)
    }

    /// Model matrix that maps ml-sharp (OpenCV) coordinates into the immersive space.
    static func modelMatrix(placement: simd_float4x4) -> simd_float4x4 {
        placement * openCVToVisionOS
    }
}
