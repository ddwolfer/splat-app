#if DEBUG
import Foundation
import Metal
import MetalSplatter
import SplatIO

/// Plain values of one encoded splat, for tests comparing the fast loader with SplatIO.
struct EncodedSplatValues: Equatable {
    var position: SIMD3<Float>
    /// SH0 colour + opacity.
    var rgba: SIMD4<Float>
    /// Upper triangle of the 3D covariance: (xx, xy, xz) and (yy, yz, zz).
    var covA: SIMD3<Float>
    var covB: SIMD3<Float>
}

/// Mirror of MetalSplatter's `EncodedSplatPoint` memory layout (MTLPackedFloat3 + 4 + 3 + 3 halves = 32 bytes).
private struct RawEncodedSplat {
    var px: Float, py: Float, pz: Float
    var r: Float16, g: Float16, b: Float16, a: Float16
    var c0: Float16, c1: Float16, c2: Float16
    var c3: Float16, c4: Float16, c5: Float16
}

enum SplatDiagnostics {
    static var encodedStride: Int { MemoryLayout<EncodedSplatPoint>.stride }
    static var mirrorStride: Int { MemoryLayout<RawEncodedSplat>.stride }

    static var device: MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device") }
        return device
    }

    static func values(of chunk: SplatChunk) -> [EncodedSplatValues] {
        let raw = UnsafeRawPointer(chunk.splats.values)
        return (0..<chunk.splats.count).map { index in
            let s = raw.loadUnaligned(fromByteOffset: index * encodedStride, as: RawEncodedSplat.self)
            return EncodedSplatValues(position: SIMD3(s.px, s.py, s.pz),
                                      rgba: SIMD4(Float(s.r), Float(s.g), Float(s.b), Float(s.a)),
                                      covA: SIMD3(Float(s.c0), Float(s.c1), Float(s.c2)),
                                      covB: SIMD3(Float(s.c3), Float(s.c4), Float(s.c5)))
        }
    }

    /// The SplatIO path: SplatPoint → EncodedSplatPoint, as MetalSplatter itself does.
    static func referenceValues(url: URL) async throws -> [EncodedSplatValues] {
        let points = try await SplatLoader.loadPoints(from: url)
        let chunk = try SplatChunk(device: device, from: points)
        return values(of: chunk)
    }

    static func fastValues(url: URL, maxSplats: Int? = nil) throws -> ([EncodedSplatValues], SharpPLYLoader.Stats)? {
        guard let (chunk, stats) = try SharpPLYLoader.load(url: url, device: device, maxSplats: maxSplats) else {
            return nil
        }
        return (values(of: chunk), stats)
    }
}
#endif
