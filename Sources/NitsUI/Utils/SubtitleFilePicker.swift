import AppKit
import NitsCore
import UniformTypeIdentifiers

/// The panel that picks a subtitle file to add to the media playing.
@MainActor
public enum SubtitleFilePicker {
    /// Runs the panel; `nil` when cancelled.
    public static func pick() -> URL? {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Subtitle File"
        openPanel.prompt = "Load"
        openPanel.allowedContentTypes = SidecarSubtitles.pickableExtensions.compactMap { UTType(filenameExtension: $0) }
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        return openPanel.runModal() == .OK ? openPanel.url : nil
    }
}
