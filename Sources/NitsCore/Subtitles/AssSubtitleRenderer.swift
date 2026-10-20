import CLibass
import Foundation
import os

/// How much of the user's subtitle style replaces an ASS script's own on its dialogue. libass decides what is
/// dialogue: lines without explicit positioning, so typeset signs keep the script's style in every mode.
public enum AssStyleOverride: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The script's styles as authored.
    case none
    /// The user's font and size.
    case font
    /// The user's font, size, colors and background.
    case full

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: "As Authored"
        case .font: "Font and Size"
        case .full: "Font, Size and Colors"
        }
    }
}

/// Draws an ASS / SSA track with libass: styles, positions, animations, karaoke, vector drawings and the fonts the
/// media attaches. Output is one finished picture per frame, sized for the area it is drawn on.
///
/// Every libass call happens under one lock, so the renderer can be fed events from the demuxer's thread while
/// another renders.
public final class AssSubtitleRenderer: @unchecked Sendable {
    /// What a render found.
    public enum Output {
        /// Nothing changed since the previous render: keep showing the last picture.
        case unchanged
        /// The picture to show; `nil` when no event is on screen.
        case frame(SubtitleImageCue?)
    }

    /// The user's subtitle style, laid over the script's dialogue as `mode` says.
    public struct StyleOverride: Equatable, Sendable {
        public var mode: AssStyleOverride
        /// A family name Core Text finds, or the one inside `fontFile`.
        public var fontName: String
        /// A font file libass is given first: Core Text hides the system's rounded, serif and monospaced designs.
        public var fontFile: URL?
        /// Points on a picture 720 pixels high, as the subtitle style's size.
        public var fontSize: Double
        /// `0xRRGGBB`.
        public var textColor: UInt32
        public var textOpacity: Double
        public var backgroundColor: UInt32
        /// 0 draws an outline without a box.
        public var backgroundOpacity: Double

        public init(
            mode: AssStyleOverride, fontName: String, fontFile: URL? = nil, fontSize: Double, textColor: UInt32,
            textOpacity: Double = 1, backgroundColor: UInt32, backgroundOpacity: Double
        ) {
            self.mode = mode
            self.fontName = fontName
            self.fontFile = fontFile
            self.fontSize = fontSize
            self.textColor = textColor
            self.textOpacity = textOpacity
            self.backgroundColor = backgroundColor
            self.backgroundOpacity = backgroundOpacity
        }

        /// The user's subtitle style (as `PlayerEngine` keeps it) for libass: the font through `libassFont`, colors
        /// with the alpha a `#RRGGBBAA` gives them, as the text overlay draws them.
        public init(
            mode: AssStyleOverride, subtitleFontName: String, fontSize: Double, textColorHex: String,
            backgroundColorHex: String, backgroundOpacity: Double
        ) {
            let font = Self.libassFont(for: subtitleFontName)
            let text = Self.rgba(hex: textColorHex) ?? (0xFF_FFFF, 1)
            let background = Self.rgba(hex: backgroundColorHex) ?? (0, 1)
            self.init(
                mode: mode, fontName: font.name, fontFile: font.file, fontSize: fontSize, textColor: text.rgb,
                textOpacity: text.alpha, backgroundColor: background.rgb,
                backgroundOpacity: backgroundOpacity * background.alpha)
        }

        /// SF Pro, as Core Text lists it to libass.
        static let systemFontFamily = "System Font"

        /// What libass draws a stored subtitle font name with: a font family as it is; a system design by the family
        /// name in its file, which libass is given as Core Text doesn't list it (SF Pro aside). A design whose file is
        /// missing falls back to SF Pro.
        static func libassFont(for fontName: String) -> (name: String, file: URL?) {
            guard let system = SubtitleSystemFont(fontName: fontName) else { return (fontName, nil) }
            return systemFonts[system] ?? (systemFontFamily, nil)
        }

