/// Where playback stood when the host went to the background, for the exact seek that brings the picture back.
///
/// In the background the engine is paused, its display links are gone and its VideoToolbox session is dropped (the
/// system invalidates it anyway, and GPU work there gets an app killed); network connections die while the app is
/// suspended, and a live stream's window moves on.
struct BackgroundSnapshot: Equatable, Sendable {
    /// The picture's position (the target of a seek still on its way).
    var position: Double
    /// A live stream was at its edge: it returns to the edge as it is then, not to the position it left.
    var atLiveEdge: Bool
}
