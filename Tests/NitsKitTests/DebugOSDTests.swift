import Foundation
import NitsCore
import Testing

@testable import NitsUI

@Suite("Debug OSD Tests")
@MainActor
struct DebugOSDTests {
    private func entry(_ level: LogLevel, _ message: String, category: LogCategory = .engine) -> LogEntry {
        LogEntry(level: level, category: category, message: message)
    }

    @Test("Disabled debug OSD ignores log entries")
    func testDisabledIgnoresEntries() {
        let osd = OSDManager()
        osd.receiveDebugLog(entry(.error, "boom"))
        #expect(osd.debugMessages.isEmpty)
        #expect(osd.isDebugEnabled == false)
    }

    @Test("Entries below the minimum level are filtered out")
    func testLevelFiltering() {
        let osd = OSDManager()
        osd.configureDebug(enabled: true, minimumLevel: .warning, duration: 4, logStore: LogStore(writeToDisk: false))
        osd.receiveDebugLog(entry(.info, "info"))
        osd.receiveDebugLog(entry(.warning, "warn"))
        osd.receiveDebugLog(entry(.error, "err"))
        #expect(osd.debugMessages.map(\.text) == ["warn", "err"])

        osd.configureDebug(enabled: true, minimumLevel: .error, duration: 4, logStore: LogStore(writeToDisk: false))
        #expect(osd.debugMessages.map(\.text) == ["err"])
    }

    @Test("Identical consecutive messages collapse into one badge")
    func testRepeatCollapsing() {
        let osd = OSDManager()
        osd.configureDebug(enabled: true, minimumLevel: .debug, duration: 4, logStore: LogStore(writeToDisk: false))
        osd.receiveDebugLog(entry(.warning, "stall"))
        osd.receiveDebugLog(entry(.warning, "stall"))
        osd.receiveDebugLog(entry(.warning, "stall"))
        osd.receiveDebugLog(entry(.warning, "other"))
        #expect(osd.debugMessages.count == 2)
        #expect(osd.debugMessages.first?.repeatCount == 3)
    }

    @Test("Visible stack is capped, dropping the oldest messages")
    func testCapacityCap() {
        let osd = OSDManager()
        osd.configureDebug(enabled: true, minimumLevel: .debug, duration: 4, logStore: LogStore(writeToDisk: false))
        for i in 0..<(OSDManager.maxDebugMessages + 3) {
            osd.receiveDebugLog(entry(.info, "msg \(i)"))
        }
        #expect(osd.debugMessages.count == OSDManager.maxDebugMessages)
        #expect(osd.debugMessages.first?.text == "msg 3")
    }

    @Test("Expired messages are pruned")
    func testExpiry() {
        let osd = OSDManager()
        osd.configureDebug(enabled: true, minimumLevel: .debug, duration: 2, logStore: LogStore(writeToDisk: false))
        osd.receiveDebugLog(entry(.info, "short-lived"))
        osd.pruneExpiredDebugMessages(now: .now + .seconds(1))
        #expect(osd.debugMessages.count == 1)
        osd.pruneExpiredDebugMessages(now: .now + .seconds(3))
        #expect(osd.debugMessages.isEmpty)
    }

    @Test("Disabling clears messages and stops listening to the log store")
    func testDisableUnsubscribes() async {
        let store = LogStore(writeToDisk: false)
        let osd = OSDManager()
        osd.configureDebug(enabled: true, minimumLevel: .debug, duration: 4, logStore: store)
        store.append(entry(.error, "live"))
        for _ in 0..<50 where osd.debugMessages.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(osd.debugMessages.map(\.text) == ["live"])

        osd.configureDebug(enabled: false, minimumLevel: .debug, duration: 4, logStore: store)
        #expect(osd.debugMessages.isEmpty)
        store.append(entry(.error, "after disable"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(osd.debugMessages.isEmpty)
    }

    @Test("Switching to another LogStore resubscribes and detaches the old one")
    func testResubscribeOnStoreChange() async {
        let first = LogStore(writeToDisk: false)
        let second = LogStore(writeToDisk: false)
        let osd = OSDManager()
        osd.configureDebug(enabled: true, minimumLevel: .debug, duration: 30, logStore: first)
        osd.configureDebug(enabled: true, minimumLevel: .debug, duration: 30, logStore: second)

        first.append(entry(.error, "from first"))
        second.append(entry(.error, "from second"))
        for _ in 0..<50 where osd.debugMessages.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(osd.debugMessages.map(\.text) == ["from second"])
    }

    @Test("Shortening the duration re-arms the prune timer for newer messages")
    func testShorterDurationRearmsTimer() async {
        let osd = OSDManager()
        let store = LogStore(writeToDisk: false)
        osd.configureDebug(enabled: true, minimumLevel: .debug, duration: 30, logStore: store)
        osd.receiveDebugLog(entry(.warning, "long"))

        osd.configureDebug(enabled: true, minimumLevel: .debug, duration: 1, logStore: store)
        osd.receiveDebugLog(entry(.warning, "short"))
        #expect(osd.debugMessages.count == 2)

        for _ in 0..<200 where osd.debugMessages.count == 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(osd.debugMessages.map(\.text) == ["long"])
    }
}

@Suite("OSD Duration Tests")
@MainActor
struct OSDDurationTests {
    @Test("show(_:) without explicit duration uses eventDuration")
    func testEventDurationUsed() async {
        let osd = OSDManager()
        osd.eventDuration = 0.2
        osd.show(.play)
        #expect(osd.isVisible)
        for _ in 0..<100 where osd.isVisible {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(osd.isVisible == false)
    }
}