        /// The system designs' fonts for libass, their files looked for once.
        private static let systemFonts: [SubtitleSystemFont: (name: String, file: URL?)] = {
            let designs: [SubtitleSystemFont: (file: String, family: String)] = [
                .rounded: ("SFNSRounded.ttf", ".SF NS Rounded"),
                .serif: ("NewYork.ttf", ".New York"),
                .monospaced: ("SFNSMono.ttf", ".SF NS Mono"),
            ]
            var fonts: [SubtitleSystemFont: (name: String, file: URL?)] = [.standard: (systemFontFamily, nil)]
            for (system, design) in designs {
                let file = URL(fileURLWithPath: "/System/Library/Fonts/" + design.file)
                if FileManager.default.fileExists(atPath: file.path) { fonts[system] = (design.family, file) }
            }
            return fonts
        }()

        /// `#RRGGBB` (opaque) or `#RRGGBBAA`, as the subtitle style stores colors.
        static func rgba(hex: String) -> (rgb: UInt32, alpha: Double)? {
            var digits = hex.trimmingCharacters(in: .whitespaces)
            if digits.hasPrefix("#") { digits.removeFirst() }
            guard digits.count == 6 || digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
            return digits.count == 8 ? (value >> 8, Double(value & 0xFF) / 255) : (value, 1)
        }

        /// libass scales an override style as if written for a script 288 lines high (mpv's
        /// `MP_ASS_FONT_PLAYRESY`), which the 720-line sizes are converted to.
        static let styleScale = 288.0 / 720.0

        /// The override bits for `mode`, `nil` included (none).
        static func bits(for override: StyleOverride?) -> Int32 {
            // The font scale (`setPlacement`) only applies to dialogue: signs keep the picture's scale.
            Int32(ASS_OVERRIDE_BIT_SELECTIVE_FONT_SCALE.rawValue) | (override?.bits ?? 0)
        }

        var bits: Int32 {
            switch mode {
            case .none: 0
            case .font: Int32(ASS_OVERRIDE_BIT_FONT_NAME.rawValue | ASS_OVERRIDE_BIT_FONT_SIZE_FIELDS.rawValue)
            case .full:
                Int32(
                    ASS_OVERRIDE_BIT_FONT_NAME.rawValue | ASS_OVERRIDE_BIT_FONT_SIZE_FIELDS.rawValue
                        | ASS_OVERRIDE_BIT_COLORS.rawValue | ASS_OVERRIDE_BIT_BORDER.rawValue
                        | ASS_OVERRIDE_BIT_BLUR.rawValue)
            }
        }

        /// An ASS color: `0xRRGGBBTT` with transparency, not opacity, in the low byte.
        static func assColor(_ rgb: UInt32, opacity: Double) -> UInt32 {
            let alpha = UInt32((min(max(opacity, 0), 1) * 255).rounded())
            return (rgb & 0xFF_FFFF) << 8 | (255 - alpha)
        }

        /// The style's name: libass copies the whole style but duplicates only `FontName`, so `Name` must outlive it.
        private nonisolated(unsafe) static let styleName: UnsafeMutablePointer<CChar> = strdup("Nits")

        /// Hands the style to libass, which duplicates `FontName` (not `Name`, hence `styleName`).
        func apply(to renderer: OpaquePointer) {
            let scale = Self.styleScale
            let hasBox = backgroundOpacity > 0
            fontName.withCString { font in
                var style = ASS_Style()
                style.Name = Self.styleName
                style.FontName = UnsafeMutablePointer(mutating: font)
                style.FontSize = fontSize * scale
                style.ScaleX = 1
                style.ScaleY = 1
                style.PrimaryColour = Self.assColor(textColor, opacity: textOpacity)
                style.SecondaryColour = style.PrimaryColour
                style.OutlineColour = Self.assColor(0, opacity: 1)
                style.BackColour = Self.assColor(backgroundColor, opacity: hasBox ? backgroundOpacity : 0.5)
                // Outline and a background box behind the line (libass' style 4), as the plain-text overlay draws.
                style.BorderStyle = hasBox ? 4 : 1
                style.Outline = 1.5 * scale
                style.Shadow = hasBox ? 0 : 1 * scale
                style.Alignment = 2
                ass_set_selective_style_override(renderer, &style)
            }
            ass_set_selective_style_override_enabled(renderer, Self.bits(for: self))
        }
    }

