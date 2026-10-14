import Testing

@testable import NitsCore

@Suite("Display Link Frame Rate Selection")
struct DisplayLinkRateTests {
    private func rate(fps: Double, screen: Int) -> Int {
        PlayerEngine.preferredDisplayLinkRate(contentFrameDuration: 1.0 / fps, screenMaximumRate: screen)
    }

    @Test("ProMotion 120 Hz: lowest whole-multiple divisor rate, else the panel maximum")
    func testProMotion() {
        #expect(rate(fps: 24, screen: 120) == 120)  // 48 does not divide 120
        #expect(rate(fps: 24000.0 / 1001.0, screen: 120) == 120)
        #expect(rate(fps: 25, screen: 120) == 120)  // no whole multiple: finest cadence
        #expect(rate(fps: 30, screen: 120) == 60)
        #expect(rate(fps: 30000.0 / 1001.0, screen: 120) == 60)
        #expect(rate(fps: 50, screen: 120) == 120)
        #expect(rate(fps: 60, screen: 120) == 60)
        #expect(rate(fps: 60000.0 / 1001.0, screen: 120) == 60)
        #expect(rate(fps: 120, screen: 120) == 120)
    }

    @Test("Fixed 60 Hz and high-refresh external screens")
    func testOtherScreens() {
        #expect(rate(fps: 24, screen: 60) == 60)
        #expect(rate(fps: 30, screen: 60) == 60)
        #expect(rate(fps: 50, screen: 60) == 60)
        #expect(rate(fps: 24, screen: 144) == 48)
        #expect(rate(fps: 25, screen: 100) == 50)
        #expect(rate(fps: 50, screen: 100) == 50)
    }

    @Test("Invalid content frame duration falls back to the screen maximum")
    func testInvalidDuration() {
        #expect(PlayerEngine.preferredDisplayLinkRate(contentFrameDuration: 0, screenMaximumRate: 120) == 120)
        #expect(PlayerEngine.preferredDisplayLinkRate(contentFrameDuration: .nan, screenMaximumRate: 120) == 120)
    }
}
