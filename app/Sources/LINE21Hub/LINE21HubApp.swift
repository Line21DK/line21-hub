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
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 720, height: 600)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Søg efter opdateringer") { Task { await store.refresh() } }.keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView().environmentObject(store)
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
