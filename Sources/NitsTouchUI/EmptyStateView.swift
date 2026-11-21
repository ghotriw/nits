#if os(iOS)
    import SwiftUI
    import NitsTouchKit
    import UniformTypeIdentifiers

    /// What the player shows with nothing loaded: open a file from Files, or a network address.
    struct EmptyStateView: View {
        let session: TouchPlayerSession
        @State private var isImporting = false
        @State private var isAskingForURL = false
        @State private var address = ""

        var body: some View {
            VStack(spacing: 20) {
                Image(systemName: "play.rectangle").font(.system(size: 56)).foregroundStyle(.secondary)
                Text("Nits").font(.largeTitle.weight(.semibold))
                VStack(spacing: 12) {
                    Button {
                        isImporting = true
                    } label: {
                        Label("Open File", systemImage: "folder").frame(maxWidth: 240)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        isAskingForURL = true
                    } label: {
                        Label("Open URL", systemImage: "link").frame(maxWidth: 240)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                if let message = session.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .padding()
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.movie, .audiovisualContent, .data]) {
                result in
                if case .success(let url) = result { session.open(url) }
            }
            .alert("Open URL", isPresented: $isAskingForURL) {
                TextField("https://example.com/video.m3u8", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Open") {
                    if session.openNetwork(address) { address = "" }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("An HLS, DASH or plain HTTP(S) address.")
            }
        }
    }
#endif
