@preconcurrency import AVFoundation
import AppKit
import Foundation
import SwiftUI

@MainActor
final class CutterViewModel: ObservableObject {
    typealias PreviewAvailabilityDetector = @Sendable (URL) async -> String?
    typealias LaunchInputPrompter = @MainActor () -> Void

    @Published var startTimeText: String = ""
    @Published var endTimeText: String = ""
    @Published private(set) var inputURL: URL?
    @Published private(set) var outputURL: URL?
    @Published private(set) var statusMessage: String = "Choose input/output and click Cut Video."
    @Published private(set) var statusColor: Color = .secondary
    @Published private(set) var isRunning = false
    @Published private(set) var progressValue = 0.0
    @Published private(set) var cutPredictionText: String = ""
    @Published private(set) var isCheckingPreviewAvailability = false
    @Published private(set) var previewUnavailableMessage: String?

    private let service: any FFmpegServicing
    private var progressTask: Task<Void, Never>?
    private var predictionTask: Task<Void, Never>?
    private var launchPromptTask: Task<Void, Never>?
    private var inputDurationSeconds: Double?
    private var hasPromptedForInputOnLaunch = false
    private let previewAvailabilityDetector: PreviewAvailabilityDetector
    private let launchInputPrompter: LaunchInputPrompter?

    init(
        service: any FFmpegServicing,
        previewAvailabilityDetector: PreviewAvailabilityDetector? = nil,
        launchInputPrompter: LaunchInputPrompter? = nil
    ) {
        self.service = service
        self.previewAvailabilityDetector = previewAvailabilityDetector ?? { url in
            await Self.defaultPreviewAvailabilityDetector(for: url)
        }
        self.launchInputPrompter = launchInputPrompter
    }

    var hasPromptedForInputOnLaunchForTesting: Bool {
        hasPromptedForInputOnLaunch
    }

    var inputPathDisplay: String {
        inputURL?.path(percentEncoded: false) ?? "No file selected"
    }

    var outputPathDisplay: String {
        outputURL?.path(percentEncoded: false) ?? "No file selected"
    }

    var hasSelectedInput: Bool {
        inputURL != nil
    }

