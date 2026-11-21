import Foundation
import Metal
import MetalSplatter
import simd

/// Fast, cancellable loader for ml-sharp PLY files (binary little-endian, `vertex` first, SH0 only).
///
/// Converts straight into MetalSplatter's `EncodedSplatPoint` buffer instead of building 1.18 M
/// `SplatPoint`s, checks for cancellation between batches, validates every splat, and can cap the splat
/// count. Files outside that shape return `nil` (use SplatIO); malformed files throw.
enum SharpPLYLoader {
    static let maxHeaderLength = 64 * 1024
    static let batchSize = 65_536
    /// Largest standard deviation accepted (metres); keeps the covariance within Float16 range.
    static let maxSigma: Float = 100
    static let transparentAlpha: Float = 1.0 / 255.0

    struct Stats: Equatable, Sendable {
        var pointsInFile: Int
        var invalid: Int
        var droppedTransparent: Int
        var droppedByBudget: Int
        var kept: Int
    }

    enum LoadError: LocalizedError, Equatable {
        case corrupt(String)
        case noValidSplats

        var errorDescription: String? {
            switch self {
            case let .corrupt(detail): "PLY 檔案損壞：\(detail)"
            case .noValidSplats: "PLY 裡沒有任何有效的 splat"
            }
        }
    }

    /// Byte layout of the vertex element, from the header.
    struct VertexLayout: Equatable {
        /// Required properties in this order: x y z f_dc_0 f_dc_1 f_dc_2 opacity scale_0..2 rot_0..3.
        static let requiredNames = ["x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2", "opacity",
                                    "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
        var headerLength: Int
        var count: Int
        var stride: Int
        /// Byte offsets of `requiredNames` within one vertex record.
        var offsets: [Int]
    }

    // MARK: - Header

    /// Returns the vertex layout, `nil` if this is not a file the fast path handles (caller should use
    /// SplatIO), or throws if it claims to be a SHARP-style PLY but is malformed/truncated.
    static func parseHeader(_ data: Data) throws -> VertexLayout? {
        let prefix = data.prefix(maxHeaderLength)
        guard prefix.starts(with: Data("ply".utf8)) else { return nil }
        // Find the line that is exactly "end_header" (a comment containing the words must not end the header).
        var lineStart = prefix.startIndex
        var headerEnd: (textEnd: Data.Index, bodyStart: Data.Index)?
        while lineStart < prefix.endIndex, let newline = prefix[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = prefix[lineStart..<newline]
            if line.last == UInt8(ascii: "\r") { return nil }  // CRLF headers: leave to SplatIO
            if line.elementsEqual("end_header".utf8) {
                headerEnd = (lineStart, prefix.index(after: newline))
                break
            }
            lineStart = prefix.index(after: newline)
        }
        guard let headerEnd else {
            throw LoadError.corrupt("找不到 end_header（或 header 超過 \(maxHeaderLength / 1024) KB）")
        }
        let headerLength = headerEnd.bodyStart - data.startIndex
        guard let text = String(data: data[data.startIndex..<headerEnd.textEnd], encoding: .ascii) else {
            throw LoadError.corrupt("header 不是 ASCII")
        }

        var sawFormat = false
        var elementIndex = -1
        var vertexCount: Int?
        var stride = 0
        var offsets: [String: Int] = [:]
        var float32Names: Set<String> = []

        for rawLine in text.split(separator: "\n") {
            let parts = rawLine.split(separator: " ", omittingEmptySubsequences: true)
            guard let keyword = parts.first else { continue }
            switch keyword {
            case "ply", "comment", "obj_info":
                continue
            case "format":
                guard parts.count >= 3, parts[1] == "binary_little_endian", parts[2] == "1.0" else { return nil }
                sawFormat = true
            case "element":
                guard parts.count == 3 else { throw LoadError.corrupt("element 行格式錯誤") }
                elementIndex += 1
                if elementIndex == 0 {
                    guard parts[1] == "vertex" else { return nil }
                    guard let count = Int(parts[2]), count >= 0 else { throw LoadError.corrupt("vertex 數量不合法") }
                    vertexCount = count
                }
            case "property":
                guard elementIndex == 0 else { continue }  // only the vertex element matters
                guard parts.count == 3 else { return nil }  // list properties etc.: not SHARP
                let type = String(parts[1]), name = String(parts[2])
                guard let size = scalarSize(type) else { return nil }
                if name.hasPrefix("f_rest_") { return nil }  // higher-order SH: let SplatIO keep it
                guard offsets[name] == nil else { throw LoadError.corrupt("重複的屬性 \(name)") }
                offsets[name] = stride
                if type == "float" || type == "float32" { float32Names.insert(name) }
                stride += size
            default:
                return nil
            }
        }

        guard sawFormat, let count = vertexCount else { return nil }
        var requiredOffsets: [Int] = []
        for name in VertexLayout.requiredNames {
            guard let offset = offsets[name], float32Names.contains(name) else { return nil }
            requiredOffsets.append(offset)
        }

        // Bounds: header + count * stride must fit in the file (overflow-checked).
        let (body, overflowA) = count.multipliedReportingOverflow(by: stride)
        let (total, overflowB) = body.addingReportingOverflow(headerLength)
        guard !overflowA, !overflowB, total <= data.count else {
            throw LoadError.corrupt("檔案被截斷（宣告 \(count) 點，檔案只有 \(data.count) bytes）")
        }
        return VertexLayout(headerLength: headerLength, count: count, stride: stride, offsets: requiredOffsets)
    }

