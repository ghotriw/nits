import Foundation
import NitsCore

/// The encodings a subtitle file can be read in, by the IANA names settings store, named in the user's language. By
/// name, which puts the script first ("Cyrillic (KOI8-R)"), so a script's encodings come together.
public enum SubtitleEncodingCatalog {
    public static let all: [(name: String, title: String, encoding: String.Encoding)] = TextFileEncoding.selectable
        .compactMap { encoding in
            TextFileEncoding.name(of: encoding).map { ($0, String.localizedName(of: encoding), encoding) }
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
}
