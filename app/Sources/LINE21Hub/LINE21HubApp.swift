import AppKit
import SwiftUI

@main
struct LINE21HubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = HubStore()

    var body: some Scene {
        Window("LINE21 Hub", id: "main") {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark) // LINE21 is a dark brand; the light palette only covers system sheets.
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 720, height: 600)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates") { Task { await store.refresh() } }.keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView().environmentObject(store).preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: HubStore? {
        didSet { if oldValue == nil { Task { @MainActor in store?.start() } } }
    }

    /// Keep checking in the background after the window is closed; the Dock icon reopens it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
