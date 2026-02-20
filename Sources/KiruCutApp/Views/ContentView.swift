import AVKit
import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: CutterViewModel
    private let fileButtonWidth: CGFloat = 128

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Files") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Open Input File...") {
                            viewModel.pickInputFile()
                        }
                        .frame(width: fileButtonWidth, alignment: .leading)
                        Text(viewModel.inputPathDisplay)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    HStack {
                        Button("Choose Output Folder...") {
                            viewModel.pickOutputFile()
                        }
                        .frame(width: fileButtonWidth, alignment: .leading)
                        Text(viewModel.outputPathDisplay)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Trim") {
                HStack(spacing: 24) {
                    VStack(alignment: .leading) {
                        Text("Start Time (seconds or mm:ss)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if viewModel.hasSelectedInput {
                            TextField("", text: $viewModel.startTimeText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .onChange(of: viewModel.startTimeText) { _, _ in
                                    viewModel.schedulePredictionUpdate()
                                }
                        } else {
                            TextField("", text: $viewModel.startTimeText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .disabled(true)
                        }
                    }

                    VStack(alignment: .leading) {
                        Text("End Time (seconds or mm:ss)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if viewModel.hasSelectedInput {
                            TextField("", text: $viewModel.endTimeText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .onChange(of: viewModel.endTimeText) { _, _ in
                                    viewModel.schedulePredictionUpdate()
                                }
                        } else {
                            TextField("", text: $viewModel.endTimeText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .disabled(true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let inputURL = viewModel.inputURL {
                GroupBox("Preview") {
                    InputPreviewPlayer(inputURL: inputURL) { start, end in
                        viewModel.applyTrimSelection(start: start, end: end)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                }
            }

            HStack(spacing: 12) {
                Button("Cut Video") {
                    viewModel.runCut()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isRunning)
            }

            ProgressView(value: viewModel.progressValue, total: 1.0)
                .progressViewStyle(.linear)
                .opacity(viewModel.isRunning || viewModel.progressValue > 0 ? 1 : 0)

            if !viewModel.cutPredictionText.isEmpty {
                Text(viewModel.cutPredictionText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text(viewModel.statusMessage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(viewModel.statusColor)
                .textSelection(.enabled)
        }
        .padding(20)
        .onAppear {
            viewModel.promptForInputOnLaunchIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.promptForInputOnLaunchIfNeeded()
        }
    }
}

private struct InputPreviewPlayer: View {
    let inputURL: URL
    let onApplyTrim: (Double, Double) -> Void

    @State private var trimRequestID = 0
    @State private var canBeginTrimming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("Trim with Player...") {
                    trimRequestID += 1
                }
                .disabled(!canBeginTrimming)

                if !canBeginTrimming {
                    Text("Preparing trim controls...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            InputPreviewPlayerView(
                inputURL: inputURL,
                trimRequestID: $trimRequestID,
                canBeginTrimming: $canBeginTrimming,
                onApplyTrim: onApplyTrim
            )
            .frame(maxWidth: .infinity, minHeight: 190)
        }
    }
}

private struct InputPreviewPlayerView: NSViewRepresentable {
    let inputURL: URL
    @Binding var trimRequestID: Int
    @Binding var canBeginTrimming: Bool
    let onApplyTrim: (Double, Double) -> Void

    final class Coordinator {
        var lastTrimRequestID = 0
        var statusObservation: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: inputURL)
        observePlayerItemStatus(in: view, context: context)
        DispatchQueue.main.async {
            canBeginTrimming = view.canBeginTrimming
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard let currentAsset = (view.player?.currentItem?.asset as? AVURLAsset)?.url else {
            view.player = AVPlayer(url: inputURL)
            observePlayerItemStatus(in: view, context: context)
            return
        }
        if currentAsset != inputURL {
            view.player?.pause()
            view.player?.replaceCurrentItem(with: AVPlayerItem(url: inputURL))
            view.player?.seek(to: .zero)
            observePlayerItemStatus(in: view, context: context)
            context.coordinator.lastTrimRequestID = trimRequestID
        }

        canBeginTrimming = view.canBeginTrimming
        guard trimRequestID > context.coordinator.lastTrimRequestID else { return }
        context.coordinator.lastTrimRequestID = trimRequestID
        beginTrimming(on: view)
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.statusObservation = nil
        view.player?.pause()
        view.player = nil
    }

    private func observePlayerItemStatus(in view: AVPlayerView, context: Context) {
        context.coordinator.statusObservation = view.player?.currentItem?.observe(\.status, options: [.initial, .new]) { _, _ in
            DispatchQueue.main.async {
                canBeginTrimming = view.canBeginTrimming
            }
        }
    }

    private func beginTrimming(on view: AVPlayerView) {
        guard view.canBeginTrimming else { return }
        guard let playerItem = view.player?.currentItem else { return }

        view.player?.pause()
        view.beginTrimming { result in
            DispatchQueue.main.async {
                canBeginTrimming = view.canBeginTrimming
                guard result == .okButton else { return }

                let startSeconds = playerItem.reversePlaybackEndTime.isNumeric ? max(0, playerItem.reversePlaybackEndTime.seconds) : 0
                let endSeconds: Double
                if playerItem.forwardPlaybackEndTime.isNumeric {
                    endSeconds = max(startSeconds, playerItem.forwardPlaybackEndTime.seconds)
                } else if playerItem.duration.isNumeric {
                    endSeconds = max(startSeconds, playerItem.duration.seconds)
                } else {
                    return
                }

                onApplyTrim(startSeconds, endSeconds)
            }
        }
    }
}
