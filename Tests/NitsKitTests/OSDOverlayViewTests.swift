import Foundation
import NitsUI
import Testing

@Suite("OSDOverlayView Tests")
@MainActor
struct OSDOverlayViewTests {
    @Test("Seek event provides progress value based on current and duration")
    func testSeekProgressValue() {
        let viewNormal = OSDOverlayView(event: .seek(offsetSeconds: 5, currentTime: 30, duration: 60))
        #expect(viewNormal.progressValue == 0.5)

        let viewStart = OSDOverlayView(event: .seek(offsetSeconds: -5, currentTime: 0, duration: 100))
        #expect(viewStart.progressValue == 0.0)

        let viewEnd = OSDOverlayView(event: .seek(offsetSeconds: 5, currentTime: 100, duration: 100))
        #expect(viewEnd.progressValue == 1.0)

        let viewNegativeClamped = OSDOverlayView(event: .seek(offsetSeconds: -10, currentTime: -5, duration: 100))
        #expect(viewNegativeClamped.progressValue == 0.0)

        let viewOverClamped = OSDOverlayView(event: .seek(offsetSeconds: 10, currentTime: 110, duration: 100))
        #expect(viewOverClamped.progressValue == 1.0)

        let viewZeroDuration = OSDOverlayView(event: .seek(offsetSeconds: 5, currentTime: 10, duration: 0))
        #expect(viewZeroDuration.progressValue == nil)

        let viewNegativeDuration = OSDOverlayView(event: .seek(offsetSeconds: 5, currentTime: 10, duration: -10))
        #expect(viewNegativeDuration.progressValue == nil)

        let viewInfiniteDuration = OSDOverlayView(
            event: .seek(offsetSeconds: 5, currentTime: 10, duration: Double.infinity))
        #expect(viewInfiniteDuration.progressValue == nil)

        let viewNanDuration = OSDOverlayView(event: .seek(offsetSeconds: 5, currentTime: 10, duration: Double.nan))
        #expect(viewNanDuration.progressValue == nil)
    }

    @Test("Volume event provides progress value based on volume level")
    func testVolumeProgressValue() {
        let viewNormal = OSDOverlayView(event: .volume(level: 0.75, isMuted: false))
        #expect(viewNormal.progressValue == 0.75)

        let viewMuted = OSDOverlayView(event: .volume(level: 0.75, isMuted: true))
        #expect(viewMuted.progressValue == 0.0)
    }
}
