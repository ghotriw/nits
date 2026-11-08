import AppKit
import NitsCore
import SwiftUI

public struct VideoSurfaceView: NSViewRepresentable {
    public let engine: PlayerEngine
    public let onFileDrop: ((String) -> Void)?
    public let onFilesDrop: (([URL]) -> Void)?
    private var acceptsActivatingClick = false

    public init(engine: PlayerEngine, onFileDrop: @escaping (String) -> Void) {
        self.engine = engine
        self.onFileDrop = onFileDrop
        self.onFilesDrop = nil
    }

    public init(engine: PlayerEngine, onFilesDrop: @escaping ([URL]) -> Void) {
        self.engine = engine
        self.onFileDrop = nil
        self.onFilesDrop = onFilesDrop
    }

    /// Lets the click that makes the window key reach the view's gestures too (`NativeVideoHostView.acceptsActivatingClick`):
    /// a SwiftUI view's `allowsWindowActivationEvents()` does not reach into an AppKit one.
    public func acceptsActivatingClick(_ accepts: Bool) -> Self {
        var view = self
        view.acceptsActivatingClick = accepts
        return view
    }

    public func makeNSView(context: Context) -> NativeVideoHostView {
        let view = NativeVideoHostView(engine: engine)
        view.onFileDrop = onFileDrop
        view.onFilesDrop = onFilesDrop
        view.acceptsActivatingClick = acceptsActivatingClick
        return view
    }

    public func updateNSView(_ nsView: NativeVideoHostView, context: Context) {
        nsView.onFileDrop = onFileDrop
        nsView.onFilesDrop = onFilesDrop
        nsView.acceptsActivatingClick = acceptsActivatingClick
        nsView.updateMode()
    }
}
