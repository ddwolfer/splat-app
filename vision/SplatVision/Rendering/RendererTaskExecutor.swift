// Adapted from MetalSplatter SampleApp (https://github.com/scier/MetalSplatter), MIT License,
// Copyright (c) 2026 Sean Cier. See vision/THIRD_PARTY_NOTICES.md.

import Foundation

/// Runs the render loop on its own high-priority serial queue, off the main thread.
final class RendererTaskExecutor: TaskExecutor {
    static let shared = RendererTaskExecutor()
    private let queue = DispatchQueue(label: "RenderThreadQueue", qos: .userInteractive)

    func enqueue(_ job: UnownedJob) {
        queue.async {
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }

    nonisolated func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}
