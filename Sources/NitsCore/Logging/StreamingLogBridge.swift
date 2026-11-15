internal import NitsStreaming
import os

/// Backs the streaming client's log (`StreamingLog`) with `AppLog`. The client writes nowhere until `install()` ran, which
/// is once for the process and must come before the first object of the client is made: every place of NitsCore that
/// makes one calls it (the engine is not the only one: thumbnails, the resolver's probes and the duration probe open the
/// client without it). The host's level (`AppLog.minimumLogLevel`) is passed on whenever it changes.
enum StreamingLogBridge {
    private static let installed: Void = {
        StreamingLog.install { level, message, file, line in
            AppLog.log(LogLevel(level), category: .demuxer, { message }, file: file, line: line)
        }
        StreamingLog.setThreshold(StreamingLog.Level(AppLog.minimumLogLevel))
    }()

    static func install() {
        _ = installed
    }

    static func thresholdChanged(to level: LogLevel) {
        StreamingLog.setThreshold(StreamingLog.Level(level))
    }
}

extension LogLevel {
    fileprivate init(_ level: StreamingLog.Level) {
        switch level {
        case .debug: self = .debug
        case .info: self = .info
        case .warning: self = .warning
        case .error: self = .error
        }
    }
}

extension StreamingLog.Level {
    fileprivate init(_ level: LogLevel) {
        switch level {
        case .debug: self = .debug
        case .info: self = .info
        case .notice: self = .info
        case .warning: self = .warning
        case .error: self = .error
        }
    }
}
