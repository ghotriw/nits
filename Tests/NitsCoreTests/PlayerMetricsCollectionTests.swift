import Foundation
import NitsTestSupport
import Testing

@testable import NitsCore

@Suite("Player metrics collection")
@MainActor
struct PlayerMetricsCollectionTests {
    @Test("The metrics timer runs only while metrics are collected")
    func testTimerFollowsCollection() {
        let engine = PlayerEngine.makeForTesting()
        #expect(engine.metricsTimer == nil)

        engine.isCollectingMetrics = true
        let timer = engine.metricsTimer
        #expect(timer != nil)
        // Asked again, the running timer stays.
        engine.isCollectingMetrics = true
        #expect(engine.metricsTimer === timer)

        engine.isCollectingMetrics = false
        #expect(engine.metricsTimer == nil)
    }

    @Test("Turned on, collection reports the process's memory", .hostDependent)
    func testCollectionReportsProcessMetrics() async {
        let engine = PlayerEngine.makeForTesting()
        engine.isCollectingMetrics = true
        defer { engine.isCollectingMetrics = false }
        #expect(await waitUntil { engine.currentMetrics.memoryUsageMB > 0 })
    }
}
