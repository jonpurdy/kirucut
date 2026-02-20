import AppKit
import SwiftUI

@main
struct KiruCutApp: App {
    @StateObject private var viewModel = CutterViewModel(service: FFmpegService())

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 680)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Settings...") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
        }

        Settings {
            SettingsView()
                .frame(width: 360)
                .padding(20)
        }
    }
}