    private static func scalarSize(_ type: String) -> Int? {
        switch type {
        case "char", "int8", "uchar", "uint8": 1
        case "short", "int16", "ushort", "uint16": 2
        case "int", "int32", "uint", "uint32", "float", "float32": 4
        case "double", "float64": 8
        default: nil
        }
    }

    // MARK: - Load

    /// - Parameter maxSplats: keep at most this many splats (nil = all). Over budget: drop nearly
    ///   transparent splats first, then a seeded uniform random sample (keeps spatial coverage even).
    /// - Returns: nil when the file is not in the fast path's shape (use SplatIO instead).
    static func load(url: URL, device: MTLDevice, maxSplats: Int?) throws -> (SplatChunk, Stats)? {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard let layout = try parseHeader(data) else { return nil }
        try Task.checkCancellation()

        let count = layout.count
        let buffer = try MetalBuffer<EncodedSplatPoint>(device: device, capacity: max(count, 1))
        // 0 = invalid, 1 = valid, 2 = valid but nearly transparent.
        let flags = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(count, 1))
        defer { flags.deallocate() }
        flags.initialize(repeating: 0)

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.advanced(by: layout.headerLength) else { return }
            let output = UnsafeSendable(values: buffer.values, flags: flags.baseAddress!, base: base)
            let workers = max(1, ProcessInfo.processInfo.activeProcessorCount)
            var batchStart = 0
            while batchStart < count {
                try Task.checkCancellation()
                let batchEnd = min(count, batchStart + batchSize)
                let span = batchEnd - batchStart
                let perWorker = (span + workers - 1) / workers
                DispatchQueue.concurrentPerform(iterations: workers) { worker in
                    let start = batchStart + worker * perWorker
                    let end = min(batchEnd, start + perWorker)
                    guard start < end else { return }
                    for index in start..<end {
                        let record = output.base.advanced(by: index * layout.stride)
                        if let (splat, transparent) = encode(record, offsets: layout.offsets) {
                            output.values[index] = splat
                            output.flags[index] = transparent ? 2 : 1
                        }
                    }
                }
                batchStart = batchEnd
            }
        }
        try Task.checkCancellation()

