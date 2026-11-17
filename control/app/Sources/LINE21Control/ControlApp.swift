import AppKit
import SwiftUI

@main
struct LINE21ControlApp: App {
    @StateObject private var store = ControlStore()

    var body: some Scene {
        Window("LINE21 Control", id: "main") {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .onAppear { store.start() }
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Refresh") { Task { await store.refresh() } }.keyboardShortcut("r")
                Button("Log Out") { store.logout() }.disabled(!store.loggedIn)
            }
        }
    }
}
