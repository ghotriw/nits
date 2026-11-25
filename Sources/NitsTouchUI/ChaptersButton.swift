#if os(iOS)
    import NitsCore
    import SwiftUI

    /// Opens the chapters panel; absent when the media has no chapters to choose from.
    struct ChaptersButton: View {
        let engine: PlayerEngine
        @Binding var isOpen: Bool
        var onInteraction: () -> Void = {}

        var body: some View {
            if ChapterPanelLogic.isButtonShown(chapterCount: engine.media.chapters.count) {
                Button {
                    isOpen = true
                    onInteraction()
                } label: {
                    Image(systemName: "list.bullet").font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Chapters")
            }
        }
    }
#endif