    private struct State {
        var library: OpaquePointer?
        var renderer: OpaquePointer?
        var track: UnsafeMutablePointer<ASS_Track>?
        var frameWidth = 0
        var frameHeight = 0
        var styleOverride: StyleOverride?
        var placement = (scale: 1.0, raise: 0.0)
        /// Font files handed to libass for overrides, by path.
        var addedFontFiles: Set<String> = []
        /// Whether a frame was rendered yet: the first result is always applied, even an empty one.
        var hasRendered = false
        /// Events fed from a stream, which can't be taken back.
        var fedEvents = 0
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// `nil` when libass can't set up the script (an unreadable file, no header).
    public init?(script: AssScript) {
        let created = state.withLockUnchecked { state -> Bool in
            guard let library = ass_library_init() else { return false }
            state.library = library
            // Fonts embedded in a script file's [Fonts] section, as well as the ones the container attaches.
            ass_set_extract_fonts(library, 1)
            ass_set_message_cb(
                library, { level, format, arguments, _ in AssSubtitleRenderer.log(level, format, arguments) }, nil)
            for font in script.fonts {
                font.data.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                    ass_add_font(library, font.name, base, Int32(bytes.count))
                }
            }
            guard let renderer = ass_renderer_init(library) else { return false }
            state.renderer = renderer
            Self.setFonts(renderer)

            if script.isCompleteFile {
                // libass takes a mutable buffer (it copies it); a script with [Fonts] can run to megabytes, so the
                // bytes aren't converted one by one. Already UTF-8: with a code page libass would run it through iconv.
                var header = script.header
                state.track = header.withUnsafeMutableBytes { bytes in
                    bytes.baseAddress.map {
                        ass_read_memory(library, $0.assumingMemoryBound(to: CChar.self), bytes.count, nil)
                    } ?? nil
                }
            } else {
                state.track = ass_new_track(library)
                if let track = state.track {
                    script.header.withUnsafeBytes { bytes in
                        guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                        ass_process_codec_private(track, base, Int32(bytes.count))
                    }
                }
            }
            return state.track != nil
        }
        guard created else {
            Self.release(state)
            return nil
        }
        addEvents(script.events)
    }

    deinit {
        Self.release(state)
    }

    /// Core Text finds installed fonts and falls back across scripts (CJK, Arabic) on its own. Called again after
    /// adding a font: libass only sees fonts added before it.
    private static func setFonts(_ renderer: OpaquePointer) {
        ass_set_fonts(renderer, nil, "Helvetica Neue", Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 1)
    }

    private static func release(_ state: OSAllocatedUnfairLock<State>) {
        state.withLockUnchecked { state in
            if let track = state.track { ass_free_track(track) }
            if let renderer = state.renderer { ass_renderer_done(renderer) }
            if let library = state.library { ass_library_done(library) }
            state = State()
        }
    }

    /// Hands events of a stream to libass; those fed before (counted by position) are skipped, so the whole growing
    /// list of a live source can be passed again.
    public func addEvents(_ events: [AssScript.Event]) {
        state.withLockUnchecked { state in
            guard let track = state.track, state.fedEvents < events.count else { return }
            for event in events[state.fedEvents...] {
                event.payload.withCString { text in
                    ass_process_chunk(
                        track, text, Int32(event.payload.utf8.count), Int64((event.start * 1000).rounded()),
                        Int64((event.duration * 1000).rounded()))
                }
            }
            state.fedEvents = events.count
        }
    }

    /// Sets the size of the area to draw on, in pixels, and the video it covers (storage size and pixel aspect, which
    /// scripts that scale with the video use). Cheap when nothing changed.
    public func configure(frameWidth: Int, frameHeight: Int, videoWidth: Int, videoHeight: Int, pixelAspect: Double) {
        state.withLockUnchecked { state in
            guard let renderer = state.renderer, frameWidth > 0, frameHeight > 0 else { return }
            if state.frameWidth != frameWidth || state.frameHeight != frameHeight {
                state.frameWidth = frameWidth
                state.frameHeight = frameHeight
                ass_set_frame_size(renderer, Int32(frameWidth), Int32(frameHeight))
            }
            ass_set_storage_size(renderer, Int32(videoWidth), Int32(videoHeight))
            ass_set_pixel_aspect(renderer, pixelAspect)
        }
    }

