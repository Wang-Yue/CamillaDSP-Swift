// CamillaDSP Monitor - Native macOS SwiftUI app
// Directly uses CamillaDSPLib for real-time audio DSP configuration and monitoring

import SwiftUI
import AppKit

@main
struct CamillaDSPMonitorApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.meters)
                .frame(minWidth: 960, minHeight: 680)
                .onAppear {
                    appDelegate.appState = appState
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 780)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if MiniPlayerWindowController.shared.isMiniPlayerVisible {
            MiniPlayerWindowController.shared.closeMiniPlayer()
            return false
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Ensure all state is saved before quit
        appState?.savePipelineStages()
        appState?.saveEQPresets()
    }
}
