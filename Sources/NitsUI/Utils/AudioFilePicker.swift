import AppKit
import NitsCore
import UniformTypeIdentifiers

/// Asks for an audio file to add to the media playing as a track (a dub, a commentary): a sheet on the key window.
@MainActor
enum AudioFilePicker {
    static func pick(_ handler: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select Audio File"
        panel.prompt = "Load"
        panel.allowedContentTypes = SidecarAudio.pickableExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        let handleSelection: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { handler(url) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handleSelection)
        } else {
            panel.begin(completionHandler: handleSelection)
        }
    }
}