    /// Sets the user's style laid over the script's dialogue; `nil` or mode `.none` draws the script as authored.
    /// Cheap when nothing changed.
    public func setStyleOverride(_ override: StyleOverride?) {
        state.withLockUnchecked { state in
            guard let renderer = state.renderer, let library = state.library else { return }
            let override = override?.mode == AssStyleOverride.none ? nil : override
            guard override != state.styleOverride else { return }
            state.styleOverride = override
            if let override {
                var applied = override
                if let file = override.fontFile, !state.addedFontFiles.contains(file.path) {
                    if let data = try? Data(contentsOf: file, options: .mappedIfSafe) {
                        data.withUnsafeBytes { bytes in
                            guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                            ass_add_font(library, file.lastPathComponent, base, Int32(bytes.count))
                        }
                        state.addedFontFiles.insert(file.path)
                        Self.setFonts(renderer)
                    } else {
                        // SF Pro rather than libass' default; the file is tried again with the next change of style.
                        AppLog.warning(.subtitles, "Can't read the subtitle font \(file.path)")
                        applied.fontName = StyleOverride.systemFontFamily
                    }
                }
                applied.apply(to: renderer)
            } else {
                ass_set_selective_style_override_enabled(renderer, StyleOverride.bits(for: nil))
            }
        }
    }

    /// Scales dialogue by `scale` and raises it by `raise` (a fraction of the frame's height, 0 leaves it where the
    /// script puts it); positioned text keeps its size and place. Cheap when nothing changed.
    public func setPlacement(scale: Double, raise: Double) {
        state.withLockUnchecked { state in
            guard let renderer = state.renderer else { return }
            let placement = (scale: scale.isFinite && scale > 0 ? scale : 1, raise: min(max(raise, 0), 1))
            guard placement != state.placement else { return }
            state.placement = placement
            ass_set_selective_style_override_enabled(renderer, StyleOverride.bits(for: state.styleOverride))
            ass_set_font_scale(renderer, placement.scale)
            ass_set_line_position(renderer, placement.raise * 100)
        }
    }

    /// Renders the events due at `seconds` into the configured frame size.
    public func render(at seconds: Double) -> Output {
        state.withLockUnchecked { state in
            guard let renderer = state.renderer, let track = state.track, state.frameWidth > 0 else {
                return .unchanged
            }
            var change: Int32 = 0
            let images = ass_render_frame(renderer, track, Int64((seconds * 1000).rounded()), &change)
            let isFirst = !state.hasRendered
            state.hasRendered = true
            guard change != 0 || isFirst else { return .unchanged }
            let regions = images.map { Self.compose($0) } ?? []
            guard !regions.isEmpty else { return .frame(nil) }
            return .frame(
                SubtitleImageCue(
                    id: SubtitleImageCue.makeID(), startTime: seconds, endTime: seconds, canvasWidth: state.frameWidth,
                    canvasHeight: state.frameHeight, regions: regions, placement: .visiblePicture))
        }
    }

    /// Pixels between two of libass' images up to which they still make one picture: the glyph runs of a line do.
    static let clusterMargin = 16

    /// A rectangle of the frame in pixels, `max` exclusive.
    private struct Bounds {
        var minX: Int
        var minY: Int
        var maxX: Int
        var maxY: Int

        init(_ image: ASS_Image) {
            minX = Int(image.dst_x)
            minY = Int(image.dst_y)
            maxX = minX + Int(image.w)
            maxY = minY + Int(image.h)
        }

        func isNear(_ other: Bounds) -> Bool {
            minX - clusterMargin < other.maxX && other.minX - clusterMargin < maxX
                && minY - clusterMargin < other.maxY && other.minY - clusterMargin < maxY
        }

