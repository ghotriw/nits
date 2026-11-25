#if os(iOS)
    import CoreGraphics
    import NitsCore

    /// What the chapters panel decides apart from its views: when the button is there, where the panel goes and how a row reads.
    enum ChapterPanelLogic {
        enum Placement: Equatable {
            /// A sheet over the lower part of the screen (portrait).
            case bottom
            /// A panel at the right edge (landscape, a wide iPad window).
            case trailing
        }

        /// A single chapter is no list to choose from.
        static func isButtonShown(chapterCount: Int) -> Bool { chapterCount > 1 }

        static func placement(for size: CGSize) -> Placement { size.width > size.height ? .trailing : .bottom }

        /// "start · length"; the start alone for a chapter that has no length.
        static func rowDetail(_ chapter: MediaChapter) -> String {
            let start = ScrubTimeline.clock(chapter.start)
            guard chapter.duration > 0 else { return start }
            return start + " · " + ScrubTimeline.clock(chapter.duration)
        }
    }
#endif
