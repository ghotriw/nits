#if os(iOS)
    import CoreGraphics
    import NitsCore
    import Testing

    @testable import NitsTouchUI

    @Suite("Chapter panel")
    struct ChapterPanelLogicTests {
        @Test("The button is for a choice: two chapters or more")
        func buttonShownOnlyWithChoice() {
            #expect(!ChapterPanelLogic.isButtonShown(chapterCount: 0))
            #expect(!ChapterPanelLogic.isButtonShown(chapterCount: 1))
            #expect(ChapterPanelLogic.isButtonShown(chapterCount: 2))
        }

        @Test("A tall screen gets a bottom sheet, a wide one a panel at the right")
        func placementFollowsShape() {
            #expect(ChapterPanelLogic.placement(for: CGSize(width: 393, height: 852)) == .bottom)
            #expect(ChapterPanelLogic.placement(for: CGSize(width: 852, height: 393)) == .trailing)
            #expect(ChapterPanelLogic.placement(for: CGSize(width: 500, height: 500)) == .bottom)
        }

        @Test("A row reads start and length")
        func rowDetailHasStartAndLength() {
            let chapter = MediaChapter(id: 0, title: nil, start: 95, end: 410)
            #expect(ChapterPanelLogic.rowDetail(chapter) == "1:35 · 5:15")
        }

        @Test("A chapter with no length reads its start only")
        func rowDetailWithoutLength() {
            let chapter = MediaChapter(id: 3, title: "End", start: 3640, end: 3640)
            #expect(ChapterPanelLogic.rowDetail(chapter) == "1:00:40")
        }
    }
#endif
