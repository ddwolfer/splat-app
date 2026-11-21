import Foundation
import Testing
@testable import SplatVision

/// Reads the mock PLY that the "Generate mock PLY" build phase puts in the app bundle.
/// Expected values mirror `tools/make_mock_ply.py` (PROBE and the scene layout).
struct MockPLYTests {
    private static let expectedSplatCount = 18_903

    @Test func mockIsBundledAndParsesWithMetadataElementsSkipped() async throws {
        let url = try SplatSource.bundledMock.resolveURL()
        let points = try await SplatLoader.loadPoints(from: url)
        // Only `vertex` elements become splats; image_size/intrinsic/extrinsic/... are skipped.
        #expect(points.count == Self.expectedSplatCount)
    }

    @Test func probeSplatDecodesToTheValuesTheGeneratorWrote() async throws {
        let url = try SplatSource.bundledMock.resolveURL()
        let points = try await SplatLoader.loadPoints(from: url)
        let probe = try #require(points.first).decoded

        #expect(isApprox(probe.position, [0, -1, 4]))
        #expect(isApprox(probe.srgb, [0.25, 0.5, 0.75], tolerance: 1e-3))
        #expect(isApprox(probe.alpha, 0.8, tolerance: 1e-3))
        #expect(isApprox(probe.sigma, [0.05, 0.04, 0.03], tolerance: 1e-4))
    }
}
