import Foundation
import os

/// Severity levels for application logs.
public enum LogLevel: String, Sendable, Codable, CaseIterable, Comparable {
    case debug = "DEBUG"
    case info = "INFO"
    case notice = "NOTICE"
    case warning = "WARNING"
    case error = "ERROR"

    public var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .error
        case .error: return .fault
        }
    }

    private var priority: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .notice: return 2
        case .warning: return 3
        case .error: return 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.priority < rhs.priority
    }
}

/// Logging category for Nits subsystems and integrating host applications.
/// Supports both built-in player subsystems and custom application categories (e.g. Host, Emby, Network).
public struct LogCategory: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ name: String) {
        self.rawValue = name
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String {
        rawValue
    }

    // Built-in presets:
    public static let general = LogCategory("General")
    public static let engine = LogCategory("Engine")
    public static let demuxer = LogCategory("Demuxer")
    public static let audio = LogCategory("Audio")
    public static let video = LogCategory("Video")
    public static let renderer = LogCategory("Renderer")
    public static let subtitles = LogCategory("Subtitles")
    public static let ui = LogCategory("UI")
    public static let performance = LogCategory("Performance")
    /// Dedicated category for playlist management and media discovery
    public static let playlist = LogCategory("Playlist")
    /// Dedicated category for integrating host applications (such as EmbyPlayer, CLI tools, etc.)
    public static let host = LogCategory("Host")

    public static let allBuiltin: [LogCategory] = [
        .general, .engine, .demuxer, .audio, .video, .renderer, .subtitles, .ui, .performance, .playlist, .host,
    ]
}

/// A structured entry representing an isolated log message.
public struct LogEntry: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    public let file: String
    public let line: Int

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        category: LogCategory,
        message: String,
        file: String = #file,
        line: Int = #line
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.file = (file as NSString).lastPathComponent
        self.line = line
    }

    public var formattedTimestamp: String {
        timestamp.formatted(.iso8601.time(includingFractionalSeconds: true))
    }

    public var plainTextFormatted: String {
        "[\(formattedTimestamp)] [\(level.rawValue)] [\(category.rawValue)] \(message)"
    }
}

/// Thread-safe in-memory ring buffer and asynchronous file persistence for logs.
/// Strictly uses `OSAllocatedUnfairLock` per video architecture rules (no `NSLock`).
public final class LogStore: @unchecked Sendable {
    public static let shared = LogStore()

    public let maxCapacity: Int

    private struct State {
        var entries: [LogEntry] = []
        var listeners: [UUID: @Sendable (LogEntry) -> Void] = [:]
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let logFileURL: URL?
    private let ioQueue: DispatchQueue?
    private var fileHandle: FileHandle?

    public init(maxCapacity: Int = 2000, writeToDisk: Bool = true) {
        self.maxCapacity = maxCapacity
        self.lock = OSAllocatedUnfairLock(initialState: State())

        if writeToDisk {
            let queue = DispatchQueue(label: "com.nits.logger.io", qos: .utility)
            self.ioQueue = queue

            let fileManager = FileManager.default
            let logsDir: URL
            if let appSupport = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
                logsDir = appSupport.appendingPathComponent("Nits/Logs", isDirectory: true)
            } else {
                logsDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
                    "Nits/Logs", isDirectory: true)
            }

            try? fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
            let fileURL = logsDir.appendingPathComponent("player.log")
            self.logFileURL = fileURL

            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try? FileHandle(forWritingTo: fileURL)
            handle?.seekToEndOfFile()
            self.fileHandle = handle
        } else {
            self.logFileURL = nil
            self.fileHandle = nil
            self.ioQueue = nil
        }
    }

    deinit {
        ioQueue?.sync { [fileHandle] in
            try? fileHandle?.close()
        }
    }

    public func append(_ entry: LogEntry) {
        let activeListeners = lock.withLock { state -> [@Sendable (LogEntry) -> Void] in
            if state.entries.count >= maxCapacity {
                state.entries.removeFirst(state.entries.count - maxCapacity + 1)
            }
            state.entries.append(entry)
            return Array(state.listeners.values)
        }

        // Asynchronous non-blocking file I/O off the critical rendering path
        if let ioQueue, let handle = fileHandle {
            let logLine = "\(entry.plainTextFormatted)\n"
            ioQueue.async {
                if let data = logLine.data(using: .utf8) {
                    try? handle.write(contentsOf: data)
                }
            }
        }

        for listener in activeListeners {
            listener(entry)
        }
    }

    public func snapshot() -> [LogEntry] {
        lock.withLock { $0.entries }
    }

    public func clear() {
        lock.withLock { state in
            state.entries.removeAll()
        }

        if let ioQueue, let handle = fileHandle {
            ioQueue.async {
                try? handle.truncate(atOffset: 0)
                try? handle.seek(toOffset: 0)
            }
        }
    }

    @discardableResult
    public func addListener(_ listener: @escaping @Sendable (LogEntry) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { state in
            state.listeners[id] = listener
        }
        return id
    }

    public func removeListener(_ id: UUID) {
        lock.withLock { state in
            _ = state.listeners.removeValue(forKey: id)
        }
    }

    public var currentLogFileURL: URL? {
        logFileURL
    }

    public func exportFormattedText() -> String {
        snapshot().map(\.plainTextFormatted).joined(separator: "\n")
    }
}

