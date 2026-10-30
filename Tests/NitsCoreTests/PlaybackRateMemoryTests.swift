import Testing

@testable import NitsCore

@Suite("Playback rate memory")
struct PlaybackRateMemoryTests {
    @Test("A media without a saved speed starts at 1× or the previous one's, which isn't saved with it")
    func resetKeepsOrDropsTheSpeed() {
        var memory = PlaybackRateMemory()
        memory.choose()
        #expect(memory.reset(current: 1.5, carries: false) == 1.0)
        #expect(memory.reset(current: 1.5, carries: true) == 1.5)
        #expect(memory.restore(saved: nil, current: 1.5) == 1.5)
        #expect(memory.preference(for: 1.5) == nil)
    }

    @Test("The saved speed is restored and saved again")
    func restoresTheSavedSpeed() {
        var memory = PlaybackRateMemory()
        _ = memory.reset(current: 1.0, carries: false)
        #expect(memory.restore(saved: 2.0, current: 1.0) == 2.0)
        #expect(memory.preference(for: 2.0) == 2.0)
        _ = memory.reset(current: 1.0, carries: false)
        #expect(memory.restore(saved: .nan, current: 1.0) == 1.0)
        #expect(memory.preference(for: 1.0) == nil)
    }

    @Test("A speed chosen while the media loads wins over the saved one")
    func choiceWhileLoadingWins() {
        var memory = PlaybackRateMemory()
        _ = memory.reset(current: 1.0, carries: false)
        memory.choose()
        #expect(memory.restore(saved: 2.0, current: 1.5) == 1.5)
        #expect(memory.preference(for: 1.5) == 1.5)
    }
}
