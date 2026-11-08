import AppKit
import NitsCore
import Observation
import SwiftUI

@Observable
@MainActor
public final class LogViewModel {
    public var entries: [LogEntry] = []
    public var filteredEntries: [LogEntry] = []

    public var selectedCategory: LogCategory? = nil {
        didSet { recomputeFiltered() }
    }
    public var minLevel: LogLevel = .debug {
        didSet { recomputeFiltered() }
    }
    public var searchText: String = "" {
        didSet { recomputeFiltered() }
    }
    public var autoScroll: Bool = true
    public var logFilePath: String = ""
    public var availableCategories: [LogCategory] = []

    private var knownCategoriesSet: Set<LogCategory> = Set(LogCategory.allBuiltin)

    private let store: LogStore
    @ObservationIgnored
    private nonisolated(unsafe) var listenerId: UUID?

    public init(store: LogStore = .shared) {
        self.store = store
        self.entries = store.snapshot()
        self.logFilePath = store.currentLogFileURL?.path ?? ""

        for entry in self.entries {
            self.knownCategoriesSet.insert(entry.category)
        }
        self.availableCategories = self.knownCategoriesSet.sorted { $0.rawValue < $1.rawValue }
        recomputeFiltered()

        self.listenerId = store.addListener { [weak self] newEntry in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.entries.append(newEntry)
                if self.entries.count > self.store.maxCapacity {
                    self.entries.removeFirst(self.entries.count - self.store.maxCapacity)
                }

                // Check if a new custom category arrived
                if self.knownCategoriesSet.insert(newEntry.category).inserted {
                    self.availableCategories = self.knownCategoriesSet.sorted { $0.rawValue < $1.rawValue }
                }

                // Incremental addition to filtered entries
                if self.matchesFilter(newEntry) {
                    self.filteredEntries.append(newEntry)
                    if self.filteredEntries.count > self.store.maxCapacity {
                        self.filteredEntries.removeFirst(self.filteredEntries.count - self.store.maxCapacity)
                    }
                }
            }
        }
    }

    deinit {
        if let id = listenerId {
            store.removeListener(id)
        }
    }

    private func matchesFilter(_ entry: LogEntry) -> Bool {
        if let selectedCategory, entry.category != selectedCategory {
            return false
        }
        if entry.level < minLevel {
            return false
        }
        if !searchText.isEmpty {
            let term = searchText.lowercased()
            let matchesMsg = entry.message.lowercased().contains(term)
            let matchesFile = entry.file.lowercased().contains(term)
            let matchesCategory = entry.category.rawValue.lowercased().contains(term)
            return matchesMsg || matchesFile || matchesCategory
        }
        return true
    }

    private func recomputeFiltered() {
        filteredEntries = entries.filter { matchesFilter($0) }
    }

    public func clear() {
        store.clear()
        entries.removeAll()
        filteredEntries.removeAll()
    }

    public func exportLogs() -> String {
        filteredEntries.map(\.plainTextFormatted).joined(separator: "\n")
    }

    public func copyToClipboard() {
        let text = exportLogs()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public func saveToFile(in window: NSWindow?) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "Nits-\(ISO8601DateFormatter().string(from: Date())).log"

        let onResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .OK, let url = savePanel.url, let text = self?.exportLogs() {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }

        if let window {
            savePanel.beginSheetModal(for: window, completionHandler: onResponse)
        } else {
            savePanel.begin(completionHandler: onResponse)
        }
    }
}

public struct LogViewerView: View {
    @State private var viewModel: LogViewModel

    public init(store: LogStore = .shared) {
        _viewModel = State(initialValue: LogViewModel(store: store))
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logList
            Divider()
            statusBar
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 12) {
            // Category filter
            Picker("Category", selection: $viewModel.selectedCategory) {
                Text("All Categories").tag(LogCategory?.none)
                ForEach(viewModel.availableCategories, id: \.self) { cat in
                    Text(cat.rawValue).tag(LogCategory?.some(cat))
                }
            }
            .frame(width: 150)

            // Min level filter
            Picker("Level", selection: $viewModel.minLevel) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.rawValue).tag(level)
                }
            }
            .frame(width: 120)

            // Search filter
            TextField("Search logs...", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

            Toggle("Auto-scroll", isOn: $viewModel.autoScroll)
                .toggleStyle(.checkbox)

            Button(action: { viewModel.copyToClipboard() }) {
                Image(systemName: "doc.on.doc")
                Text("Copy")
            }
            .help("Copy filtered logs to clipboard")

            Button(action: {
                viewModel.saveToFile(in: NSApp.keyWindow)
            }) {
                Image(systemName: "square.and.arrow.down")
                Text("Export")
            }
            .help("Export filtered logs to a file")

            Button(action: { viewModel.clear() }) {
                Image(systemName: "trash")
                Text("Clear")
            }
            .help("Clear logs buffer")
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.filteredEntries) { entry in
                        LogRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Color(NSColor.textBackgroundColor))
            // The count for a filter changed, the last entry for one added: once the log is full the count stays at
            // `maxCapacity`.
            .onChange(
                of: ScrollTrigger(count: viewModel.filteredEntries.count, lastID: viewModel.filteredEntries.last?.id)
            ) {
                if viewModel.autoScroll, let last = viewModel.filteredEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private struct ScrollTrigger: Equatable {
        var count: Int
        var lastID: UUID?
    }

    @ViewBuilder
    private var statusBar: some View {
        HStack {
            Text("Total: \(viewModel.entries.count) | Showing: \(viewModel.filteredEntries.count)")
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(.secondary)

            Spacer()

            if !viewModel.logFilePath.isEmpty {
                Text(viewModel.logFilePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.formattedTimestamp)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 85, alignment: .leading)

            Text(entry.level.rawValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(badgeColor(for: entry.level).opacity(0.15))
                .foregroundColor(badgeColor(for: entry.level))
                .cornerRadius(3)
                .frame(width: 60)

            Text("[\(entry.category.rawValue)]")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.primary)
                .frame(width: 95, alignment: .leading)

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(textColor(for: entry.level))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Text("\(entry.file):\(entry.line)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(entry.level == .error ? Color.red.opacity(0.06) : Color.clear)
    }

    private func badgeColor(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .notice: return .teal
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func textColor(for level: LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        default: return .primary
        }
    }
}
