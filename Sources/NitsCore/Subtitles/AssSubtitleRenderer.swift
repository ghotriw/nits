import CLibass
import Foundation
import os

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

    private struct State {
        var library: OpaquePointer?
        var renderer: OpaquePointer?
        var track: UnsafeMutablePointer<ASS_Track>?
        var frameWidth = 0
        var frameHeight = 0
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
            // Core Text finds installed fonts and falls back across scripts (CJK, Arabic) on its own.
            ass_set_fonts(renderer, nil, "Helvetica Neue", Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 1)

            if script.isCompleteFile {
                var bytes = [CChar](script.header.map { CChar(bitPattern: $0) })
                // Already UTF-8: with a code page libass would run it through iconv for nothing.
                state.track = ass_read_memory(library, &bytes, bytes.count, nil)
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
            guard let images, let region = Self.compose(images) else { return .frame(nil) }
            return .frame(
                SubtitleImageCue(
                    id: SubtitleImageCue.makeID(), startTime: seconds, endTime: seconds, canvasWidth: state.frameWidth,
                    canvasHeight: state.frameHeight, regions: [region]))
        }
    }

    /// Blends libass' alpha masks (each with its color, back to front) into one premultiplied BGRA picture that covers
    /// just the area they touch.
    static func compose(_ first: UnsafeMutablePointer<ASS_Image>) -> SubtitleImageCue.Region? {
        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min
        var node: UnsafeMutablePointer<ASS_Image>? = first
        while let image = node?.pointee {
            if image.w > 0, image.h > 0 {
                minX = min(minX, Int(image.dst_x))
                minY = min(minY, Int(image.dst_y))
                maxX = max(maxX, Int(image.dst_x) + Int(image.w))
                maxY = max(maxY, Int(image.dst_y) + Int(image.h))
            }
            node = image.next
        }
        guard minX < maxX, minY < maxY else { return nil }

        let width = maxX - minX
        let height = maxY - minY
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBufferPointer { destination in
            node = first
            while let image = node?.pointee {
                node = image.next
                // libass' alpha is transparency: 0 is opaque.
                let opacity = 255 - (image.color & 0xFF)
                guard image.w > 0, image.h > 0, opacity > 0, let mask = image.bitmap else { continue }
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
        return SubtitleImageCue.Region(x: minX, y: minY, width: width, height: height, premultipliedBGRA: Data(pixels))
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
