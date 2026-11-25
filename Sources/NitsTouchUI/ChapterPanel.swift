#if os(iOS)
    import NitsCore
    import SwiftUI

    /// The chapters as cards: a frame of the picture (when previews exist or are being made), the title and the start
    /// and length; the chapter playing is outlined. A tap goes to a chapter's start and plays.
    struct ChapterPanel: View {
        let engine: PlayerEngine
        /// Told of a tap: the panel's touches do not reach the controls' own timer.
        var onInteraction: () -> Void = {}
        /// Room over the first card for what the host draws on the panel's top (the sheet's handle).
        var topInset: CGFloat = 0

        var body: some View {
            let thumbnails = engine.thumbnailManager
            let showsThumbnails = !thumbnails.thumbnails.isEmpty || thumbnails.isGenerating
            let currentIndex = engine.currentChapterIndex
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(engine.media.chapters) { chapter in
                            ChapterRow(
                                chapter: chapter,
                                thumbnail: showsThumbnails ? .some(thumbnails.thumbnail(at: chapter.start)) : nil,
                                isCurrent: currentIndex == chapter.id
                            ) {
                                engine.seekToChapter(chapter)
                                if !engine.isPlaying { engine.play() }
                                onInteraction()
                            }
                            .id(chapter.id)
                        }
                    }
                }
                .contentMargins(
                    .all, EdgeInsets(top: 8 + topInset, leading: 8, bottom: 8, trailing: 8), for: .scrollContent
                )
                // After the first layout: a lazy list scrolled at once may not know the row's place yet.
                .onAppear { Task { @MainActor in scroll(to: currentIndex, using: proxy, animated: false) } }
                .onChange(of: currentIndex) { _, index in scroll(to: index, using: proxy, animated: true) }
            }
            // The cards scroll under the panel's rounded corners, not out of them.
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, .dark)
        }

        /// Brings a card into view with no anchor: the list moves as little as it takes, and not at all when the card
        /// is shown already.
        private func scroll(to index: Int?, using proxy: ScrollViewProxy, animated: Bool) {
            guard let index else { return }
            if animated {
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(index) }
            } else {
                proxy.scrollTo(index)
            }
        }
    }

    /// One card. `thumbnail` is `nil` when no previews are made at all (no slot for a frame), `.some(nil)` while this one is missing.
    private struct ChapterRow: View {
        let chapter: MediaChapter
        let thumbnail: ThumbnailItem??
        let isCurrent: Bool
        let onSelect: () -> Void

        private static let thumbnailSize = CGSize(width: 112, height: 63)

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    if let thumbnail { frame(thumbnail) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chapter.displayTitle)
                            .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                            .foregroundStyle(chapter.title == nil ? .secondary : .primary)
                            .lineLimit(1)
                        Text(ChapterPanelLogic.rowDetail(chapter))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    // Without a frame the text takes the frame's inset as its own on the left.
                    .padding(.leading, thumbnail == nil ? 6 : 0)
                    Spacer(minLength: 0)
                }
                // The same inset at the left, top and bottom, and the frame's corners (10) inside the card's (16 - 6).
                .padding(6)
                .padding(.trailing, 6)
                .frame(minHeight: 44, alignment: .leading)
                .background(Color.white.opacity(0.12), in: shape)
                .overlay { if isCurrent { shape.strokeBorder(Color.white.opacity(0.75), lineWidth: 2) } }
                .clipShape(shape)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(chapter.displayTitle)
            .accessibilityValue(ChapterPanelLogic.rowDetail(chapter))
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
        }

        @ViewBuilder
        private func frame(_ item: ThumbnailItem?) -> some View {
            Group {
                if let item {
                    Image(decorative: item.image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.06)
                }
            }
            .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    #Preview("Chapters") {
        let engine = PlayerEngine()
        ChapterPanel(engine: engine).frame(width: 360, height: 420).padding().background(.black)
    }
#endif
