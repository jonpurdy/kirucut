import SwiftUI

@main
struct KiruCutApp: App {
    @StateObject private var viewModel = CutterViewModel(service: FFmpegService())

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 680, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
    }
}
