import XCTest
@testable import KiruCutApp

final class KiruCutAppTests: XCTestCase {
    func testLoadInputSetsDurationBeforeSlowPreviewCheckFinishes() async throws {
        let url = URL(fileURLWithPath: "/tmp/input.mp4")
        let service = MockFFmpegService(duration: 12.5)
        let viewModel = await MainActor.run {
            CutterViewModel(
                service: service,
                previewAvailabilityDetector: { _ in
                    try? await Task.sleep(for: .seconds(1))
                    return "Preview unsupported"
                }
            )
        }

        let task = await MainActor.run { viewModel.loadInputFile(url: url) }
        try await waitUntil(timeout: .milliseconds(300)) {
            await MainActor.run {
                viewModel.endTimeText == "12.50" &&
                viewModel.statusMessage == "Input selected. Output defaulted to same folder." &&
                viewModel.isCheckingPreviewAvailability
            }
        }

        await task.value
        let finalMessage = await MainActor.run { viewModel.previewUnavailableMessage }
        XCTAssertEqual(finalMessage, "Preview unsupported")
    }

    func testRunCutRejectsOutputMatchingInputPath() async throws {
        let url = URL(fileURLWithPath: "/tmp/same-path.mp4")
        let service = MockFFmpegService(duration: 10)
        let viewModel = await MainActor.run {
            CutterViewModel(service: service, previewAvailabilityDetector: { _ in nil })
        }

        let loadTask = await MainActor.run { viewModel.loadInputFile(url: url) }
        await loadTask.value
        await MainActor.run {
            viewModel.setOutputFile(url: url)
            viewModel.startTimeText = "0"
            viewModel.endTimeText = "5"
            viewModel.runCut()
        }

        let status = await MainActor.run { viewModel.statusMessage }
        XCTAssertEqual(status, "Output file must be different from input file.")
        let cutCalled = await service.didCallCut()
        XCTAssertFalse(cutCalled)
    }

    func testRunProcessHandlesLargeOutput() async throws {
        let service = FFmpegService()
        let output = try await withTimeout(.seconds(8)) {
            try await service.runProcess(
                executable: "/bin/zsh",
                arguments: ["-lc", "for i in {1..50000}; do printf 'line%05d\\n' $i; done"]
            )
        }

        XCTAssertEqual(output.exitCode, 0)
        XCTAssertTrue(output.output.contains("line50000"))
    }
}

private actor MockFFmpegServiceState {
    var didCallCut = false

    func markCutCalled() {
        didCallCut = true
    }

    func wasCutCalled() -> Bool {
        didCallCut
    }
}

private struct MockFFmpegService: FFmpegServicing {
    let duration: Double
    private let state = MockFFmpegServiceState()

    func cut(inputURL: URL, outputURL: URL, start: Double, duration: Double, overwriteOutput: Bool) async throws {
        await state.markCutCalled()
    }

    func mediaDuration(inputURL: URL) async throws -> Double {
        duration
    }

    func predictCut(inputURL: URL, requestedStart: Double, requestedEnd: Double) async throws -> CutPrediction {
        CutPrediction(
            requestedStart: requestedStart,
            requestedEnd: requestedEnd,
            predictedStart: requestedStart,
            predictedEnd: requestedEnd,
            frameRate: 30
        )
    }

    func didCallCut() async -> Bool {
        await state.wasCutCalled()
    }
}

private enum TimeoutError: Error {
    case timedOut
}

private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError.timedOut
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private func waitUntil(
    timeout: Duration,
    condition: @escaping @Sendable () async -> Bool
) async throws {
    try await withTimeout(timeout) {
        while await !condition() {
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