        // Deterministic compaction (single thread).
        var stats = Stats(pointsInFile: count, invalid: 0, droppedTransparent: 0, droppedByBudget: 0, kept: 0)
        let validCount = flags.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
        stats.invalid = count - validCount
        let dropTransparent = maxSplats.map { validCount > $0 } ?? false
        var write = 0
        for index in 0..<count {
            let flag = flags[index]
            if flag == 0 { continue }
            if flag == 2, dropTransparent { stats.droppedTransparent += 1; continue }
            if write != index { buffer.values[write] = buffer.values[index] }
            write += 1
        }

        if let maxSplats, write > maxSplats {
            write = subsample(buffer.values, count: write, keep: maxSplats)
            stats.droppedByBudget = validCount - stats.droppedTransparent - write
        }
        guard write > 0 else { throw LoadError.noValidSplats }
        buffer.count = write
        stats.kept = write
        try Task.checkCancellation()
        return (SplatChunk(splats: buffer), stats)
    }

    /// Validates and encodes one vertex record; nil if it must be skipped.
    @inline(__always)
    private static func encode(_ record: UnsafeRawPointer, offsets: [Int]) -> (EncodedSplatPoint, Bool)? {
        @inline(__always) func f(_ i: Int) -> Float { record.loadUnaligned(fromByteOffset: offsets[i], as: Float.self) }
        let values = (f(0), f(1), f(2), f(3), f(4), f(5), f(6), f(7), f(8), f(9), f(10), f(11), f(12), f(13))
        let position = SIMD3<Float>(values.0, values.1, values.2)
        let sh0 = SIMD3<Float>(values.3, values.4, values.5)
        let logit = values.6
        let logScale = SIMD3<Float>(values.7, values.8, values.9)
        let quat = SIMD4<Float>(values.10, values.11, values.12, values.13)  // (w, x, y, z)

        guard finite(position), finite(sh0), logit.isFinite, finite(logScale), finite(quat),
              abs(sh0.x) < 60_000, abs(sh0.y) < 60_000, abs(sh0.z) < 60_000 else { return nil }
        let quatLength = simd_length(quat)
        guard quatLength >= 1e-6 else { return nil }
        let scale = SIMD3<Float>(Foundation.exp(logScale.x), Foundation.exp(logScale.y), Foundation.exp(logScale.z))
        guard finite(scale), scale.max() <= maxSigma else { return nil }

        let opacity = 1 / (1 + Foundation.exp(-logit))
        let rotation = simd_quatf(ix: quat.y, iy: quat.z, iz: quat.w, r: quat.x).normalized
        let splat = EncodedSplatPoint(position: position, colorSH0: sh0, opacity: opacity, scale: scale, rotation: rotation)
        return (splat, opacity < transparentAlpha)
    }

    @inline(__always)
    private static func finite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

    @inline(__always)
    private static func finite(_ v: SIMD4<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite && v.w.isFinite }

    /// Selection sampling (Knuth's Algorithm S) with a fixed seed: keeps `keep` of `count` items in
    /// their original order, compacted to the front. Returns `keep`.
    private static func subsample(_ values: UnsafeMutablePointer<EncodedSplatPoint>, count: Int, keep: Int) -> Int {
        var selected = 0
        for index in selectionSample(count: count, keep: keep) {
            values[selected] = values[index]
            selected += 1
        }
        return selected
    }

    /// Indices chosen by seeded selection sampling, ascending. Shared with the SplatIO fallback.
    static func selectionSample(count: Int, keep: Int) -> [Int] {
        var rng = SplitMix64(seed: 0x5EED_5A1A)
        var chosen: [Int] = []
        chosen.reserveCapacity(min(count, keep))
        for index in 0..<count where chosen.count < keep {
            let remaining = count - index
            let needed = keep - chosen.count
            if Int(rng.next() % UInt64(remaining)) < needed { chosen.append(index) }
        }
        return chosen
    }
}

/// Raw pointers shared with `concurrentPerform` workers; each worker writes a disjoint index range.
private struct UnsafeSendable: @unchecked Sendable {
    let values: UnsafeMutablePointer<EncodedSplatPoint>
    let flags: UnsafeMutablePointer<UInt8>
    let base: UnsafeRawPointer
}

/// Small deterministic PRNG for subsampling.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
