import NitsTouchKit
import NitsTouchUI
import SwiftUI

@main
struct NitsApp: App {
    @State private var session = TouchPlayerSession()

    var body: some Scene {
        WindowGroup {
            PlayerScreen(session: session)
                // A file opened from Files, or shared to Nits: its scoped access is the session's to hold.
                .onOpenURL { url in
                    if url.isFileURL {
                        session.open(url)
                    } else {
                        session.openNetwork(url.absoluteString)
                    }
                }
        }
    }
}
