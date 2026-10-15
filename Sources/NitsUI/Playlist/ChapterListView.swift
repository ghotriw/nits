import NitsCore
import SwiftUI

/// Chapters tab of the playlist panel: the loaded media's chapters with the current one marked.
/// Clicking a row seeks to its start.
struct ChapterListView: View {
    let engine: PlayerEngine

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(engine.chapters) { chapter in
                            ChapterRowView(
                                chapter: chapter,
                                thumbnail: engine.thumbnailManager.thumbnail(at: chapter.start),
                                isCurrent: engine.currentChapterIndex == chapter.id,
                                onSelect: {
                                    // Picking a chapter means "watch from here", like picking a playlist item.
                                    engine.seekToChapter(chapter)
                                    if !engine.isPlaying {
                                        engine.play()
                                    }
                                }
                            )
                            .id(chapter.id)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .onAppear {
                    scrollToCurrent(using: proxy, animated: false)
                }
                .onChange(of: engine.currentChapterIndex) { _, _ in
                    scrollToCurrent(using: proxy, animated: true)
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.1))

            footerView
        }
    }

    private var footerView: some View {
        HStack {
            let count = engine.chapters.count
            Text(
                engine.currentChapterIndex.map { "Chapter \($0 + 1) of \(count)" }
                    ?? "\(count) \(count == 1 ? "chapter" : "chapters")"
            )
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.white.opacity(0.5))

            Spacer()

            if engine.duration > 0 {
                Text(TimeParser.format(seconds: engine.duration))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }

    private func scrollToCurrent(using proxy: ScrollViewProxy, animated: Bool) {
        guard let index = engine.currentChapterIndex else { return }
        Task { @MainActor in
            if animated {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            } else {
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }
}

/// One chapter: preview frame, number, title, start time and length.
private struct ChapterRowView: View {
    let chapter: MediaChapter
    let thumbnail: ThumbnailItem?
    let isCurrent: Bool
    let onSelect: () -> Void

    @State private var isHovered: Bool = false

    private static let thumbnailSize = CGSize(width: 64, height: 36)

    var body: some View {
        HStack(spacing: 10) {
            Text("\(chapter.id + 1)")
                .font(.system(size: 11, weight: isCurrent ? .semibold : .medium, design: .monospaced))
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .frame(minWidth: 17, alignment: .trailing)

            thumbnailView

            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.displayTitle)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(chapter.title == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text(TimeParser.format(seconds: chapter.start))
                    if chapter.duration > 0 {
                        Text("·")
                        Text(TimeParser.format(seconds: chapter.duration))
                    }
                }
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        // Neutral highlight like the playlist rows: white on the dark panel always reads over video.
        .background(Color.white.opacity(isCurrent ? 0.15 : (isHovered ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onSelect()
        }
        .help(chapter.displayTitle)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Group {
            if let thumbnail {
                Image(decorative: thumbnail.image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.06)
            }
        }
        .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}
