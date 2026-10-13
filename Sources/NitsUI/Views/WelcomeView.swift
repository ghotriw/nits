import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct WelcomeView: View {
    public var onOpenFile: () -> Void
    public var onOpenURL: (() -> Void)?
    public var onFileDropped: ((String) -> Void)?
    public var onFilesDropped: (([URL]) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isTargetedForDrop: Bool = false

    public init(
        onOpenFile: @escaping () -> Void,
        onOpenURL: (() -> Void)? = nil,
        onFileDropped: @escaping (String) -> Void
    ) {
        self.onOpenFile = onOpenFile
        self.onOpenURL = onOpenURL
        self.onFileDropped = onFileDropped
        self.onFilesDropped = nil
    }

    public init(
        onOpenFile: @escaping () -> Void,
        onOpenURL: (() -> Void)? = nil,
        onFilesDropped: @escaping ([URL]) -> Void
    ) {
        self.onOpenFile = onOpenFile
        self.onOpenURL = onOpenURL
        self.onFileDropped = nil
        self.onFilesDropped = onFilesDropped
    }

    public var body: some View {
        ZStack {
            // Adaptive gradient overlay for depth over vibrancy
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color.black.opacity(0.15), Color.black.opacity(0.35)]
                    : [Color.white.opacity(0.20), Color.black.opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .gesture(WindowDragGesture())

            VStack(spacing: 28) {
                // App Logo (Native vector logo)
                LogoView(theme: .monterey)
                    .frame(width: 80, height: 88)

                // Title & Subtitle
                VStack(spacing: 6) {
                    Text("Nits")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("Drop video here or open a file to start watching")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                }

                // Action buttons
                HStack(spacing: 14) {
                    Button(action: onOpenFile) {
                        Label("Open File…", systemImage: "folder")
                            .font(.system(size: 13, weight: .medium))
                            .frame(minWidth: 120, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button(action: { onOpenURL?() }) {
                        Label("Open URL…", systemImage: "link")
                            .font(.system(size: 13, weight: .medium))
                            .frame(minWidth: 120, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)

            // Drop highlight border
            if isTargetedForDrop {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(8)
                    .transition(.opacity)
            }
        }
        .frame(width: 520, height: 350)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            if let onFilesDropped {
                onFilesDropped(urls)
            } else if let firstUrl = urls.first {
                onFileDropped?(firstUrl.path)
            }
            return true
        } isTargeted: { targeted in
            isTargetedForDrop = targeted
        }
    }
}
