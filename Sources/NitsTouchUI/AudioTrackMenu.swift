#if os(iOS)
    import Foundation
    import NitsCore
    import SwiftUI

    /// How an audio track is named in the menu, and when the menu is worth showing.
    enum AudioTrackLabel {
        static func isShown(trackCount: Int) -> Bool { trackCount > 1 }

        static func text(
            title: String, language: String, codecName: String, channels: Int, locale: Locale = .current
        ) -> String {
            let languageName = locale.localizedString(forLanguageCode: language) ?? language
            let base = !title.isEmpty ? title : !languageName.isEmpty ? languageName : codecName
            guard channels > 2 else { return base }
            let layout =
                switch channels {
                case 6: "5.1"
                case 8: "7.1"
                default: "\(channels) ch"
                }
            return "\(base) · \(layout)"
        }
    }

    /// The audio tracks as a checkmarked menu; absent when there is nothing to choose.
    struct AudioTrackMenu: View, Equatable {
        let engine: PlayerEngine
        var onInteraction: () -> Void = {}

        /// Equal while it is the same engine: the screen re-evaluates its controls every quarter second and as the time moves, and a menu rebuilt
        /// while it is open flickers (what it shows it observes itself). `onInteraction` is not compared: the screen always
        /// passes the same touch of its controls' visibility.
        nonisolated static func == (lhs: AudioTrackMenu, rhs: AudioTrackMenu) -> Bool { lhs.engine === rhs.engine }

        private var selection: Binding<Int> {
            Binding(
                get: { engine.selectedAudioTrackId },
                set: {
                    engine.selectAudioTrack(id: $0)
                    onInteraction()
                })
        }

        var body: some View {
            if AudioTrackLabel.isShown(trackCount: engine.audioTracks.count) {
                Menu {
                    Picker("Audio", selection: selection) {
                        ForEach(engine.audioTracks) { track in
                            Text(
                                AudioTrackLabel.text(
                                    title: track.title, language: track.language, codecName: track.codecName,
                                    channels: track.channels)
                            ).tag(track.id)
                        }
                    }
                } label: {
                    Image(systemName: "waveform.circle").font(.title2).frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .simultaneousGesture(TapGesture().onEnded { onInteraction() })
                .accessibilityLabel("Audio")
            }
        }
    }
#endif
