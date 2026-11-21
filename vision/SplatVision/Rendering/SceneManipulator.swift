import Foundation
import simd

/// One pinch update from the immersive space (a `SpatialEventCollection.Event`, reduced to what we use).
struct PinchSample: Equatable {
    enum Phase: Equatable { case active, ended, cancelled }
    var id: AnyHashable
    var phase: Phase
    /// Pinch location in immersive-space (world) coordinates, metres. Only `.active` samples need it;
    /// `.ended` / `.cancelled` remove the hand by id alone.
    var position: SIMD3<Float>?
}

/// Turns pinch gestures into a world-space adjustment for the splat scene (applied on top of the
/// head-based placement). Pure value type, owned by the main actor, fed one batch of samples per
/// spatial-event callback.
///
/// - One hand: the scene follows the hand; horizontal motion ×3 (so far content can be pushed away),
///   vertical 1:1 (precise floor alignment).
/// - Two hands: the midpoint moves the scene 1:1; turning the hand line (seen from above) turns the scene
///   about the vertical axis through the midpoint; spreading the hands scales about the midpoint.
/// - Whenever the set of hands changes, or the two-hand line becomes usable/unusable for rotation or
///   scale (hands closer than 5 cm), the current adjustment becomes the new starting point, so the scene
///   never jumps (no snap-back, no 180° flip when the hands cross).
struct SceneManipulator {
    static let horizontalGain: Float = 3
    static let verticalGain: Float = 1
    static let minimumHandSpan: Float = 0.05
    static let scaleRange: ClosedRange<Float> = 0.1...4
    static let maxHands = 2

    private(set) var adjustment = matrix_identity_float4x4

    private struct Hand {
        let id: AnyHashable
        var start: SIMD3<Float>
        var current: SIMD3<Float>
    }
    private var hands: [Hand] = []
    private var startAdjustment = matrix_identity_float4x4
    private var startUsability = Usability(rotation: false, scale: false)
    /// Last valid two-hand rotation / scale relative to the start (kept while the line is unusable).
    private var lastRotation: Float = 0
    private var lastScale: Float = 1

    private struct Usability: Equatable {
        var rotation: Bool
        var scale: Bool
    }

    /// Uniform scale of the adjustment.
    var scale: Float { Self.scale(of: adjustment) }

    var isAdjusted: Bool {
        (0..<4).contains { simd_length(adjustment[$0] - matrix_identity_float4x4[$0]) > 1e-5 }
    }

    mutating func reset() {
        self = SceneManipulator()
    }

    mutating func apply(_ samples: [PinchSample]) {
        // 1. Move the hands already taking part. A taking-part hand without a pose this time is "lost".
        var lostPose = false
        for sample in samples where sample.phase == .active {
            guard let index = hands.firstIndex(where: { $0.id == sample.id }) else { continue }
            if let position = sample.position {
                hands[index].current = position
            } else {
                lostPose = true
            }
        }
        // 2. Apply that motion with the current set of hands (before anyone joins or leaves). If a hand lost
        //    its pose, freeze instead: its stale position would read as a spread or a twist.
        if !lostPose {
            adjustment = gestureTransform() * startAdjustment
        }

        // 3. Hands joining or leaving. Ends/cancels need no position; a lost hand steps out and rejoins
        //    (from wherever it is) on its next sample with a pose.
        var membershipChanged = false
        for sample in samples {
            let index = hands.firstIndex(where: { $0.id == sample.id })
            switch sample.phase {
            case .ended, .cancelled:
                if let index {
                    hands.remove(at: index)
                    membershipChanged = true
                }
            case .active:
                if let index, sample.position == nil {
                    hands.remove(at: index)
                    membershipChanged = true
                } else if index == nil, let position = sample.position, hands.count < Self.maxHands {
                    hands.append(Hand(id: sample.id, start: position, current: position))
                    membershipChanged = true
                }
            }
        }

        // 4. Start over from here when the gesture's shape changed.
        if membershipChanged || currentUsability() != startUsability {
            rebaseline()
        }
    }

    // MARK: - Private

    private mutating func rebaseline() {
        startAdjustment = adjustment
        for index in hands.indices { hands[index].start = hands[index].current }
        startUsability = currentUsability()
        lastRotation = 0
        lastScale = 1
    }

    private func currentUsability() -> Usability {
        guard hands.count == 2 else { return Usability(rotation: false, scale: false) }
        let span = hands[1].current - hands[0].current
        return Usability(rotation: simd_length(SIMD2(span.x, span.z)) >= Self.minimumHandSpan,
                         scale: simd_length(span) >= Self.minimumHandSpan)
    }

