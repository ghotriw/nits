#if os(iOS)
    import Foundation
    import Testing

    @testable import NitsTouchUI

    @Suite("Audio track label")
    struct AudioTrackLabelTests {
        @Test("The menu is for a choice: two tracks or more")
        func shownOnlyWithChoice() {
            #expect(!AudioTrackLabel.isShown(trackCount: 0))
            #expect(!AudioTrackLabel.isShown(trackCount: 1))
            #expect(AudioTrackLabel.isShown(trackCount: 2))
        }

        @Test("Title first, then language, then codec")
        func labelPrefersTitleThenLanguageThenCodec() {
            #expect(
                AudioTrackLabel.text(title: "Commentary", language: "eng", codecName: "aac", channels: 2)
                    == "Commentary")
            #expect(AudioTrackLabel.text(title: "", language: "zzz", codecName: "aac", channels: 2).contains("zzz"))
            #expect(AudioTrackLabel.text(title: "", language: "", codecName: "eac3", channels: 2).contains("eac3"))
        }

        @Test("A language code reads as the language's name")
        func languageIsNamed() {
            let text = AudioTrackLabel.text(
                title: "", language: "ukr", codecName: "aac", channels: 2, locale: Locale(identifier: "en"))
            #expect(text == "Ukrainian")
        }

        @Test("An undetermined language is named by the codec, not 'Unknown'")
        func undeterminedLanguageUsesCodec() {
            let text = AudioTrackLabel.text(
                title: "", language: "und", codecName: "eac3", channels: 2, locale: Locale(identifier: "en"))
            #expect(text == "eac3")
        }

        private func entry(_ id: Int, _ language: String, _ codec: String, title: String = "") -> AudioTrackLabel.Entry
        {
            .init(id: id, title: title, language: language, codecName: codec, channels: 2)
        }

        @Test("Only tracks that would read the same get the codec")
        func codecOnlyForDuplicates() {
            let labels = AudioTrackLabel.labels(
                for: [entry(1, "eng", "aac"), entry(2, "eng", "eac3"), entry(3, "ukr", "aac")],
                locale: Locale(identifier: "en"))
            #expect(labels[1] == "English · aac")
            #expect(labels[2] == "English · eac3")
            #expect(labels[3] == "Ukrainian")
        }

        @Test("A codec already in the label is not added again")
        func codecNotRepeated() {
            let labels = AudioTrackLabel.labels(
                for: [entry(1, "und", "aac"), entry(2, "und", "aac")], locale: Locale(identifier: "en"))
            // The label is the codec already; only the number tells them apart.
            #expect(labels[1] == "aac (1)")
            #expect(labels[2] == "aac (2)")
        }

        @Test("Tracks the same in language and codec are numbered")
        func identicalTracksAreNumbered() {
            let labels = AudioTrackLabel.labels(
                for: [entry(1, "eng", "aac"), entry(2, "eng", "aac")], locale: Locale(identifier: "en"))
            #expect(labels[1] == "English · aac (1)")
            #expect(labels[2] == "English · aac (2)")
        }

        @Test("More than stereo adds the channel layout")
        func labelAddsChannelsWhenMoreThanStereo() {
            #expect(AudioTrackLabel.text(title: "", language: "ukr", codecName: "eac3", channels: 6).contains("5.1"))
            #expect(!AudioTrackLabel.text(title: "", language: "ukr", codecName: "aac", channels: 2).contains("2.0"))
        }
    }
#endif
