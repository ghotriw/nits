import AppKit
import NitsCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings pane section for managing untracked folders and domains excluded from history and recents.
struct HistoryExclusionsView: View {
    let excludedFolders: [ExcludedFolder]
    let excludedDomains: [String]
    let onAddFolder: (ExcludedFolder) -> Void
    let onRemoveFolder: (ExcludedFolder) -> Void
    let onAddDomain: (String) -> Void
    let onRemoveDomain: (String) -> Void

    @State private var newDomainText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Folders Section
            VStack(alignment: .leading, spacing: 6) {
                Text("Untracked Folders")
                    .font(.subheadline)
                    .fontWeight(.medium)

                if excludedFolders.isEmpty {
                    Text("No folders excluded. Media opened from all folders will be tracked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                } else {
                    VStack(spacing: 6) {
                        ForEach(excludedFolders) { folder in
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                                        .font(.body)
                                        .lineLimit(1)
                                    Text(displayPath(folder.path))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button {
                                    onRemoveFolder(folder)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove folder from exclusions")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("Add Folder…") {
                        chooseFolder()
                    }
                    Text("or drop folders from Finder")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
            }

            Divider()

            // Domains Section
            VStack(alignment: .leading, spacing: 6) {
                Text("Untracked Domains")
                    .font(.subheadline)
                    .fontWeight(.medium)

                if excludedDomains.isEmpty {
                    Text("No domains excluded. Streams from all network domains will be tracked.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 2)
                } else {
                    VStack(spacing: 6) {
                        ForEach(excludedDomains, id: \.self) { domain in
                            HStack(spacing: 8) {
                                Image(systemName: "globe")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(domain)
                                    .font(.body)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    onRemoveDomain(domain)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove domain from exclusions")
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField("Domain (e.g. example.com)", text: $newDomainText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addDomain()
                        }

                    Button("Add Domain") {
                        addDomain()
                    }
                    .disabled(HistoryExclusionPolicy.normalizeDomain(newDomainText) == nil)
                }
                .padding(.top, 2)
            }
        }
    }

    private func addPath(_ path: String) {
        let folder = ExcludedFolder.resolve(from: path)
        guard !excludedFolders.contains(where: { $0.overlaps(folder) }) else { return }
        onAddFolder(folder)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Folder to Exclude from History"
        panel.prompt = "Exclude"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true

        let handleSelection: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            for url in panel.urls {
                addPath(url.path)
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handleSelection)
        } else {
            panel.begin(completionHandler: handleSelection)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var didHandle = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    Task { @MainActor in
                        addPath(url.path)
                    }
                }
            }
            didHandle = true
        }
        return didHandle
    }

    private func addDomain() {
        guard let normalized = HistoryExclusionPolicy.normalizeDomain(newDomainText) else { return }
        newDomainText = ""
        guard !excludedDomains.contains(normalized) else { return }
        onAddDomain(normalized)
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
