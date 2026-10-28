import AppKit
import NitsCore
import NitsKit
import NitsUI
import SwiftUI

@main
struct NitsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(onConfigurationChanged: { newConfig in
                appDelegate.updateConfiguration(newConfig)
            })
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open File…") {
                    appDelegate.promptOpenFile()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open URL…") {
                    appDelegate.promptOpenURL()
                }
                .keyboardShortcut("u", modifiers: .command)

                RecentMediaMenu(appDelegate: appDelegate)
            }

            PlayerCommands(fallbackPlayer: { appDelegate.activePlayer })
        }
    }
}

private struct RecentMediaMenu: View {
    let appDelegate: AppDelegate

    var body: some View {
        Menu("Open Recent") {
            if appDelegate.rememberRecentMedia && !RecentMediaStore.shared.items.isEmpty {
                ForEach(RecentMediaStore.shared.items) { item in
                    Button(item.title) {
                        appDelegate.openRecentItem(item)
                    }
                }
                Divider()
                Button("Clear Menu") {
                    appDelegate.clearRecentMedia()
                }
            } else {
                Button("No Recent Videos") {}
                    .disabled(true)
            }
        }
    }
}