        func union(_ other: Bounds) -> Bounds {
            var result = self
            result.minX = min(minX, other.minX)
            result.minY = min(minY, other.minY)
            result.maxX = max(maxX, other.maxX)
            result.maxY = max(maxY, other.maxY)
            return result
        }
    }

    /// Blends libass' alpha masks (each with its color, back to front) into premultiplied BGRA pictures, one per group
    /// of images near each other. A sign at the top and the dialogue at the bottom make two small pictures, not one
    /// the size of the frame that would be allocated, filled and uploaded with every animated frame.
    static func compose(_ first: UnsafeMutablePointer<ASS_Image>) -> [SubtitleImageCue.Region] {
        var images: [ASS_Image] = []
        var node: UnsafeMutablePointer<ASS_Image>? = first
        while let image = node?.pointee {
            // libass' alpha is transparency: 0 is opaque.
            if image.w > 0, image.h > 0, image.color & 0xFF != 0xFF, image.bitmap != nil { images.append(image) }
            node = image.next
        }

        // Groups of images, each in libass' order. A group that grows may reach others, so merging repeats.
        var groups: [(bounds: Bounds, members: [Int])] = []
        for (index, image) in images.enumerated() {
            var bounds = Bounds(image)
            var members = [index]
            var other = 0
            while other < groups.count {
                if groups[other].bounds.isNear(bounds) {
                    bounds = bounds.union(groups[other].bounds)
                    members += groups[other].members
                    groups.remove(at: other)
                    other = 0
                } else {
                    other += 1
                }
            }
            groups.append((bounds, members))
        }
        return groups.map { group in
            compose(group.members.sorted().map { images[$0] }, in: group.bounds)
        }
    }

    private static func compose(_ images: [ASS_Image], in bounds: Bounds) -> SubtitleImageCue.Region {
        let minX = bounds.minX
        let minY = bounds.minY
        let width = bounds.maxX - minX
        let height = bounds.maxY - minY
        // Filled in place: a copy of the picture into `Data` afterwards would double the work.
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let destination = raw.bindMemory(to: UInt8.self)
            for image in images {
                let opacity = 255 - (image.color & 0xFF)
                guard let mask = image.bitmap else { continue }
                let red = image.color >> 24
                let green = (image.color >> 16) & 0xFF
                let blue = (image.color >> 8) & 0xFF
                for row in 0..<Int(image.h) {
                    let source = mask + row * Int(image.stride)
                    var offset = ((Int(image.dst_y) - minY + row) * width + Int(image.dst_x) - minX) * 4
                    for column in 0..<Int(image.w) {
                        defer { offset += 4 }
                        let alpha = (UInt32(source[column]) * opacity + 127) / 255
                        if alpha == 0 { continue }
                        let keep = 255 - alpha
                        destination[offset] = UInt8(
                            (blue * alpha + 127) / 255 + (UInt32(destination[offset]) * keep + 127) / 255)
                        destination[offset + 1] = UInt8(
                            (green * alpha + 127) / 255 + (UInt32(destination[offset + 1]) * keep + 127) / 255)
                        destination[offset + 2] = UInt8(
                            (red * alpha + 127) / 255 + (UInt32(destination[offset + 2]) * keep + 127) / 255)
                        destination[offset + 3] = UInt8(alpha + (UInt32(destination[offset + 3]) * keep + 127) / 255)
                    }
                }
            }
        }
        return SubtitleImageCue.Region(x: minX, y: minY, width: width, height: height, premultipliedBGRA: pixels)
    }

    /// libass reports through a C callback with a printf-style format; its warnings (a missing font) reach the log.
    private static func log(_ level: Int32, _ format: UnsafePointer<CChar>?, _ arguments: CVaListPointer?) {
        guard let format, let arguments, level <= 4 else { return }
        var buffer = [CChar](repeating: 0, count: 512)
        vsnprintf(&buffer, buffer.count, format, arguments)
        let message = buffer.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } ?? "" }
        if level <= 2 {
            AppLog.warning(.subtitles, "libass: \(message)")
        } else {
            AppLog.debug(.subtitles, "libass: \(message)")
        }
    }
}
