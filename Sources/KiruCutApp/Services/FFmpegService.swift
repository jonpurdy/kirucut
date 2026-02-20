import Foundation

protocol FFmpegServicing: Sendable {
    func cut(inputURL: URL, outputURL: URL, start: Double, duration: Double, overwriteOutput: Bool) async throws
    func mediaDuration(inputURL: URL) async throws -> Double
}

struct FFmpegService: FFmpegServicing {
    enum ServiceError: LocalizedError {
        case ffmpegNotFound
        case ffprobeNotFound
        case durationUnavailable
        case commandFailed(code: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "ffmpeg was not found in PATH. Install it (for example: brew install ffmpeg)."
            case .ffprobeNotFound:
                return "ffprobe was not found. Install ffmpeg tools (for example: brew install ffmpeg)."
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

    private func resolveFFmpegURL() async throws -> URL {
        let fileManager = FileManager.default

        let pathCandidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]

        for path in pathCandidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for path in pathEnv.split(separator: ":") {
                let candidate = String(path) + "/ffmpeg"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }

        throw ServiceError.ffmpegNotFound
    }

    private func resolveFFprobeURL() async throws -> URL {
        let fileManager = FileManager.default

        if let ffmpegURL = try? await resolveFFmpegURL() {
            let siblingProbe = ffmpegURL.deletingLastPathComponent().appendingPathComponent("ffprobe").path
            if fileManager.isExecutableFile(atPath: siblingProbe) {
                return URL(fileURLWithPath: siblingProbe)
            }
        }

        let pathCandidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]

        for path in pathCandidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for path in pathEnv.split(separator: ":") {
                let candidate = String(path) + "/ffprobe"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }

        throw ServiceError.ffprobeNotFound
    }

    private func runFFmpeg(ffmpegURL: URL, arguments: [String]) async throws {
        let result = try await runProcess(executable: ffmpegURL.path, arguments: arguments)
        guard result.exitCode == 0 else {
            throw ServiceError.commandFailed(code: result.exitCode, output: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func runProcess(
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

            process.terminationHandler = { process in
                let output: String
                if collectOutput {
                    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    output = String(decoding: data, as: UTF8.self)
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
