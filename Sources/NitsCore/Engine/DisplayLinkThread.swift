import Foundation
import os

/// A dedicated thread whose run loop serves the engines' display links.
///
/// On the main run loop a tick waits behind whatever the UI is doing: SwiftUI redrawing the window synchronously
/// waits for WindowServer, panels animate, windows resize. Every such stall skipped ticks and dropped frames. Here the
/// tick runs as soon as the link fires. It touches only lock-guarded state, the Metal renderer (which has its own
/// lock) and the display layer (see `PlayerEngine.displayLayerLock`); UI state goes to the main actor.
///
/// Links are still created and configured on the main thread (`VideoHost` and `PlatformScreen` make them);
/// only their callbacks run here.
final class DisplayLinkThread: @unchecked Sendable {
    static let shared = DisplayLinkThread()

    /// The thread's run loop; add display links to it in `.default` mode.
    let runLoop: RunLoop

    private init() {
        let started = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var threadRunLoop: RunLoop?
        let thread = Thread {
            threadRunLoop = RunLoop.current
            // A run loop without input sources returns at once; the port keeps it waiting for link callbacks.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            started.signal()
            while true {
                _ = RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "com.nits.display-link"
        thread.qualityOfService = .userInteractive
        thread.start()
        // Once per process, for as long as the thread takes to start.
        started.wait()
        runLoop = threadRunLoop!
    }
}
