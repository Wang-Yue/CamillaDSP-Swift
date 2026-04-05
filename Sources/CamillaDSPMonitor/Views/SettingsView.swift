// SettingsView - App preferences

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            DevicePickerView()
                .tabItem {
                    Label("Audio", systemImage: "hifispeaker.2")
                }
                .frame(width: 450, height: 350)
        }
    }
}
