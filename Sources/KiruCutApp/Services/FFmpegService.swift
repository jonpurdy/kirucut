import Foundation

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let copy = data
        lock.unlock()
        return copy
    }
}

struct CutPrediction: Sendable {
    let requestedStart: Double
    let requestedEnd: Double
    let predictedStart: Double
    let predictedEnd: Double
    let frameRate: Double?
}

protocol FFmpegServicing: Sendable {
    func cut(inputURL: URL, outputURL: URL, start: Double, duration: Double, overwriteOutput: Bool) async throws
    func mediaDuration(inputURL: URL) async throws -> Double
    func predictCut(inputURL: URL, requestedStart: Double, requestedEnd: Double) async throws -> CutPrediction
}

struct FFmpegService: FFmpegServicing {
    enum TestHooks {
        nonisolated(unsafe) static var installedSearchDirectoriesOverride: [String]?
        nonisolated(unsafe) static var bundledResourcesDirectoryOverride: URL?
    }

    enum ServiceError: LocalizedError {
        case ffmpegNotFound
        case ffprobeNotFound
        case durationUnavailable
        case commandFailed(code: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "ffmpeg was not found. Enable \"Use installed ffmpeg\" and install it (for example: brew install ffmpeg), or provide a bundled ffmpeg."
            case .ffprobeNotFound:
                return "ffprobe was not found. Enable \"Use installed ffmpeg\" and install it (for example: brew install ffmpeg), or provide a bundled ffprobe."
            case .durationUnavailable:
                return "Could not read input duration."
            case .commandFailed(let code, let output):
                if output.isEmpty {
                    return "ffmpeg failed with exit code \(code)."
                }
                return "ffmpeg failed with exit code \(code): \(output)"
            }
        }
    }

    static var useInstalledFFmpeg: Bool {
        AppSettings.useInstalledFFmpeg
    }

    static func setUseInstalledFFmpeg(_ value: Bool) {
        AppSettings.setUseInstalledFFmpeg(value)
    }

    static func installedToolsAvailable() -> Bool {
        let fileManager = FileManager.default
        guard let ffmpegURL = findInstalledExecutable(named: "ffmpeg", fileManager: fileManager) else {
            return false
        }

        if fileManager.isExecutableFile(atPath: ffmpegURL.deletingLastPathComponent().appendingPathComponent("ffprobe").path) {
            return true
        }

        return findInstalledExecutable(named: "ffprobe", fileManager: fileManager) != nil
    }

    func mediaDuration(inputURL: URL) async throws -> Double {
        let ffprobeURL = try await resolveFFprobeURL()
        let result = try await runProcess(
            executable: ffprobeURL.path,
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                inputURL.path
            ]
        )

        guard result.exitCode == 0 else {
            throw ServiceError.commandFailed(code: result.exitCode, output: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let duration = Double(trimmed), duration > 0 else {
            throw ServiceError.durationUnavailable
        }

        return duration
    }

    func cut(inputURL: URL, outputURL: URL, start: Double, duration: Double, overwriteOutput: Bool) async throws {
        let ffmpegURL = try await resolveFFmpegURL()
        let overwriteArg = overwriteOutput ? "-y" : "-n"

        try await runFFmpeg(
            ffmpegURL: ffmpegURL,
            arguments: [
                overwriteArg,
                "-ss", String(format: "%.2f", start),
                "-i", inputURL.path,
                "-c", "copy",
                "-map", "0",
                "-t", String(format: "%.2f", duration),
                outputURL.path
            ]
        )
    }

    func predictCut(inputURL: URL, requestedStart: Double, requestedEnd: Double) async throws -> CutPrediction {
        let ffprobeURL = try await resolveFFprobeURL()
        let requestedDuration = max(0, requestedEnd - requestedStart)

        async let packets = loadTimes(
            executable: ffprobeURL.path,
            arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "packet=pts_time",
                "-of", "csv=p=0",
                inputURL.path
            ]
        )

        async let frameRate = loadFrameRate(
            executable: ffprobeURL.path,
            inputURL: inputURL
        )

        let packetTimes = try await packets
        let fps = try await frameRate

        let predictedStart = nearestTime(atOrBefore: requestedStart, from: packetTimes) ?? requestedStart
        let nominalPredictedEnd = predictedStart + requestedDuration
        let predictedEndCandidate = nearestTime(atOrBefore: nominalPredictedEnd, from: packetTimes) ?? nominalPredictedEnd
        let predictedEnd = max(predictedStart, predictedEndCandidate)

        return CutPrediction(
            requestedStart: requestedStart,
            requestedEnd: requestedEnd,
            predictedStart: predictedStart,
            predictedEnd: predictedEnd,
            frameRate: fps
        )
    }

    private func resolveFFmpegURL() async throws -> URL {
        let fileManager = FileManager.default
        if Self.useInstalledFFmpeg {
            if let installed = Self.findInstalledExecutable(named: "ffmpeg", fileManager: fileManager) {
                return installed
            }
        } else if let bundled = Self.findBundledExecutable(named: "ffmpeg", fileManager: fileManager) {
            return bundled
        }

        throw ServiceError.ffmpegNotFound
    }

    private func resolveFFprobeURL() async throws -> URL {
        let fileManager = FileManager.default

        if Self.useInstalledFFmpeg {
            if let ffmpegURL = Self.findInstalledExecutable(named: "ffmpeg", fileManager: fileManager) {
                let siblingProbe = ffmpegURL.deletingLastPathComponent().appendingPathComponent("ffprobe").path
                if fileManager.isExecutableFile(atPath: siblingProbe) {
                    return URL(fileURLWithPath: siblingProbe)
                }
            }

            if let installed = Self.findInstalledExecutable(named: "ffprobe", fileManager: fileManager) {
                return installed
            }
        } else {
            if let ffmpegURL = Self.findBundledExecutable(named: "ffmpeg", fileManager: fileManager) {
                let siblingProbe = ffmpegURL.deletingLastPathComponent().appendingPathComponent("ffprobe").path
                if fileManager.isExecutableFile(atPath: siblingProbe) {
                    return URL(fileURLWithPath: siblingProbe)
                }
            }

            if let bundled = Self.findBundledExecutable(named: "ffprobe", fileManager: fileManager) {
                return bundled
            }
        }

        throw ServiceError.ffprobeNotFound
    }

    private static func findBundledExecutable(named name: String, fileManager: FileManager) -> URL? {
        let resourcesURL: URL
        if let override = TestHooks.bundledResourcesDirectoryOverride {
            resourcesURL = override
        } else {
            guard let bundled = Bundle.main.resourceURL else { return nil }
            resourcesURL = bundled
        }

        let direct = resourcesURL.appendingPathComponent(name)
        if fileManager.isExecutableFile(atPath: direct.path) {
            return direct
        }

        let inBin = resourcesURL.appendingPathComponent("bin/\(name)")
        if fileManager.isExecutableFile(atPath: inBin.path) {
            return inBin
        }

        return nil
    }

    private static func findInstalledExecutable(named name: String, fileManager: FileManager) -> URL? {
        let pathCandidates: [String]
        if let overrideDirectories = TestHooks.installedSearchDirectoriesOverride {
            pathCandidates = overrideDirectories.map { "\($0)/\(name)" }
        } else {
            pathCandidates = [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)",
                "/usr/bin/\(name)"
            ]
        }

        for path in pathCandidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        if TestHooks.installedSearchDirectoriesOverride != nil {
            return nil
        }

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for path in pathEnv.split(separator: ":") {
                let candidate = String(path) + "/\(name)"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }

        return nil
    }

    private func runFFmpeg(ffmpegURL: URL, arguments: [String]) async throws {
        let result = try await runProcess(executable: ffmpegURL.path, arguments: arguments)
        guard result.exitCode == 0 else {
            throw ServiceError.commandFailed(code: result.exitCode, output: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func loadTimes(executable: String, arguments: [String]) async throws -> [Double] {
        let result = try await runProcess(executable: executable, arguments: arguments)
        guard result.exitCode == 0 else {
            throw ServiceError.commandFailed(code: result.exitCode, output: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return result.output
            .split(whereSeparator: \.isNewline)
            .compactMap(parseFirstCSVNumber)
            .sorted()
    }

    private func loadFrameRate(executable: String, inputURL: URL) async throws -> Double? {
        let result = try await runProcess(
            executable: executable,
            arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=avg_frame_rate",
                "-of", "default=noprint_wrappers=1:nokey=1",
                inputURL.path
            ]
        )
        guard result.exitCode == 0 else {
            return nil
        }

        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "0/0" else { return nil }

        if value.contains("/") {
            let parts = value.split(separator: "/")
            guard parts.count == 2,
                  let num = Double(parts[0]),
                  let den = Double(parts[1]),
                  den != 0 else { return nil }
            return num / den
        }

        return Double(value)
    }

    private func nearestTime(atOrBefore target: Double, from times: [Double]) -> Double? {
        guard !times.isEmpty else { return nil }
        var best: Double?
        for t in times {
            if t <= target {
                best = t
            } else {
                break
            }
        }
        return best
    }

    private func parseFirstCSVNumber(_ line: Substring) -> Double? {
        let raw = String(line).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        let token = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(raw)
        let cleaned = token.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }

    func runProcess(
        executable: String,
        arguments: [String],
        collectOutput: Bool = true
    ) async throws -> (exitCode: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            let outputBuffer = ProcessOutputBuffer()

            if collectOutput {
                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    outputBuffer.append(data)
                }
            }

            process.terminationHandler = { process in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                let output: String
                if collectOutput {
                    let remainingData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    outputBuffer.append(remainingData)
                    let finalData = outputBuffer.snapshot()
                    output = String(decoding: finalData, as: UTF8.self)
                } else {
                    output = ""
                }
                continuation.resume(returning: (process.terminationStatus, output))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
