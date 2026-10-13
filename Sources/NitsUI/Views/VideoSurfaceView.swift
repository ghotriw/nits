import AppKit
import NitsCore
import SwiftUI

public struct VideoSurfaceView: NSViewRepresentable {
    public let engine: PlayerEngine
    public let onFileDrop: ((String) -> Void)?
    public let onFilesDrop: (([URL]) -> Void)?

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

    public func makeNSView(context: Context) -> NativeVideoHostView {
        let view = NativeVideoHostView(engine: engine)
        view.onFileDrop = onFileDrop
        view.onFilesDrop = onFilesDrop
        return view
    }

    public func updateNSView(_ nsView: NativeVideoHostView, context: Context) {
        nsView.onFileDrop = onFileDrop
        nsView.onFilesDrop = onFilesDrop
        nsView.updateMode()
    }
}
