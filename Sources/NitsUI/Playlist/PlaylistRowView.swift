import AppKit
import NitsCore
import SwiftUI

/// Renders a single row in the playlist drawer with playback status, metadata,
/// and context menu actions (reveal in Finder, copy URL, remove).
public struct PlaylistRowView: View {
    public let item: PlaylistItem
    public let index: Int
    public let isCurrent: Bool
    public let isPlaying: Bool
    public var onSelect: () -> Void
    public var onRemove: () -> Void

    @State private var isHovered: Bool = false

    public init(
        item: PlaylistItem,
        index: Int,
        isCurrent: Bool,
        isPlaying: Bool,
        onSelect: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.item = item
        self.index = index
        self.isCurrent = isCurrent
        self.isPlaying = isPlaying
        self.onSelect = onSelect
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: 10) {
            // Index or Play/Pause Status Indicator
            ZStack {
                if isCurrent {
                    // Neutral, not accent-coloured: the panel sits over arbitrary video, and
                    // white on the dark panel is the only pairing that always reads.
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 17, alignment: .trailing)

            // Title & Subtitle / Duration
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    if let duration = item.formattedDuration {
                        Text(duration)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                    } else if item.isNetworkStream {
                        Text("Stream")
                            .font(.system(size: 10, weight: .medium))
                    } else {
                        Text(item.url.pathExtension.uppercased())
                            .font(.system(size: 10, weight: .medium))
                    }
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Remove Button on Hover
            if isHovered {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("Remove from playlist")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.white.opacity(isCurrent ? 0.15 : (isHovered ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button("Play") {
                onSelect()
            }

            if item.url.isFileURL {
                Button("Reveal in Finder") {
                    let targetURL = item.url.standardizedFileURL.resolvingSymlinksInPath()
                    NSWorkspace.shared.activateFileViewerSelecting([targetURL])
                }
            }

            Button("Copy Path / URL") {
                let pboard = NSPasteboard.general
                pboard.clearContents()
                pboard.setString(item.url.isFileURL ? item.url.path : item.url.absoluteString, forType: .string)
            }

            Divider()

            Button("Remove from Playlist", role: .destructive) {
                onRemove()
            }
        }
    }
}

#Preview("Rows") {
    let items = [
        PlaylistItem(url: URL(filePath: "/Movies/Tears of Steel (2012) 2160p HDR10.mkv"), duration: 734),
        PlaylistItem(url: URL(filePath: "/Movies/Sintel.mp4"), duration: 888),
        PlaylistItem(
            url: URL(filePath: "/Movies/A Very Long File Name of a Recording That Does Not Fit Into the Panel.mov"),
            duration: 4521),
        PlaylistItem(url: URL(filePath: "/Movies/Not Probed Yet.webm")),
        PlaylistItem(url: URL(string: "https://example.com/live/master.m3u8")!, title: "Live Stream"),
    ]
    VStack(spacing: 0) {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            PlaylistRowView(
                item: item, index: index, isCurrent: index < 2, isPlaying: index == 0, onSelect: {}, onRemove: {})
        }
    }
    .frame(width: PlayerSidePanel.playlist.width)
    .padding(.vertical, 8)
    .background(Color.black.opacity(0.85))
    .environment(\.colorScheme, .dark)
}
