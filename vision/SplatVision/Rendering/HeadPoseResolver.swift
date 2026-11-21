import Foundation
import simd

/// Chooses the head pose used for BOTH the camera and the placement each frame, so the two never
/// disagree. Pure value type; the renderer feeds it the tracked device anchor (if any) and a clock.
struct HeadPoseResolver {
    enum Status: Equatable, Sendable {
        case waiting
        case tracking
        case simulated(reason: String)
    }

    struct Pose {
        enum Kind: Equatable {
            /// Tracked this frame.
            case tracked
            /// Tracking dropped; this is the last tracked pose, held so the camera does not jump.
            /// Must not be used to (re)place the scene.
            case held
            /// Fallback head when tracking is unavailable.
            case simulated
        }

        var transform: simd_float4x4
        var kind: Kind

        var isSimulated: Bool { kind == .simulated }
    }

    /// Fallback head: 1.6 m above the immersive-space origin (the floor under the user), looking along −z.
    static let simulatedHead = SceneTransforms.translation(SIMD3<Float>(0, 1.6, 0))
    static let trackingTimeout: TimeInterval = 2

    private(set) var status: Status = .waiting
    private var startTime: TimeInterval?
    private var lastTracked: simd_float4x4?
    private var unavailableReason: String?

    /// World tracking is unsupported or failed to start: go straight to the simulated head.
    mutating func markTrackingUnavailable(reason: String) {
        unavailableReason = reason
    }

    /// Returns the pose for this frame, or nil while still waiting for tracking to come up.
    mutating func resolve(trackedHead: simd_float4x4?, now: TimeInterval) -> Pose? {
        if let trackedHead {
            lastTracked = trackedHead
            status = .tracking
            return Pose(transform: trackedHead, kind: .tracked)
        }
        if let lastTracked {
            // Tracking dropped briefly mid-session: hold the last good pose for the camera only.
            return Pose(transform: lastTracked, kind: .held)
        }
        if let unavailableReason {
            status = .simulated(reason: unavailableReason)
            return Pose(transform: Self.simulatedHead, kind: .simulated)
        }
        let start = startTime ?? now
        startTime = start
        if now - start >= Self.trackingTimeout {
            status = .simulated(reason: "\(Int(Self.trackingTimeout)) 秒內沒有頭部追蹤資料")
            return Pose(transform: Self.simulatedHead, kind: .simulated)
        }
        return nil
    }
}
