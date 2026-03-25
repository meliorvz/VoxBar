import Foundation

final class ProcessBridge {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        onStdoutLine: @escaping @Sendable (String) -> Void = { _ in },
        onStderrLine: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> CLIResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutCollector = LineCollector(emit: onStdoutLine)
            let stderrCollector = LineCollector(emit: onStderrLine)

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stdoutCollector.append(data)
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stderrCollector.append(data)
            }

            process.terminationHandler = { process in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdoutCollector.finish()
                stderrCollector.finish()

                let result = CLIResult(
                    stdout: stdoutCollector.output,
                    stderr: stderrCollector.output,
                    exitCode: process.terminationStatus
                )

                if process.terminationStatus == 0 {
                    continuation.resume(returning: result)
                } else {
                    AppLogger.error(
                        "Bridge process failed",
                        metadata: [
                            "command": executableURL.path,
                            "exit_code": String(process.terminationStatus),
                            "stderr": result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                        ]
                    )
                    continuation.resume(throwing: BridgeError.processFailed(result))
                }
            }

            do {
                try process.run()
            } catch {
                AppLogger.error(
                    "Bridge process failed to start",
                    metadata: [
                        "command": executableURL.path,
                        "error": error.localizedDescription,
                    ]
                )
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class LineCollector: @unchecked Sendable {
    private var buffer = Data()
    private(set) var output = ""
    private let emit: @Sendable (String) -> Void

    init(emit: @escaping @Sendable (String) -> Void) {
        self.emit = emit
    }

    func append(_ data: Data) {
        buffer.append(data)
        drainLines()
    }

    func finish() {
        if !buffer.isEmpty, let string = String(data: buffer, encoding: .utf8) {
            emitLine(string)
        }
        buffer.removeAll(keepingCapacity: false)
    }

    private func drainLines() {
        while let newlineRange = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
            buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)
            if let line = String(data: lineData, encoding: .utf8) {
                emitLine(line)
            }
        }
    }

    private func emitLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        output += trimmed + "\n"
        emit(trimmed)
    }
}

enum BridgeError: LocalizedError {
    case missingBridge(URL)
    case processFailed(CLIResult)
    case malformedOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingBridge(let url):
            return "Bridge script not found at \(url.path)"
        case .processFailed(let result):
            return result.stderr.isEmpty
                ? "Generation failed with exit code \(result.exitCode)."
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        case .malformedOutput(let message):
            return message
        }
    }
}
