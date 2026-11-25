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
            // Undetermined is no language: its name would read "Unknown". (`mul`, several languages, is one worth showing.)
            let hasLanguage = language.lowercased() != "und"
            let languageName = hasLanguage ? (locale.localizedString(forLanguageCode: language) ?? language) : ""
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

    extension AudioTrackLabel {
        /// What a label is made of: a track's, apart from the demuxer's type.
        struct Entry: Equatable {
            var id: Int
            var title: String
            var language: String
            var codecName: String
            var channels: Int
        }

        /// The label of each track; those that would read the same get their codec added, and those still the same
        /// (one language, one codec, no title) a number in the order they come.
        static func labels(for entries: [Entry], locale: Locale = .current) -> [Int: String] {
            let plain = entries.map {
                text(
                    title: $0.title, language: $0.language, codecName: $0.codecName, channels: $0.channels,
                    locale: locale)
            }
            func duplicates(_ labels: [String], of label: String) -> Bool { labels.filter { $0 == label }.count > 1 }
            let withCodec = zip(entries, plain).map { entry, label in
                duplicates(plain, of: label) && !entry.codecName.isEmpty
                    && !label.localizedCaseInsensitiveContains(entry.codecName)
                    ? "\(label) · \(entry.codecName)" : label
            }
            var seen: [String: Int] = [:]
            var labels: [Int: String] = [:]
            for (entry, label) in zip(entries, withCodec) {
                if duplicates(withCodec, of: label) {
                    seen[label, default: 0] += 1
                    labels[entry.id] = "\(label) (\(seen[label] ?? 1))"
                } else {
                    labels[entry.id] = label
                }
            }
            return labels
        }

        static func labels(for tracks: [MediaDemuxer.AudioTrack], locale: Locale = .current) -> [Int: String] {
            labels(
                for: tracks.map {
                    Entry(
                        id: $0.id, title: $0.title, language: $0.language, codecName: $0.codecName,
                        channels: $0.channels)
                }, locale: locale)
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
                let labels = AudioTrackLabel.labels(for: engine.audioTracks)
                Menu {
                    Picker("Audio", selection: selection) {
                        ForEach(engine.audioTracks) { track in
                            Text(labels[track.id] ?? track.title).tag(track.id)
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
