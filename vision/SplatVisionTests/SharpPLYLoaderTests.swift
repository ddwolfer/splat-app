import Foundation
import simd
import Testing
@testable import SplatVision

/// Builds small PLY files in memory for header / validation tests.
struct PLYBuilder {
    static let standard: [(String, String)] = SharpPLYLoader.VertexLayout.requiredNames.map { ("float", $0) }

    var format = "binary_little_endian 1.0"
    var properties: [(type: String, name: String)] = PLYBuilder.standard
    var declaredCount: String?
    /// One value per property, in `properties` order.
    var records: [[Double]] = []
    var elementsBeforeVertex: [String] = []
    /// Extra header lines after the vertex properties (e.g. comments).
    var extraHeaderLines: [String] = []
    var lineEnding = "\n"
    var trailer = Data()

    /// A valid SHARP-style record: position, sRGB-ish colour, opacity logit, log scale, quaternion (w,x,y,z).
    static func record(x: Double = 0, y: Double = 0, z: Double = 2, logit: Double = 2, logScale: Double = -4,
                       quat: (Double, Double, Double, Double) = (1, 0, 0, 0)) -> [Double] {
        [x, y, z, 0.5, -0.5, 1.0, logit, logScale, logScale, logScale, quat.0, quat.1, quat.2, quat.3]
    }

    func build() -> Data {
        var header = "ply\nformat \(format)\ncomment built by tests\n"
        for element in elementsBeforeVertex { header += element + "\n" }
        header += "element vertex \(declaredCount ?? String(records.count))\n"
        for property in properties { header += "property \(property.type) \(property.name)\n" }
        for line in extraHeaderLines { header += line + "\n" }
        header += "element extra 1\nproperty uchar extra\nend_header\n"
        if lineEnding != "\n" { header = header.replacingOccurrences(of: "\n", with: lineEnding) }
        var data = Data(header.utf8)
        for record in records {
            for (property, value) in zip(properties, record) {
                switch property.type {
                case "float", "float32": withUnsafeBytes(of: Float(value).bitPattern.littleEndian) { data.append(contentsOf: $0) }
                case "double", "float64": withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
                case "uchar", "uint8": data.append(UInt8(value))
                default: fatalError("unsupported test type \(property.type)")
                }
            }
        }
        data.append(7)  // the `extra` element
        data.append(trailer)
        return data
    }

    func write() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).ply")
        try build().write(to: url)
        return url
    }
}

private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float) -> Bool {
    simd_length(a - b) <= tolerance
}

private func close(_ a: EncodedSplatValues, _ b: EncodedSplatValues) -> Bool {
    // Positions are float32; colour/opacity/covariance are float16 on both sides.
    let covTolerance = max(1e-6, 2e-3 * max(abs(a.covA).max(), abs(a.covB).max()))
    return close(a.position, b.position, 1e-6)
        && simd_length(a.rgba - b.rgba) <= 2e-3
        && close(a.covA, b.covA, covTolerance)
        && close(a.covB, b.covB, covTolerance)
}

struct SharpPLYLoaderTests {
    @Test func mirrorLayoutMatchesMetalSplatter() {
        #expect(SplatDiagnostics.encodedStride == 32)
        #expect(SplatDiagnostics.mirrorStride == SplatDiagnostics.encodedStride)
    }

    @Test func fastPathMatchesSplatIOOnTheMock() async throws {
        let url = try SplatSource.bundledMock.resolveURL()
        let reference = try await SplatDiagnostics.referenceValues(url: url)
        let (fast, stats) = try #require(try SplatDiagnostics.fastValues(url: url))
        #expect(stats.kept == 18_903)
        #expect(stats.invalid == 0)
        #expect(fast.count == reference.count)
        // SplatChunk(device:from:) keeps file order; so does the fast path.
        let mismatches = zip(fast, reference).enumerated().filter { !close($0.element.0, $0.element.1) }
        #expect(mismatches.isEmpty, "first mismatch: \(String(describing: mismatches.first))")
    }

    enum UnsupportedVariant: String, CaseIterable, Sendable {
        case bigEndian, ascii, higherOrderSH, doubleX, missingRot3, vertexNotFirst

        func apply(to builder: inout PLYBuilder) {
            switch self {
            case .bigEndian: builder.format = "binary_big_endian 1.0"
            case .ascii: builder.format = "ascii 1.0"
            case .higherOrderSH: builder.properties.append(("float", "f_rest_0"))
            case .doubleX: builder.properties[0] = ("double", "x")
            case .missingRot3: builder.properties.removeLast()
            case .vertexNotFirst: builder.elementsBeforeVertex = ["element meta 0"]
            }
        }
    }

    @Test(arguments: UnsupportedVariant.allCases)
    func unsupportedLayoutsFallBackToSplatIO(variant: UnsupportedVariant) throws {
        var builder = PLYBuilder(records: [PLYBuilder.record()])
        variant.apply(to: &builder)
        if builder.properties.count < 14 { builder.records = [Array(PLYBuilder.record().prefix(13))] }
        if builder.properties.count > 14 { builder.records = [PLYBuilder.record() + [0]] }
        #expect(try SharpPLYLoader.parseHeader(builder.build()) == nil, "\(variant) should fall back")
    }

