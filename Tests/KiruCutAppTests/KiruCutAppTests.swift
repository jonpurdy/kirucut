import XCTest
@testable import KiruCutApp

final class KiruCutAppTests: XCTestCase {
    private let useInstalledFFmpegKey = "UseInstalledFFmpeg"
    private let showOpenInputAtLaunchKey = "ShowOpenInputAtLaunch"

    override func tearDown() {
        super.tearDown()
        resetSettingsAndHooks()
    }

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

    func testAppSettingsDefaultsWhenUnset() {
        resetSettingsAndHooks()

        XCTAssertFalse(AppSettings.useInstalledFFmpeg)
        XCTAssertTrue(AppSettings.showOpenInputAtLaunch)
    }

    func testPromptForInputDoesNotArmWhenLaunchPromptSettingDisabled() async {
        resetSettingsAndHooks()
        AppSettings.setShowOpenInputAtLaunch(false)

        let service = MockFFmpegService(duration: 1)
        let launchCounter = await MainActor.run { MainActorCounter() }
        let viewModel = await MainActor.run {
            CutterViewModel(
                service: service,
                previewAvailabilityDetector: { _ in nil },
                launchInputPrompter: {
                    launchCounter.increment()
                }
            )
        }

        await MainActor.run {
            viewModel.promptForInputOnLaunchIfNeeded()
        }
        try? await Task.sleep(for: .milliseconds(150))

        let attempts = await MainActor.run { launchCounter.value() }
        XCTAssertEqual(attempts, 0)
        let armed = await MainActor.run { viewModel.hasPromptedForInputOnLaunchForTesting }
        XCTAssertFalse(armed)
    }

    func testInstalledToolsAvailableRequiresBothTools() throws {
        resetSettingsAndHooks()
        let sandbox = try TemporaryDirectory()

        FFmpegService.TestHooks.installedSearchDirectoriesOverride = [sandbox.url.path]
        XCTAssertFalse(FFmpegService.installedToolsAvailable())

        try writeExecutable(
            at: sandbox.url.appendingPathComponent("ffmpeg"),
            contents: "#!/bin/zsh\necho ok\n"
        )
        XCTAssertFalse(FFmpegService.installedToolsAvailable())

        try writeExecutable(
            at: sandbox.url.appendingPathComponent("ffprobe"),
            contents: "#!/bin/zsh\necho ok\n"
        )
        XCTAssertTrue(FFmpegService.installedToolsAvailable())
    }

    func testMediaDurationUsesInstalledOrBundledResolverBySetting() async throws {
        resetSettingsAndHooks()
        let sandbox = try TemporaryDirectory()
        let installedDir = sandbox.url.appendingPathComponent("installed", isDirectory: true)
        let bundledDir = sandbox.url.appendingPathComponent("bundled", isDirectory: true)
        let bundledBinDir = bundledDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundledBinDir, withIntermediateDirectories: true)

        try writeExecutable(
            at: installedDir.appendingPathComponent("ffmpeg"),
            contents: "#!/bin/zsh\nexit 0\n"
        )
        try writeExecutable(
            at: installedDir.appendingPathComponent("ffprobe"),
            contents: "#!/bin/zsh\necho 11.11\n"
        )
        try writeExecutable(
            at: bundledBinDir.appendingPathComponent("ffprobe"),
            contents: "#!/bin/zsh\necho 22.22\n"
        )

        FFmpegService.TestHooks.installedSearchDirectoriesOverride = [installedDir.path]
        FFmpegService.TestHooks.bundledResourcesDirectoryOverride = bundledDir
        let service = FFmpegService()
        let inputURL = sandbox.url.appendingPathComponent("dummy.mp4")

        AppSettings.setUseInstalledFFmpeg(true)
        let installedDuration = try await service.mediaDuration(inputURL: inputURL)
        XCTAssertEqual(installedDuration, 11.11, accuracy: 0.001)

        AppSettings.setUseInstalledFFmpeg(false)
        let bundledDuration = try await service.mediaDuration(inputURL: inputURL)
        XCTAssertEqual(bundledDuration, 22.22, accuracy: 0.001)
    }

    func testInstalledFFprobePrefersSiblingOfResolvedFFmpeg() async throws {
        resetSettingsAndHooks()
        let sandbox = try TemporaryDirectory()
        let pathFirstDir = sandbox.url.appendingPathComponent("path-first", isDirectory: true)
        let ffmpegDir = sandbox.url.appendingPathComponent("ffmpeg-home", isDirectory: true)
        try FileManager.default.createDirectory(at: pathFirstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ffmpegDir, withIntermediateDirectories: true)

        try writeExecutable(
            at: pathFirstDir.appendingPathComponent("ffprobe"),
            contents: "#!/bin/zsh\necho 44.44\n"
        )
        try writeExecutable(
            at: ffmpegDir.appendingPathComponent("ffmpeg"),
            contents: "#!/bin/zsh\nexit 0\n"
        )
        try writeExecutable(
            at: ffmpegDir.appendingPathComponent("ffprobe"),
            contents: "#!/bin/zsh\necho 33.33\n"
        )

        FFmpegService.TestHooks.installedSearchDirectoriesOverride = [pathFirstDir.path, ffmpegDir.path]
        AppSettings.setUseInstalledFFmpeg(true)

        let duration = try await FFmpegService().mediaDuration(inputURL: sandbox.url.appendingPathComponent("dummy.mp4"))
        XCTAssertEqual(duration, 33.33, accuracy: 0.001)
    }

    private func resetSettingsAndHooks() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: useInstalledFFmpegKey)
        defaults.removeObject(forKey: showOpenInputAtLaunchKey)
        FFmpegService.TestHooks.installedSearchDirectoriesOverride = nil
        FFmpegService.TestHooks.bundledResourcesDirectoryOverride = nil
    }
}

@MainActor
private final class MainActorCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        let parent = FileManager.default.temporaryDirectory
        url = parent.appendingPathComponent("KiruCutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

private func writeExecutable(at url: URL, contents: String) throws {
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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
