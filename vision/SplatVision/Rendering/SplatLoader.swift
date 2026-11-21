import Foundation
import SplatIO

/// Reads a splat file (.ply / .splat / .spz, chosen by file extension) into memory.
enum SplatLoader {
    static func loadPoints(from url: URL) async throws -> [SplatPoint] {
        try await AutodetectSceneReader(url).readAll()
    }

    /// Same budget rule as the fast path: over budget, drop nearly transparent splats first, then a
    /// seeded uniform sample. Returns the kept points and how many were dropped by each step.
    static func applyBudget(_ points: [SplatPoint], maxSplats: Int?) -> (points: [SplatPoint], transparent: Int, sampled: Int) {
        guard let maxSplats, points.count > maxSplats else { return (points, 0, 0) }
        let visible = points.filter { $0.opacity.asLinearFloat >= SharpPLYLoader.transparentAlpha }
        let transparent = points.count - visible.count
        guard visible.count > maxSplats else { return (visible, transparent, 0) }
        let kept = SharpPLYLoader.selectionSample(count: visible.count, keep: maxSplats).map { visible[$0] }
        return (kept, transparent, visible.count - kept.count)
    }
}

/// A splat decoded into human units, used by tests and diagnostics.
struct DecodedSplat: Equatable {
    var position: SIMD3<Float>
    /// Base (SH0) colour in sRGB, 0...1.
    var srgb: SIMD3<Float>
    /// Opacity, 0...1.
    var alpha: Float
    /// Standard deviation per axis, metres.
    var sigma: SIMD3<Float>
}

extension SplatPoint {
    var decoded: DecodedSplat {
        DecodedSplat(position: position,
                     srgb: color.asSRGBFloat,
                     alpha: opacity.asLinearFloat,
                     sigma: scale.asLinearFloat)
    }
}
