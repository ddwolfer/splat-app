import simd

/// Decides where the SHARP camera origin is anchored in the world. Pure value type, fed one head
/// pose per frame. The placement is world-locked: once computed it does not follow the head, so the
/// user can move to see parallax. It is recomputed only when
/// - nothing has been placed yet,
/// - a recenter was requested, or
/// - the current placement came from a simulated head pose and a real tracked pose arrives.
struct PlacementController {
    private(set) var placement: simd_float4x4?
    /// True when `placement` was computed from a simulated (fallback) head pose.
    private(set) var isProvisional = false
    private var recenterRequested = false

    mutating func requestRecenter() {
        recenterRequested = true
    }

    /// Feeds this frame's resolved head pose. A `.held` pose (tracking dropped) never places or
    /// consumes a pending recenter, so the recenter waits for real tracking to come back.
    @discardableResult
    mutating func update(with pose: HeadPoseResolver.Pose) -> simd_float4x4? {
        guard pose.kind != .held else { return placement }
        return update(head: pose.transform, isSimulated: pose.isSimulated)
    }

    /// Feeds the head pose for this frame and returns the placement to render with (nil = not placed yet).
    @discardableResult
    mutating func update(head: simd_float4x4, isSimulated: Bool) -> simd_float4x4? {
        let needsPlacement = placement == nil || recenterRequested || (isProvisional && !isSimulated)
        if needsPlacement, let newPlacement = SceneTransforms.placement(fromHead: head) {
            placement = newPlacement
            isProvisional = isSimulated
            recenterRequested = false
        }
        return placement
    }
}
