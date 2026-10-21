import Foundation
import Testing
import os

@testable import NitsCore

/// `AssSubtitleRenderer` for tests: each call on libass' queue (`AssSubtitleRenderer.perform`), given up after
/// `limit` with an issue recorded. A call that never returns (a font request `fontd` never answers) then fails the
/// test, rather than holding a thread of the run's pool while the run waits for it.
struct LibassRenderer: Sendable {
    let renderer: AssSubtitleRenderer

    static let limit = 20

    /// `nil` when libass can't set up the script, or got stuck.
    init?(script: AssScript) async {
        guard let made = await Self.run({ AssSubtitleRenderer(script: script) }), let made else { return nil }
        renderer = made
    }

    func configure(frameWidth: Int, frameHeight: Int, videoWidth: Int, videoHeight: Int, pixelAspect: Double) async {
        let renderer = renderer
        _ = await Self.run {
            renderer.configure(
                frameWidth: frameWidth, frameHeight: frameHeight, videoWidth: videoWidth, videoHeight: videoHeight,
                pixelAspect: pixelAspect)
        }
    }

    func setStyleOverride(_ override: AssSubtitleRenderer.StyleOverride?) async {
        let renderer = renderer
        _ = await Self.run { renderer.setStyleOverride(override) }
    }

    func setPlacement(scale: Double, raise: Double) async {
        let renderer = renderer
        _ = await Self.run { renderer.setPlacement(scale: scale, raise: raise) }
    }

    func addEvents(_ events: [AssScript.Event]) async {
        let renderer = renderer
        _ = await Self.run { renderer.addEvents(events) }
    }

    /// `.unchanged` when libass got stuck.
    func render(at seconds: Double) async -> AssSubtitleRenderer.Output {
        let renderer = renderer
        return await Self.run { renderer.render(at: seconds) } ?? .unchanged
    }

    /// `work` on libass' queue, or `nil` (an issue recorded) when it doesn't return within `limit` seconds.
    private static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        let result: T? = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable (T?) -> Void = { value in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            // Unstructured, so nothing waits for a call that never returns.
            Task.detached { resume(await AssSubtitleRenderer.perform(work)) }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(limit)) { resume(nil) }
        }
        if result == nil { Issue.record("libass didn't return within \(limit) s (a font request to fontd?)") }
        return result
    }
}
