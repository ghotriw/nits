import AppKit
import NitsCore
import SwiftUI
import UniformTypeIdentifiers
import os

/// Slide-over drawer presenting the current playlist, navigation controls,
/// search filter, repeat/shuffle options, and drag-and-drop management.
public struct PlaylistOverlayView: View {
    public let engine: PlayerEngine
    @Bindable public var uiState: PlayerUIState
    public var onClose: () -> Void

    @State private var isShowingAddURLAlert: Bool = false
    @State private var isShowingClearConfirmation: Bool = false
    @State private var inputURLString: String = ""
    @State private var isTargetedForDrop: Bool = false

    public init(engine: PlayerEngine, uiState: PlayerUIState, onClose: @escaping () -> Void) {
        self.engine = engine
        self.uiState = uiState
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - Header
            headerView

            Divider()
                .overlay(Color.white.opacity(0.1))

            // MARK: - Filter Bar
            filterBarView

            Divider()
                .overlay(Color.white.opacity(0.08))

            // MARK: - Body / List
            if engine.playlist.items.isEmpty {
                emptyStateView
            } else if engine.playlist.filteredItems.isEmpty {
                noMatchStateView
            } else {
                playlistListView
            }

            Divider()
                .overlay(Color.white.opacity(0.1))

            // MARK: - Footer Summary
            footerSummaryView
        }
        .frame(width: 350)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1)
        }
        .overlay {
            if isTargetedForDrop {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.1))
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 24, x: -8, y: 0)
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls: urls)
        } isTargeted: { targeted in
            isTargetedForDrop = targeted
        }
        .alert("Add Media URL", isPresented: $isShowingAddURLAlert) {
            TextField("https://...", text: $inputURLString)
            Button("Add") {
                let trimmed = inputURLString.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: trimmed), !trimmed.isEmpty {
                    Task { @MainActor in
                        await engine.playlist.appendAsync(urls: [url])
                    }
                }
                inputURLString = ""
            }
            Button("Cancel", role: .cancel) {
                inputURLString = ""
            }
        } message: {
            Text("Enter a direct streaming URL (HTTP/HTTPS, HLS, or MKV stream) to add to the playlist.")
        }
        .confirmationDialog(
            "Clear Playlist",
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Playlist", role: .destructive) {
                engine.playlist.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to remove all items from the playlist?")
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(spacing: 8) {
            Text("Playlist")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)

            if !engine.playlist.items.isEmpty {
                Text("\(engine.playlist.items.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }

            Spacer()

            // Repeat Mode Button
            Button {
                engine.playlist.cycleRepeatMode()
            } label: {
                Image(systemName: engine.playlist.repeatMode.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(
                        engine.playlist.repeatMode != .off ? Color.accentColor : Color.white.opacity(0.6)
                    )
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                engine.playlist.repeatMode != .off
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.white.opacity(0.06)
                            )
                    )
            }
            .buttonStyle(.plain)
            .help(engine.playlist.repeatMode.title)

            // Shuffle Button
            Button {
                engine.playlist.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(
                        engine.playlist.isShuffled ? Color.accentColor : Color.white.opacity(0.6)
                    )
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(
                                engine.playlist.isShuffled
                                    ? Color.accentColor.opacity(0.2)
                                    : Color.white.opacity(0.06)
                            )
                    )
            }
            .buttonStyle(.plain)
            .help(engine.playlist.isShuffled ? "Shuffle: On" : "Shuffle: Off")

            // Sort Menu
            Menu {
                ForEach(PlaylistSortOrder.allCases) { order in
                    Button(order.rawValue) {
                        engine.playlist.sort(by: order)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort Playlist")

            // Add Menu
            Menu {
                Button("Add Media Files…") {
                    let urls = MediaOpenPanel.promptForMediaFiles()
                    if !urls.isEmpty {
                        engine.playlist.append(urls: urls)
                    }
                }

                Button("Add Folder…") {
                    let folderURLs = MediaOpenPanel.promptForMediaFolders()
                    if !folderURLs.isEmpty {
                        engine.playlist.append(folderURLs: folderURLs)
                    }
                }

                Button("Add URL…") {
                    isShowingAddURLAlert = true
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.8))
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add Media to Playlist")

            // Clear Button
            Button {
                isShowingClearConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .disabled(engine.playlist.items.isEmpty)
            .help("Clear Playlist")

            // Close Button
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(6)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(Color.black.opacity(0.2))
    }

    // MARK: - Filter Bar View

    private var filterBarView: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))

            TextField(
                "Filter playlist…",
                text: Binding(
                    get: { engine.playlist.searchQuery },
                    set: { engine.playlist.searchQuery = $0 }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.white)

            if !engine.playlist.searchQuery.isEmpty {
                Text("\(engine.playlist.filteredItems.count) of \(engine.playlist.items.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))

                Button {
                    engine.playlist.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.1))
    }

    // MARK: - Playlist List View

    private var playlistListView: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(Array(engine.playlist.filteredItems.enumerated()), id: \.element.id) { index, item in
                    PlaylistRowView(
                        item: item,
                        index: index,
                        isCurrent: engine.playlist.currentItem?.id == item.id,
                        isPlaying: engine.isPlaying && engine.playlist.currentItem?.id == item.id,
                        onSelect: {
                            engine.playPlaylistItem(id: item.id)
                        },
                        onRemove: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                engine.removePlaylistItem(id: item.id)
                            }
                        }
                    )
                    .id(item.id)
                    .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .onMove { source, destination in
                    engine.playlist.move(from: source, to: destination)
                }
                .moveDisabled(!engine.playlist.searchQuery.isEmpty)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onAppear {
                scrollToActiveItem(using: proxy, animated: false)
            }
            .onChange(of: engine.playlist.currentItem?.id) { _, _ in
                scrollToActiveItem(using: proxy, animated: true)
            }
        }
    }

    private func scrollToActiveItem(using proxy: ScrollViewProxy, animated: Bool = false) {
        guard let currentID = engine.playlist.currentItem?.id else { return }
        Task { @MainActor in
            if animated {
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(currentID, anchor: .center)
                }
            } else {
                proxy.scrollTo(currentID, anchor: .center)
            }
        }
    }

    // MARK: - Empty States

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "play.square.stack")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.white.opacity(0.3))

            Text("Playlist is Empty")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))

            Text("Drag & drop media files or folders here, or click '+' to add.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Button {
                let urls = MediaOpenPanel.promptForMediaFiles()
                if !urls.isEmpty {
                    engine.playlist.append(urls: urls)
                    if let firstItem = engine.playlist.currentItem {
                        engine.load(item: firstItem)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("Add Media")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchStateView: some View {
        VStack(spacing: 10) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.3))

            Text("No Matching Items")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))

            Text("No tracks found matching \"\(engine.playlist.searchQuery)\"")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("Clear Filter") {
                engine.playlist.searchQuery = ""
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer Summary

    private var footerSummaryView: some View {
        HStack {
            let totalItems = engine.playlist.items.count
            Text("\(totalItems) \(totalItems == 1 ? "item" : "items")")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))

            Spacer()

            let totalDuration = engine.playlist.items.compactMap(\.duration).reduce(0, +)
            if totalDuration > 0 {
                Text(formatDuration(totalDuration))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.2))
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }

    // MARK: - Drag & Drop Handling

    private func handleDrop(urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        AppLog.info(.playlist, "Dropped \(urls.count) item(s) onto playlist drawer")
        let hasRemote = urls.contains { !$0.isFileURL }
        if hasRemote {
            Task { @MainActor in
                await engine.playlist.appendAsync(urls: urls)
            }
        } else {
            engine.playlist.append(urls: urls)
        }
        return true
    }
}
