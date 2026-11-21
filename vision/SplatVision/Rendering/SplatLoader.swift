import Foundation
import SplatIO

/// Reads a splat file (.ply / .splat / .spz, chosen by file extension) into memory.
enum SplatLoader {
    static func loadPoints(from url: URL) async throws -> [SplatPoint] {
        try await AutodetectSceneReader(url).readAll()
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
