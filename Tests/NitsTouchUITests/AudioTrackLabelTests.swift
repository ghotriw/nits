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

        @Test("More than stereo adds the channel layout")
        func labelAddsChannelsWhenMoreThanStereo() {
            #expect(AudioTrackLabel.text(title: "", language: "ukr", codecName: "eac3", channels: 6).contains("5.1"))
            #expect(!AudioTrackLabel.text(title: "", language: "ukr", codecName: "aac", channels: 2).contains("2.0"))
        }
    }
#endif
