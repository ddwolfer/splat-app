import simd
@testable import SplatVision

func isApprox(_ a: SIMD3<Float>, _ b: SIMD3<Float>, tolerance: Float = 1e-4) -> Bool {
    simd_length(a - b) <= tolerance
}

func isApprox(_ a: Float, _ b: Float, tolerance: Float = 1e-4) -> Bool {
    abs(a - b) <= tolerance
}

func isApprox(_ a: simd_float4x4, _ b: simd_float4x4, tolerance: Float = 1e-4) -> Bool {
    (0..<4).allSatisfy { simd_length(a[$0] - b[$0]) <= tolerance }
}

/// Applies a 4x4 transform to a point.
func transformPoint(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
    let r = m * SIMD4<Float>(p, 1)
    return SIMD3<Float>(r.x, r.y, r.z) / r.w
}

/// A head (device) transform at `position`, turned by `yaw` about +Y, then pitched by `pitch` about its own X
/// (positive pitch looks up), then rolled by `roll` about its own Z.
func headTransform(position: SIMD3<Float>, yaw: Float = 0, pitch: Float = 0, roll: Float = 0) -> simd_float4x4 {
    let rotation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        * simd_quatf(angle: pitch, axis: [1, 0, 0])
        * simd_quatf(angle: roll, axis: [0, 0, 1])
    var m = simd_float4x4(rotation)
    m.columns.3 = SIMD4<Float>(position, 1)
    return m
}
