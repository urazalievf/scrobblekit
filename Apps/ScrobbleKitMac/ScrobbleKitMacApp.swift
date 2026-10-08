import AppKit
import ScrobbleCore
import SwiftUI

@main
struct ScrobbleKitMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = MenuBarController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environment(controller)
                .modelContainer(controller.container)
        } label: {
            Image(systemName: controller.menuBarSymbol)
                .accessibilityLabel(Text("ScrobbleKit: \(controller.summary.headline)"))
        }
        .menuBarExtraStyle(.window)

        Settings {
            PreferencesView()
                .environment(controller)
                .modelContainer(controller.container)
        }
    }
}

/// Receives the `scrobblekit://lastfm-callback` URL after the Last.fm web
/// login. An app delegate gets it even when no window is open, which a menu
/// bar app usually doesn't have.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            MainActor.assumeIsolated { MenuBarController.shared.handleCallback(url) }
        }
    }
}