/// Public unified logging facade for all Nits modules.
public enum AppLog {
    public static let subsystem = "com.nits.app"

    private static let thresholdLock = OSAllocatedUnfairLock(initialState: LogLevel.debug)

    /// Configurable minimum log level. Messages below this level are discarded
    /// before evaluating any @autoclosure string interpolation.
    public static var minimumLogLevel: LogLevel {
        get { thresholdLock.withLock { $0 } }
        set { thresholdLock.withLock { $0 = newValue } }
    }

    private static let loggers: [LogCategory: os.Logger] = [
        .general: os.Logger(subsystem: subsystem, category: LogCategory.general.rawValue),
        .engine: os.Logger(subsystem: subsystem, category: LogCategory.engine.rawValue),
        .demuxer: os.Logger(subsystem: subsystem, category: LogCategory.demuxer.rawValue),
        .audio: os.Logger(subsystem: subsystem, category: LogCategory.audio.rawValue),
        .video: os.Logger(subsystem: subsystem, category: LogCategory.video.rawValue),
        .renderer: os.Logger(subsystem: subsystem, category: LogCategory.renderer.rawValue),
        .subtitles: os.Logger(subsystem: subsystem, category: LogCategory.subtitles.rawValue),
        .ui: os.Logger(subsystem: subsystem, category: LogCategory.ui.rawValue),
        .performance: os.Logger(subsystem: subsystem, category: LogCategory.performance.rawValue),
        .playlist: os.Logger(subsystem: subsystem, category: LogCategory.playlist.rawValue),
        .host: os.Logger(subsystem: subsystem, category: LogCategory.host.rawValue),
    ]

    public static func log(
        _ level: LogLevel,
        category: LogCategory,
        _ message: @autoclosure () -> String,
        file: String = #file,
        line: Int = #line
    ) {
        guard level >= minimumLogLevel else { return }

        let msg = message()
        let osLog = loggers[category] ?? os.Logger(subsystem: subsystem, category: category.rawValue)
        osLog.log(level: level.osLogType, "\(msg, privacy: .public)")

        let entry = LogEntry(
            level: level,
            category: category,
            message: msg,
            file: file,
            line: line
        )
        LogStore.shared.append(entry)
    }

    @inlinable
    public static func debug(
        _ category: LogCategory, _ message: @autoclosure () -> String, file: String = #file, line: Int = #line
    ) {
        log(.debug, category: category, message(), file: file, line: line)
    }

    @inlinable
    public static func info(
        _ category: LogCategory, _ message: @autoclosure () -> String, file: String = #file, line: Int = #line
    ) {
        log(.info, category: category, message(), file: file, line: line)
    }

    @inlinable
    public static func notice(
        _ category: LogCategory, _ message: @autoclosure () -> String, file: String = #file, line: Int = #line
    ) {
        log(.notice, category: category, message(), file: file, line: line)
    }

    @inlinable
    public static func warning(
        _ category: LogCategory, _ message: @autoclosure () -> String, file: String = #file, line: Int = #line
    ) {
        log(.warning, category: category, message(), file: file, line: line)
    }

    @inlinable
    public static func error(
        _ category: LogCategory, _ message: @autoclosure () -> String, file: String = #file, line: Int = #line
    ) {
        log(.error, category: category, message(), file: file, line: line)
    }
}
