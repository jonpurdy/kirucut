import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var useInstalledFFmpeg = FFmpegService.useInstalledFFmpeg
    @State private var showOpenInputAtLaunch = AppSettings.showOpenInputAtLaunch

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Use installed ffmpeg", isOn: Binding(
                get: { useInstalledFFmpeg },
                set: { newValue in
                    applyUseInstalledFFmpeg(newValue)
                }
            ))

            Toggle("Show Open Input File at launch", isOn: Binding(
                get: { showOpenInputAtLaunch },
                set: { newValue in
                    showOpenInputAtLaunch = newValue
                    AppSettings.setShowOpenInputAtLaunch(newValue)
                }
            ))
        }
    }

    private func applyUseInstalledFFmpeg(_ newValue: Bool) {
        guard newValue else {
            useInstalledFFmpeg = false
            FFmpegService.setUseInstalledFFmpeg(false)
            return
        }

        guard FFmpegService.installedToolsAvailable() else {
            showMissingInstallAlert()
            useInstalledFFmpeg = false
            FFmpegService.setUseInstalledFFmpeg(false)
            return
        }

        useInstalledFFmpeg = true
        FFmpegService.setUseInstalledFFmpeg(true)
    }

    private func showMissingInstallAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Installed ffmpeg was not found"
        alert.informativeText = "Install ffmpeg and ffprobe first (for example: brew install ffmpeg)."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
