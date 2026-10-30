import Foundation
import NitsCore
import Observation
import SwiftUI
import os

@Observable
@MainActor
public final class OSDManager {
    public private(set) var currentEvent: OSDEvent?
    public private(set) var isVisible: Bool = false
    /// How long `show(_:)` keeps an event on screen when no explicit duration is passed.
    @ObservationIgnored public var eventDuration: Double = 1.3
    /// Off, `show(_:)` ignores events and the one on screen goes; the debug OSD is apart (`configureDebug`).
    @ObservationIgnored public var isEnabled: Bool = true {
        didSet {
            if !isEnabled, oldValue {
                hide()
            }
        }
    }

    /// Log messages currently mirrored to the debug OSD, oldest first.
    public private(set) var debugMessages: [DebugOSDMessage] = []
    public private(set) var isDebugEnabled: Bool = false

    /// Maximum number of debug badges on screen at once; the oldest ones are dropped first.
    public static let maxDebugMessages = 6

    private var hideTask: Task<Void, Never>?

    @ObservationIgnored private var debugMinimumLevel: LogLevel = .warning
    @ObservationIgnored private var debugDuration: Double = 4.0
    @ObservationIgnored private var debugSubscription: LogSubscription?
    @ObservationIgnored private var debugPruneTask: Task<Void, Never>?
    @ObservationIgnored private var debugPruneDeadline: ContinuousClock.Instant?
    /// Level gate read by the log listener off the main actor, so filtered-out entries never hop actors.
    @ObservationIgnored private let debugLevelGate = OSAllocatedUnfairLock(initialState: LogLevel.warning)

    public init() {}

    /// Presents an OSD event and schedules auto-hiding after `duration` seconds (defaults to `eventDuration`), unless
    /// the OSD is off (`isEnabled`).
    public func show(_ event: OSDEvent, duration: Double? = nil) {
        guard isEnabled else { return }
        let duration = duration ?? eventDuration
        hideTask?.cancel()

        currentEvent = event

        if !isVisible {
            withAnimation(.easeOut(duration: 0.15)) {
                isVisible = true
            }
        }

        let validDuration = duration.isFinite ? max(0.2, duration) : 1.3
        let nanoseconds = UInt64(validDuration * 1_000_000_000)
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                self.isVisible = false
            }
        }
    }

    /// Hides the current OSD notification immediately.
    public func hide() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) {
            isVisible = false
            currentEvent = nil
        }
    }

    // MARK: - Debug OSD

    /// Enables or disables mirroring of `AppLog` messages at or above `minimumLevel` to the debug OSD.
    /// Each message stays on screen for `duration` seconds.
    public func configureDebug(
        enabled: Bool,
        minimumLevel: LogLevel,
        duration: Double,
        logStore: LogStore = .shared
    ) {
        debugMinimumLevel = minimumLevel
        debugDuration = PlayerConfiguration.clampDebugOSDDuration(duration)
        debugLevelGate.withLock { $0 = minimumLevel }

        if enabled {
            // Resubscribe when a different store is injected (tests, host apps).
            if debugSubscription?.store !== logStore {
                let gate = debugLevelGate
                let id = logStore.addListener { [weak self] entry in
                    guard entry.level >= gate.withLock({ $0 }) else { return }
                    Task { @MainActor [weak self] in
                        self?.receiveDebugLog(entry)
                    }
                }
                debugSubscription = LogSubscription(store: logStore, id: id)
            }
            if debugMessages.contains(where: { $0.level < minimumLevel }) {
                debugMessages.removeAll { $0.level < minimumLevel }
            }
        } else {
            debugSubscription = nil
            clearDebugMessages()
        }
        isDebugEnabled = enabled
    }

    /// Removes all debug badges immediately.
    public func clearDebugMessages() {
        debugPruneTask?.cancel()
        debugPruneTask = nil
        debugPruneDeadline = nil
        if !debugMessages.isEmpty {
            withAnimation(.easeInOut(duration: 0.15)) {
                debugMessages.removeAll()
            }
        }
    }

    func receiveDebugLog(_ entry: LogEntry) {
        guard isDebugEnabled, entry.level >= debugMinimumLevel else { return }
        let expiresAt = ContinuousClock.now + .milliseconds(Int(debugDuration * 1000))

        // Collapse bursts of the same message into one badge with a repeat counter.
        if let lastIndex = debugMessages.indices.last,
            debugMessages[lastIndex].level == entry.level,
            debugMessages[lastIndex].category == entry.category,
            debugMessages[lastIndex].text == entry.message
        {
            debugMessages[lastIndex].repeatCount += 1
            debugMessages[lastIndex].expiresAt = expiresAt
        } else {
            withAnimation(.easeOut(duration: 0.15)) {
                debugMessages.append(
                    DebugOSDMessage(
                        level: entry.level,
                        category: entry.category,
                        text: entry.message,
                        expiresAt: expiresAt
                    )
                )
                if debugMessages.count > Self.maxDebugMessages {
                    debugMessages.removeFirst(debugMessages.count - Self.maxDebugMessages)
                }
            }
        }
        scheduleDebugPrune()
    }

    func pruneExpiredDebugMessages(now: ContinuousClock.Instant = .now) {
        if debugMessages.contains(where: { $0.expiresAt <= now }) {
            withAnimation(.easeInOut(duration: 0.2)) {
                debugMessages.removeAll { $0.expiresAt <= now }
            }
        }
        scheduleDebugPrune()
    }

    /// Keeps a single timer armed for the earliest expiry instead of one task per message.
    /// Re-arms when a message expires sooner than the pending deadline (e.g. after the duration was shortened).
    private func scheduleDebugPrune() {
        guard let deadline = debugMessages.map(\.expiresAt).min() else { return }
        if debugPruneTask != nil, let pending = debugPruneDeadline, pending <= deadline { return }
        debugPruneTask?.cancel()
        debugPruneDeadline = deadline
        debugPruneTask = Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard let self, !Task.isCancelled else { return }
            self.debugPruneTask = nil
            self.debugPruneDeadline = nil
            self.pruneExpiredDebugMessages()
        }
    }
}

/// Removes its `LogStore` listener when released, so the subscription's lifetime follows its owner.
private final class LogSubscription: Sendable {
    let store: LogStore
    let id: UUID

    init(store: LogStore, id: UUID) {
        self.store = store
        self.id = id
    }

    deinit {
        store.removeListener(id)
    }
}

extension OSDManager {
    /// Shows the title of the item Next or Previous moved to (`PlayerEngine.playNext()` / `playPrevious()`); nothing
    /// when it didn't move.
    public func showTrackChange(to title: String?, isNext: Bool) {
        guard let title else { return }
        show(.custom(symbol: isNext ? "forward.end.fill" : "backward.end.fill", text: title))
    }
}