    func promptForInputOnLaunchIfNeeded() {
        guard AppSettings.showOpenInputAtLaunch else { return }
        guard !hasPromptedForInputOnLaunch else { return }
        hasPromptedForInputOnLaunch = true
        guard inputURL == nil else { return }

        launchPromptTask?.cancel()
        launchPromptTask = Task { @MainActor in
            for _ in 0..<20 {
                if NSApp.isActive, NSApp.keyWindow != nil {
                    break
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard self.inputURL == nil else { return }
            NSApp.activate(ignoringOtherApps: true)
            if let launchInputPrompter = self.launchInputPrompter {
                launchInputPrompter()
            } else {
                self.pickInputFile()
            }
            self.launchPromptTask = nil
        }
    }

    func pickInputFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose input video"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        _ = loadInputFile(url: url)
    }

    @discardableResult
    func loadInputFile(url: URL) -> Task<Void, Never> {
        inputURL = url
        outputURL = defaultOutputURL(for: url)
        startTimeText = "0"
        endTimeText = ""
        inputDurationSeconds = nil
        cutPredictionText = ""
        isCheckingPreviewAvailability = true
        previewUnavailableMessage = nil
        statusMessage = "Input selected. Reading duration..."
        statusColor = .secondary

        return Task {
            async let previewAvailability = previewAvailabilityDetector(url)

            do {
                let duration = try await service.mediaDuration(inputURL: url)
                guard inputURL == url else { return }
                inputDurationSeconds = duration
                endTimeText = formatTimeForInput(duration)
                statusMessage = "Input selected. Output defaulted to same folder."
                statusColor = .secondary
                schedulePredictionUpdate()
            } catch {
                guard inputURL == url else { return }
                inputDurationSeconds = nil
                cutPredictionText = ""
                statusMessage = "Input selected, but duration could not be read: \(error.localizedDescription)"
                statusColor = .red
            }

            let previewMessage = await previewAvailability
            guard inputURL == url else { return }
            isCheckingPreviewAvailability = false
            previewUnavailableMessage = previewMessage
        }
    }

    func pickOutputFile() {
        let panel = NSSavePanel()
        panel.title = "Choose output video"
        if let inputURL {
            panel.directoryURL = inputURL.deletingLastPathComponent()
            panel.nameFieldStringValue = defaultOutputURL(for: inputURL).lastPathComponent
        } else {
            panel.nameFieldStringValue = "out.mp4"
        }
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        outputURL = url
        statusMessage = "Output selected."
        statusColor = .secondary
    }

    func setOutputFile(url: URL) {
        outputURL = url
        statusMessage = "Output selected."
        statusColor = .secondary
    }

    func runCut() {
        guard !isRunning else { return }

        guard let inputURL else {
            statusMessage = "Select an input file first."
            statusColor = .red
            return
        }

        guard let outputURL else {
            statusMessage = "Select an output file first."
            statusColor = .red
            return
        }

        guard inputURL.standardizedFileURL != outputURL.standardizedFileURL else {
            statusMessage = "Output file must be different from input file."
            statusColor = .red
            return
        }

        guard let start = parseTime(startTimeText), start >= 0 else {
            statusMessage = "Start time must be seconds or mm:ss, and >= 0."
            statusColor = .red
            return
        }

        guard let parsedEnd = parseTime(endTimeText), parsedEnd >= 0 else {
            statusMessage = "End time must be seconds or mm:ss, and >= 0."
            statusColor = .red
            return
        }

        let end: Double
        if let inputDurationSeconds, parsedEnd > inputDurationSeconds {
            let clamped = inputDurationSeconds
            endTimeText = formatTimeForInput(clamped)
            statusMessage = "End time exceeded file length. End time was reset to video end."
            statusColor = .secondary
            return
        } else {
            end = parsedEnd
        }
        endTimeText = formatTimeForInput(end)

        let duration = end - start
        guard duration > 0 else {
            statusMessage = "End time must be greater than start time."
            statusColor = .red
            return
        }

        let shouldOverwrite: Bool
        if FileManager.default.fileExists(atPath: outputURL.path) {
            shouldOverwrite = confirmOverwrite(for: outputURL)
            guard shouldOverwrite else {
                statusMessage = "Canceled: output file was not overwritten."
                statusColor = .secondary
                return
            }
        } else {
            shouldOverwrite = false
        }

        isRunning = true
        startProgress(estimatedDuration: duration)
        statusMessage = "Running ffmpeg..."
        statusColor = .secondary

        Task {
            defer {
                isRunning = false
                progressTask?.cancel()
                progressTask = nil
            }
            do {
                if let prediction = try? await service.predictCut(inputURL: inputURL, requestedStart: start, requestedEnd: end) {
                    cutPredictionText = formatPrediction(prediction)
                }

                try await service.cut(
                    inputURL: inputURL,
                    outputURL: outputURL,
                    start: start,
                    duration: duration,
                    overwriteOutput: shouldOverwrite
                )
                progressValue = 1.0
                statusMessage = "Success: \(outputURL.lastPathComponent)"
                statusColor = .green
            } catch {
                progressValue = 0.0
                statusMessage = "Error: \(error.localizedDescription)"
                statusColor = .red
            }
        }
    }

    func schedulePredictionUpdate() {
        predictionTask?.cancel()
        predictionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            await self?.updatePrediction()
        }
    }

    func applyTrimSelection(start: Double, end: Double) {
        guard inputURL != nil else { return }

        var clampedStart = max(0, start)
        var clampedEnd = max(0, end)
        if let inputDurationSeconds {
            clampedStart = min(clampedStart, inputDurationSeconds)
            clampedEnd = min(clampedEnd, inputDurationSeconds)
        }

        guard clampedEnd > clampedStart else {
            statusMessage = "Invalid trim selection from preview."
            statusColor = .red
            return
        }

        startTimeText = formatTimeForInput(clampedStart)
        endTimeText = formatTimeForInput(clampedEnd)
        statusMessage = "Trim range updated from preview."
        statusColor = .secondary
        schedulePredictionUpdate()
    }

    private func defaultOutputURL(for inputURL: URL) -> URL {
        let directory = inputURL.deletingLastPathComponent()
        let inputName = inputURL.deletingPathExtension().lastPathComponent
        let ext = inputURL.pathExtension.isEmpty ? "mp4" : inputURL.pathExtension
        let fileName = "\(inputName)-cut.\(ext)"
        return directory.appendingPathComponent(fileName)
    }

