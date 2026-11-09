import NitsCore
import SwiftUI

/// Chapters tab of the playlist panel: the loaded media's chapters with the current one marked.
/// Clicking a row seeks to its start.
struct ChapterListView: View {
    let engine: PlayerEngine

    var body: some View {
        let thumbnails = engine.thumbnailManager
        ChapterListContent(
            chapters: engine.media.chapters,
            currentIndex: engine.currentChapterIndex,
            duration: engine.media.duration,
            showsThumbnails: !thumbnails.thumbnails.isEmpty || thumbnails.isGenerating,
            thumbnail: { thumbnails.thumbnail(at: $0) },
            onSelect: { chapter in
                // Picking a chapter means "watch from here", like picking a playlist item.
                engine.seekToChapter(chapter)
                if !engine.isPlaying {
                    engine.play()
                }
            }
        )
    }
}

/// The tab's layout, apart from the engine so that a preview can fill it.
private struct ChapterListContent: View {
    let chapters: [MediaChapter]
    let currentIndex: Int?
    let duration: Double
    let showsThumbnails: Bool
    /// The preview frame nearest to a time, if one is generated.
    let thumbnail: (Double) -> ThumbnailItem?
    let onSelect: (MediaChapter) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(chapters) { chapter in
                            ChapterRowView(
                                chapter: chapter,
                                thumbnail: thumbnail(chapter.start),
                                showsThumbnail: showsThumbnails,
                                isCurrent: currentIndex == chapter.id,
                                onSelect: { onSelect(chapter) }
                            )
                            .id(chapter.id)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .onAppear {
                    scrollToCurrent(using: proxy, animated: false)
                }
                .onChange(of: currentIndex) { _, _ in
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
            let count = chapters.count
            Text(
                currentIndex.map { "Chapter \($0 + 1) of \(count)" }
                    ?? "\(count) \(count == 1 ? "chapter" : "chapters")"
            )
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.white.opacity(0.5))

            Spacer()

            if duration > 0 {
                Text(TimeParser.format(seconds: duration))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }

    private func scrollToCurrent(using proxy: ScrollViewProxy, animated: Bool) {
        guard let index = currentIndex else { return }
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

/// One chapter: preview frame (when thumbnails exist or are generating), number, title, start time and length.
private struct ChapterRowView: View {
    let chapter: MediaChapter
    let thumbnail: ThumbnailItem?
    let showsThumbnail: Bool
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

            if showsThumbnail {
                thumbnailView
            }

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

#Preview("Chapters") {
    let titles = [
        "Opening Credits", "The Bridge", nil, "Night Market", "Rooftops",
        "A Very Long Chapter Title That Does Not Fit Into the Panel", "The Chase", "Epilogue", "End Credits",
    ]
    let starts: [Double] = [0, 95, 410, 760, 1185, 1730, 2310, 3105, 3640]
    let duration: Double = 3812
    let chapters = titles.indices.map { index in
        MediaChapter(
            id: index, title: titles[index], start: starts[index],
            end: index + 1 < starts.count ? starts[index + 1] : duration)
    }
    // A plain colour per chapter stands in for its frame.
    let thumbnails = chapters.compactMap { chapter -> ThumbnailItem? in
        let (width, height) = (128, 72)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let hue = Double(chapter.id) / Double(chapters.count)
        context.setFillColor(NSColor(hue: hue, saturation: 0.45, brightness: 0.55, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage().map { ThumbnailItem(time: chapter.start, image: $0, width: width, height: height) }
    }
    SidePanelContainer(width: PlayerSidePanel.chapters.width) {
        ChapterListContent(
            chapters: chapters, currentIndex: 3, duration: duration, showsThumbnails: true,
            // Each frame stands exactly at its chapter's start, the time the list asks for.
            thumbnail: { time in thumbnails.first { $0.time == time } },
            onSelect: { _ in })
    }
    .frame(height: 520)
}

#Preview("Chapters, no thumbnails") {
    let chapters = (0..<4).map { index in
        MediaChapter(id: index, title: nil, start: Double(index) * 600, end: Double(index + 1) * 600)
    }
    SidePanelContainer(width: PlayerSidePanel.chapters.width) {
        ChapterListContent(
            chapters: chapters, currentIndex: nil, duration: 2400, showsThumbnails: false,
            thumbnail: { _ in nil }, onSelect: { _ in })
    }
    .frame(height: 320)
}