    /// World-space transform of this gesture since the start (updates the remembered rotation/scale).
    private mutating func gestureTransform() -> simd_float4x4 {
        switch hands.count {
        case 1:
            let delta = hands[0].current - hands[0].start
            return SceneTransforms.translation([delta.x * Self.horizontalGain,
                                                delta.y * Self.verticalGain,
                                                delta.z * Self.horizontalGain])
        case 2:
            let startSpan = hands[1].start - hands[0].start
            let span = hands[1].current - hands[0].current
            let usable = currentUsability()
            if startUsability.rotation && usable.rotation {
                lastRotation = Self.signedYaw(from: SIMD2(startSpan.x, startSpan.z), to: SIMD2(span.x, span.z))
            }
            if startUsability.scale && usable.scale {
                let startScale = Self.scale(of: startAdjustment)
                let total = startScale * simd_length(span) / simd_length(startSpan)
                lastScale = min(max(total, Self.scaleRange.lowerBound), Self.scaleRange.upperBound) / startScale
            }
            let startMidpoint = (hands[0].start + hands[1].start) / 2
            let midpoint = (hands[0].current + hands[1].current) / 2
            return SceneTransforms.translation(midpoint)
                * SceneTransforms.rotationY(lastRotation)
                * SceneTransforms.uniformScale(lastScale)
                * SceneTransforms.translation(-startMidpoint)
        default:
            return matrix_identity_float4x4
        }
    }

    /// Angle θ such that `SceneTransforms.rotationY(θ)` turns horizontal direction `from` (x, z) onto `to`.
    private static func signedYaw(from: SIMD2<Float>, to: SIMD2<Float>) -> Float {
        atan2(from.y * to.x - from.x * to.y, simd_dot(from, to))
    }

    private static func scale(of m: simd_float4x4) -> Float {
        simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
    }
}

/// Scripted pinch gestures for the `-sceneGesture` launch argument (simulator screenshots; the simulator
/// cannot pinch with two hands). Steps separated by ";":
/// - `drag:dx,dy,dz` — one hand moves by (dx, dy, dz) metres (the scene moves 3x horizontally, 1x vertically)
/// - `twist:degrees` — two hands turn by that angle about +Y (seen from above, positive = counter-clockwise)
/// - `spread:factor` — two hands move apart by that factor
/// Two-hand steps pivot about `pivot` (2 m in front of a standing user at the default placement).
enum SyntheticGesture {
    static let pivot: SIMD3<Float> = [0, 1.5, -2]

    static func batches(_ spec: String) -> [[PinchSample]]? {
        var batches: [[PinchSample]] = []
        for step in spec.split(separator: ";") {
            let parts = step.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            // Every field must be a finite number (no silently skipped fields, no NaN/inf in the matrix).
            let fields = parts[1].split(separator: ",", omittingEmptySubsequences: false)
            let numbers = fields.compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }.filter(\.isFinite)
            guard numbers.count == fields.count else { return nil }
            switch (parts[0].trimmingCharacters(in: .whitespaces), numbers.count) {
            case ("drag", 3):
                let start: SIMD3<Float> = [0, 1.2, -0.5]
                batches += [[pinch(1, start)], [pinch(1, start + SIMD3(numbers[0], numbers[1], numbers[2]))], [end(1)]]
            case ("twist", 1):
                let half = SceneTransforms.rotationY(numbers[0] * .pi / 180) * SIMD4<Float>(0.2, 0, 0, 0)
                let turned = SIMD3<Float>(half.x, half.y, half.z)
                batches += [[pinch(1, pivot - [0.2, 0, 0]), pinch(2, pivot + [0.2, 0, 0])],
                            [pinch(1, pivot - turned), pinch(2, pivot + turned)],
                            [end(1), end(2)]]
            case ("spread", 1):
                batches += [[pinch(1, pivot - [0.1, 0, 0]), pinch(2, pivot + [0.1, 0, 0])],
                            [pinch(1, pivot - [0.1 * numbers[0], 0, 0]), pinch(2, pivot + [0.1 * numbers[0], 0, 0])],
                            [end(1), end(2)]]
            default:
                return nil
            }
        }
        return batches.isEmpty ? nil : batches
    }

    private static func pinch(_ id: Int, _ position: SIMD3<Float>) -> PinchSample {
        PinchSample(id: AnyHashable("synthetic-\(id)"), phase: .active, position: position)
    }

    private static func end(_ id: Int) -> PinchSample {
        PinchSample(id: AnyHashable("synthetic-\(id)"), phase: .ended, position: nil)
    }
}