    @Test(arguments: [
        ("truncated", "10"),
        ("huge count", String(Int.max / 2)),
        ("negative count", "-1"),
    ])
    func corruptFilesThrow(name: String, declaredCount: String) {
        var builder = PLYBuilder(records: [PLYBuilder.record()])
        builder.declaredCount = declaredCount
        #expect(throws: SharpPLYLoader.LoadError.self, "\(name)") {
            try SharpPLYLoader.parseHeader(builder.build())
        }
    }

    @Test func commentMentioningEndHeaderDoesNotEndTheHeader() throws {
        var builder = PLYBuilder(records: [PLYBuilder.record(x: 0.5, y: 0.25, z: 2)])
        builder.extraHeaderLines = ["comment end_header is the last line"]
        let url = try builder.write()
        let (values, _) = try #require(try SplatDiagnostics.fastValues(url: url))
        #expect(values.first?.position == SIMD3<Float>(0.5, 0.25, 2))
    }

    @Test func crlfHeaderFallsBack() throws {
        var builder = PLYBuilder(records: [PLYBuilder.record()])
        builder.lineEnding = "\r\n"
        #expect(try SharpPLYLoader.parseHeader(builder.build()) == nil)
    }

    @Test func fallbackPathHonoursTheBudget() async throws {
        let url = try SplatSource.bundledMock.resolveURL()
        let points = try await SplatLoader.loadPoints(from: url)
        let first = SplatLoader.applyBudget(points, maxSplats: 5000)
        let second = SplatLoader.applyBudget(points, maxSplats: 5000)
        #expect(first.points.count == 5000)
        #expect(first.sampled == points.count - 5000)
        #expect(first.points.map(\.position) == second.points.map(\.position))
        #expect(SplatLoader.applyBudget(points, maxSplats: nil).points.count == points.count)
    }

    @Test func missingEndHeaderThrows() {
        let data = Data("ply\nformat binary_little_endian 1.0\nelement vertex 1\n".utf8)
        #expect(throws: SharpPLYLoader.LoadError.self) { try SharpPLYLoader.parseHeader(data) }
    }

    @Test func extraUnalignedPropertyIsSkippedCorrectly() throws {
        var builder = PLYBuilder()
        builder.properties.insert(("uchar", "flag"), at: 0)  // every float is now misaligned by 1 byte
        builder.records = [[1] + PLYBuilder.record(x: 1.25, y: -2.5, z: 3.75)]
        let url = try builder.write()
        let (values, stats) = try #require(try SplatDiagnostics.fastValues(url: url))
        #expect(stats.kept == 1)
        #expect(values.first?.position == SIMD3<Float>(1.25, -2.5, 3.75))
    }

    @Test func invalidSplatsAreSkippedAndOrderIsKept() throws {
        var builder = PLYBuilder()
        builder.records = [
            PLYBuilder.record(x: .nan),                          // head: NaN
            PLYBuilder.record(x: 1),
            PLYBuilder.record(x: 2, quat: (0, 0, 0, 0)),         // middle: zero quaternion
            PLYBuilder.record(x: 3),
            PLYBuilder.record(x: 4, logScale: 10),               // tail: σ = e^10 m, too large
        ]
        let url = try builder.write()
        let (values, stats) = try #require(try SplatDiagnostics.fastValues(url: url))
        #expect(stats.invalid == 3)
        #expect(values.map(\.position.x) == [1, 3])
    }

    @Test func allInvalidThrows() throws {
        var builder = PLYBuilder()
        builder.records = [PLYBuilder.record(x: .infinity), PLYBuilder.record(quat: (0, 0, 0, 0))]
        let url = try builder.write()
        #expect(throws: SharpPLYLoader.LoadError.noValidSplats) { try SplatDiagnostics.fastValues(url: url) }
    }

    @Test func budgetDropsTransparentFirstThenSubsamplesDeterministically() throws {
        var builder = PLYBuilder()
        builder.records = (0..<1000).map { i in
            PLYBuilder.record(x: Double(i), logit: i % 10 == 0 ? -10 : 2)  // 100 nearly transparent
        }
        let url = try builder.write()
        let (first, stats) = try #require(try SplatDiagnostics.fastValues(url: url, maxSplats: 500))
        #expect(stats.kept == 500)
        #expect(stats.droppedTransparent == 100)
        #expect(stats.droppedByBudget == 400)
        #expect(first.allSatisfy { $0.rgba.w > SharpPLYLoader.transparentAlpha })
        let xs = first.map(\.position.x)
        #expect(xs == xs.sorted())  // original order kept
        let (second, _) = try #require(try SplatDiagnostics.fastValues(url: url, maxSplats: 500))
        #expect(second.map(\.position.x) == xs)  // deterministic
    }

    @Test func noBudgetKeepsTransparentSplats() throws {
        var builder = PLYBuilder()
        builder.records = [PLYBuilder.record(x: 0, logit: -10), PLYBuilder.record(x: 1)]
        let url = try builder.write()
        let (values, stats) = try #require(try SplatDiagnostics.fastValues(url: url))
        #expect(values.count == 2)
        #expect(stats.droppedTransparent == 0)
    }

    @Test func cancellationStopsTheLoad() async throws {
        let url = try SplatSource.bundledMock.resolveURL()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SplatDiagnostics.fastValues(url: url)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}
