import Darwin
import Foundation
import os

/// What it took to load one splat (reported once per session).
struct LoadReport: Equatable, Sendable {
    var splatCount = 0
    var pointsInFile = 0
    var invalid = 0
    var droppedTransparent = 0
    var droppedByBudget = 0
    var usedFastPath = false
    /// Reading + decoding the file into a GPU buffer.
    var parseSeconds: Double = 0
    /// `SplatRenderer.addChunk` (includes MetalSplatter's locality sort).
    var addChunkSeconds: Double = 0
    /// From load start until MetalSplatter's first depth sort finished (first drawable frame).
    var firstSortSeconds: Double?
}

/// Rendering numbers over the last ~1 s. Names say exactly what was measured.
struct RenderStats: Equatable, Sendable {
    /// Frames submitted to CompositorServices per second (not a measured display rate).
    var submittedFPS: Double = 0
    /// Splat frames fully drawn / where at least one drawable was skipped or failed (cleared instead).
    /// Counted per frame, like `submittedFPS`.
    var renderedFrames = 0
    var skippedFrames = 0
    /// GPU time of splat command buffers (gpuEndTime − gpuStartTime), milliseconds.
    var gpuMillisAverage: Double = 0
    var gpuMillisMax: Double = 0
    /// Duration of the most recent depth sort (MetalSplatter `onSortComplete`), milliseconds.
    var lastSortMillis: Double?
}

/// Accumulates per-frame numbers on the render thread / GPU completion handlers.
struct RenderStatsAccumulator {
    var windowStart: TimeInterval = 0
    var submitted = 0
    var rendered = 0
    var skipped = 0
    var gpuTotal: Double = 0
    var gpuSamples = 0
    var gpuMax: Double = 0
    var lastSortSeconds: Double?

    mutating func recordGPU(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        gpuTotal += seconds
        gpuSamples += 1
        gpuMax = max(gpuMax, seconds)
    }

    /// Returns the stats for the finished window and starts a new one, once per `interval`.
    mutating func flushIfDue(now: TimeInterval, interval: TimeInterval = 1) -> RenderStats? {
        if windowStart == 0 { windowStart = now }
        let elapsed = now - windowStart
        guard elapsed >= interval else { return nil }
        let stats = RenderStats(submittedFPS: Double(submitted) / elapsed,
                                renderedFrames: rendered,
                                skippedFrames: skipped,
                                gpuMillisAverage: gpuSamples > 0 ? gpuTotal / Double(gpuSamples) * 1000 : 0,
                                gpuMillisMax: gpuMax * 1000,
                                lastSortMillis: lastSortSeconds.map { $0 * 1000 })
        let sort = lastSortSeconds
        self = RenderStatsAccumulator(windowStart: now, lastSortSeconds: sort)
        return stats
    }
}

/// App memory, sampled on demand.
enum MemoryStats {
    /// Physical footprint (the number Xcode's memory gauge and jetsam use), bytes.
    static func physFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// How much more this process may allocate before hitting its limit, bytes.
    static func available() -> UInt64 {
        UInt64(os_proc_available_memory())
    }
}