    private func confirmOverwrite(for outputURL: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Output file exists"
        alert.informativeText = "\"\(outputURL.lastPathComponent)\" already exists. Do you want to replace it?"
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    
    private func parseTime(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let seconds = Double(trimmed), seconds >= 0 {
            return seconds
        }

        let parts = trimmed.split(separator: ":")
        guard parts.count == 2 else { return nil }
        guard let minutes = Double(parts[0]), minutes >= 0 else { return nil }
        guard let seconds = Double(parts[1]), seconds >= 0, seconds < 60 else { return nil }
        return (minutes * 60) + seconds
    }

    private func formatTimeForInput(_ seconds: Double) -> String {
        if seconds < 60 {
            return formatSeconds(seconds)
        }

        let totalMinutes = Int(seconds) / 60
        let remainingSeconds = seconds - (Double(totalMinutes) * 60)
        return "\(totalMinutes):" + formatSecondsComponent(remainingSeconds)
    }

    private func formatSeconds(_ value: Double) -> String {
        let clamped = max(0, value)
        if abs(clamped.rounded() - clamped) < 0.005 {
            return String(Int(clamped.rounded()))
        }
        return String(format: "%.2f", clamped)
    }

    private func formatSecondsComponent(_ value: Double) -> String {
        let safe = max(0, min(value, 59.999))
        if abs(safe.rounded() - safe) < 0.005 {
            return String(format: "%02d", Int(safe.rounded()))
        }
        return String(format: "%05.2f", safe)
    }

    private func updatePrediction() async {
        guard let inputURL else {
            cutPredictionText = ""
            return
        }
        guard let start = parseTime(startTimeText), start >= 0 else {
            cutPredictionText = ""
            return
        }
        guard let end = parseTime(endTimeText), end > start else {
            cutPredictionText = ""
            return
        }

        do {
            let prediction = try await service.predictCut(inputURL: inputURL, requestedStart: start, requestedEnd: end)
            guard self.inputURL == inputURL else { return }
            cutPredictionText = formatPrediction(prediction)
        } catch {
            cutPredictionText = ""
        }
    }

    private func formatPrediction(_ prediction: CutPrediction) -> String {
        var line = "Requested \(formatSeconds(prediction.requestedStart))s -> \(formatSeconds(prediction.requestedEnd))s | "
        line += "Predicted \(formatSeconds(prediction.predictedStart))s -> \(formatSeconds(prediction.predictedEnd))s"

        if let fps = prediction.frameRate, fps > 0 {
            let startFrame = Int((prediction.predictedStart * fps).rounded())
            let endFrame = Int((prediction.predictedEnd * fps).rounded())
            line += " (frames ~\(startFrame)-\(endFrame) @ \(String(format: "%.3f", fps))fps)"
        }
        return line
    }

    private func startProgress(estimatedDuration: Double) {
        progressTask?.cancel()
        progressValue = 0.0

        let safeDuration = max(estimatedDuration, 1.0)
        progressTask = Task { [weak self] in
            let startDate = Date()
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startDate)
                let estimated = min(elapsed / safeDuration, 0.9)
                await MainActor.run {
                    self?.progressValue = estimated
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private static func defaultPreviewAvailabilityDetector(for inputURL: URL) async -> String? {
        if inputURL.pathExtension.caseInsensitiveCompare("mkv") == .orderedSame {
            return "Preview unavailable: QuickTime does not natively support MKV playback."
        }

        let asset = AVURLAsset(url: inputURL)

        do {
            let isPlayable = try await asset.load(.isPlayable)
            guard isPlayable else {
                return "Preview unavailable: QuickTime cannot play this file's format or codec."
            }

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard !videoTracks.isEmpty else {
                return "Preview unavailable: this file has no video track."
            }

            let decodeProbeMessage = await withTaskGroup(of: String?.self) { group in
                group.addTask(priority: .userInitiated) {
                    let probeAsset = AVURLAsset(url: inputURL)
                    let generator = AVAssetImageGenerator(asset: probeAsset)
                    generator.appliesPreferredTrackTransform = true

                    return await withCheckedContinuation { continuation in
                        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, image, _, result, _ in
                            if image != nil, result == .succeeded {
                                continuation.resume(returning: nil)
                            } else {
                                continuation.resume(returning: "Preview unavailable: QuickTime cannot decode frames for this file's codec.")
                            }
                        }
                    }
                }

                group.addTask {
                    try? await Task.sleep(for: .seconds(3))
                    return "Preview unavailable: compatibility check timed out."
                }

                let firstResult = await group.next() ?? "Preview unavailable: compatibility check failed."
                group.cancelAll()
                return firstResult
            }

            if let decodeProbeMessage {
                return decodeProbeMessage
            }

            return nil
        } catch {
            return "Preview unavailable: \(error.localizedDescription)"
        }
    }
}
