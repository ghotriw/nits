import SwiftUI

/// Settings tab for customizing player control bar items (visibility & order).
public struct ControlsSettingsPane: View {
    @Bindable var controlsConfig: ControlsConfiguration

    public init(controlsConfig: ControlsConfiguration) {
        self.controlsConfig = controlsConfig
    }

    public var body: some View {
        List {
            Section {
                Text("Drag and reorder items to change their placement on the player bar, or remove optional buttons.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(controlsConfig.visibleItems) { item in
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 13))

                        Image(systemName: item.iconName)
                            .frame(width: 20)
                            .foregroundStyle(Color.accentColor)

                        Text(item.title)
                            .font(.system(size: 13))

                        Spacer()

                        if item.isRequired {
                            Text("Required")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.quaternary))
                        } else {
                            Button {
                                controlsConfig.setEnabled(item, isEnabled: false)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red.opacity(0.85))
                                    .font(.system(size: 15))
                            }
                            .buttonStyle(.plain)
                            .help("Hide from control bar")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onMove { indices, newOffset in
                    controlsConfig.move(from: indices, to: newOffset)
                }
            } header: {
                HStack {
                    Text("Active Control Bar Items")
                    Spacer()
                    Button("Reset to Defaults") {
                        controlsConfig.resetToDefaults()
                    }
                    .buttonStyle(.link)
                    .font(.subheadline)
                }
            }

            // Available hidden items to add back
            let hiddenItems = ControlBarItem.allCases.filter {
                controlsConfig.isAvailable($0) && !controlsConfig.isEnabled($0)
            }
            if !hiddenItems.isEmpty {
                Section {
                    ForEach(hiddenItems) { item in
                        HStack(spacing: 12) {
                            Image(systemName: item.iconName)
                                .frame(width: 20)
                                .foregroundStyle(.secondary)

                            Text(item.title)
                                .font(.system(size: 13))

                            Spacer()

                            Button {
                                controlsConfig.setEnabled(item, isEnabled: true)
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.system(size: 15))
                            }
                            .buttonStyle(.plain)
                            .help("Add to control bar")
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Hidden Items")
                }
            }
        }
        .listStyle(.inset)
        .onAppear {
            controlsConfig.isSettingsCustomizingControls = true
        }
        .onDisappear {
            controlsConfig.isSettingsCustomizingControls = false
        }
    }
}
