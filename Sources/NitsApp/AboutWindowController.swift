import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 10),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let hostingView = NSHostingView(rootView: AboutView())
        window.contentView = hostingView
        window.setContentSize(hostingView.fittingSize)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private struct AboutView: View {
    private static let repository = "https://github.com/ghotriw/nits"

    private static let licenseURL = URL(string: repository + "/blob/main/LICENSE")

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "Version \(short)" : "Version \(short) (\(build))"
    }

    /// The license texts themselves ship in `Contents/Resources/ThirdPartyLicenses`.
    private static let noticesURL = URL(string: repository + "/blob/main/THIRD_PARTY_NOTICES.md")

    private var copyright: String? {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.bottom, 12)

            Text("Nits")
                .font(.system(size: 24, weight: .semibold))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            VStack(spacing: 2) {
                if let copyright {
                    Text(copyright).foregroundStyle(.secondary)
                }
                if let licenseURL = Self.licenseURL {
                    Link("MIT License", destination: licenseURL)
                }
            }
            .font(.system(size: 11))
            .padding(.top, 8)

            Divider()
                .padding(.vertical, 20)

            VStack(spacing: 4) {
                Text("Acknowledgements").font(.system(size: 12, weight: .semibold))
                Text(
                    "Nits uses FFmpeg, dav1d, libass, FreeType, HarfBuzz, FriBidi and libunibreak. FFmpeg and FriBidi are licensed under the LGPL v2.1 or later; their source code is published with [Nits releases](https://github.com/ghotriw/nits/releases)."
                )
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
                Text("HDR tone mapping is adapted from mpv (LGPL v2.1 or later).")
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .font(.system(size: 11))

            if let noticesURL = Self.noticesURL {
                Link("Third-Party Notices", destination: noticesURL)
                    .font(.system(size: 11))
                    .padding(.top, 12)
            }
        }
        .multilineTextAlignment(.center)
        .frame(width: 380)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .fixedSize(horizontal: false, vertical: true)
    }
}
