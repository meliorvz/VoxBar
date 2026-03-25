import Foundation

struct GenerationRunResult {
    let record: GenerationRecord
    let stdout: String
    let stderr: String
}

final class GenerationService {
    private let bridge = ProcessBridge()
    private static let previewPhrase = "The quick brown fox jumps over the lazy dog."

    func listVoices() async throws -> [String] {
        let result = try await bridge.run(
            executableURL: AppPaths.bridgeScript,
            arguments: ["--list-voices-json"]
        )
        let data = Data(result.stdout.utf8)
        return try JSONDecoder().decode(VoiceListPayload.self, from: data).voices
    }

    func generate(
        inputValue: String,
        sourceKind: InputSourceKind,
        voice: String,
        speed: Double,
        titleOverride: String? = nil,
        onProgress: @escaping @Sendable (GenerationProgress) -> Void
    ) async throws -> GenerationRunResult {
        try AppPaths.ensureDirectories()

        let runID = UUID()
        let trimmed = inputValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? Self.deriveTitle(from: trimmed, kind: sourceKind)
        let preview = Self.preview(for: trimmed, kind: sourceKind)
        let relay = ProgressRelay()
        Task { @MainActor in
            relay.value = GenerationProgress(
                phase: .fetching,
                message: sourceKind == .url ? "Fetching article" : "Preparing text",
                detail: sourceKind == .url ? "Downloading and extracting the main article body." : "Skipping extraction and sending text directly."
            )
            onProgress(relay.value)
        }

        let arguments = cliArguments(
            inputValue: trimmed,
            sourceKind: sourceKind,
            voice: voice,
            speed: speed,
            jobID: runID.uuidString,
            title: title
        )

        let result = try await bridge.run(
            executableURL: AppPaths.bridgeScript,
            arguments: arguments,
            onStdoutLine: { line in
                Task { @MainActor in
                    relay.value.logLines = Self.append(line: line, to: relay.value.logLines)
                    if let event = Self.decodeEvent(from: line) {
                        Self.apply(event: event, to: &relay.value)
                    }
                    onProgress(relay.value)
                }
            },
            onStderrLine: { line in
                Task { @MainActor in
                    relay.value.logLines = Self.append(line: "stderr: \(line)", to: relay.value.logLines)
                    relay.value.lastError = line
                    onProgress(relay.value)
                }
            }
        )

        let parsed = try Self.parseCompletion(from: result.stdout)
        let record = GenerationRecord(
            id: runID,
            createdAt: Date(),
            title: parsed.title,
            metadataSummary: parsed.metadataSummary,
            tags: parsed.tags,
            metadataModel: parsed.metadataModel,
            sourceKind: sourceKind,
            sourcePreview: preview,
            voice: voice,
            inputValue: trimmed,
            runDirectory: parsed.jobDirectory,
            textFile: parsed.textPath,
            audioFile: parsed.audioPath,
            summary: parsed.summary
        )

        return GenerationRunResult(record: record, stdout: result.stdout, stderr: result.stderr)
    }

    func previewVoice(voice: String, speed: Double) async throws -> URL {
        try AppPaths.ensureDirectories()

        let jobID = "preview-" + UUID().uuidString
        let prompt = previewPrompt(for: voice)
        let result = try await bridge.run(
            executableURL: AppPaths.bridgeScript,
            arguments: [
                "--json-events",
                "--job-id", jobID,
                "--voice", voice,
                "--speed", String(format: "%.2f", speed),
                "--no-play",
                "--output-dir", AppPaths.previewsRoot.path,
                "--title", "voice-preview-\(voice)",
                "--text", prompt,
            ]
        )

        let parsed = try Self.parseCompletion(from: result.stdout)
        return URL(fileURLWithPath: parsed.audioPath)
    }

    private func cliArguments(
        inputValue: String,
        sourceKind: InputSourceKind,
        voice: String,
        speed: Double,
        jobID: String,
        title: String
    ) -> [String] {
        var arguments: [String] = [
            "--json-events",
            "--job-id", jobID,
            "--voice", voice,
            "--speed", String(format: "%.2f", speed),
            "--no-play",
            "--output-dir", AppPaths.runsRoot.path,
            "--title", title
        ]
        if sourceKind == .url {
            arguments.append(inputValue)
        } else {
            arguments.append(contentsOf: ["--text", inputValue])
        }
        return arguments
    }

    private static func deriveTitle(from input: String, kind: InputSourceKind) -> String {
        if kind == .url {
            return URL(string: input)?.host ?? "article"
        }

        let words = input.split(whereSeparator: { $0.isWhitespace }).prefix(6).map(String.init)
        let title = words.joined(separator: " ")
        return title.isEmpty ? "pasted-text" : title
    }

    private static func preview(for input: String, kind: InputSourceKind) -> String {
        switch kind {
        case .url:
            return input
        case .text:
            return String(input.prefix(120))
        }
    }

    private func previewPrompt(for voice: String) -> String {
        let spokenName = voice.replacingOccurrences(of: "_", with: " ")
        return "This is \(spokenName). \(Self.previewPhrase)"
    }

    private static func decodeEvent(from line: String) -> BridgeEvent? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BridgeEvent.self, from: data)
    }

    private static func apply(event: BridgeEvent, to progress: inout GenerationProgress) {
        switch event.type {
        case "stage":
            progress.message = event.message ?? progress.message
            progress.detail = event.message ?? progress.detail
            if let name = event.name {
                switch name {
                case "input", "fetching_url", "extracting_article":
                    progress.phase = .fetching
                case "synthesizing":
                    progress.phase = .rendering
                case "writing_text", "writing_audio", "playback":
                    progress.phase = .saving
                default:
                    break
                }
            }
            if let total = event.total {
                progress.chunkTotal = total
            }
        case "progress":
            progress.phase = .rendering
            progress.chunkIndex = event.current
            progress.chunkTotal = event.total
            if let current = event.current, let total = event.total {
                progress.message = "Rendering chunk \(current)/\(total)"
            } else {
                progress.message = "Rendering audio"
            }
            progress.detail = event.stage ?? "Kokoro is synthesizing the audio."
        case "result":
            progress.phase = .ready
            progress.message = "Ready"
            if let totalSeconds = event.totalSeconds, let renderSeconds = event.renderSeconds {
                progress.detail = "Total \(Self.format(seconds: totalSeconds)) • Render \(Self.format(seconds: renderSeconds))"
            } else {
                progress.detail = "Generation finished."
            }
            progress.lastError = nil
        case "error":
            progress.phase = .failed
            progress.message = "Generation failed"
            progress.detail = event.message ?? "The bridge reported an error."
            progress.lastError = event.message
        default:
            break
        }
    }

    private static func parseCompletion(from stdout: String) throws -> ParsedCompletion {
        var lastResult: BridgeEvent?
        var lastError: BridgeEvent?

        for rawLine in stdout.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let event = decodeEvent(from: line) else { continue }
            if event.type == "result" {
                lastResult = event
            } else if event.type == "error" {
                lastError = event
            }
        }

        if let lastError, lastResult == nil {
            throw BridgeError.malformedOutput(lastError.message ?? "The bridge reported an error.")
        }

        guard
            let result = lastResult,
            let title = result.title,
            let jobDirectory = result.jobDir,
            let textPath = result.textPath,
            let audioPath = result.audioPath
        else {
            throw BridgeError.malformedOutput("The bridge did not return the generated file paths.")
        }

        let summary: String
        if let totalSeconds = result.totalSeconds, let renderSeconds = result.renderSeconds {
            summary = "Total \(format(seconds: totalSeconds)) | Render \(format(seconds: renderSeconds))"
        } else {
            summary = "Completed"
        }

        return ParsedCompletion(
            title: title,
            jobDirectory: jobDirectory,
            textPath: textPath,
            audioPath: audioPath,
            summary: summary,
            metadataSummary: result.metadataSummary,
            tags: result.metadataTags ?? [],
            metadataModel: result.metadataModel
        )
    }

    private static func append(line: String, to lines: [String]) -> [String] {
        var updated = lines
        updated.append(line)
        if updated.count > 12 {
            updated.removeFirst(updated.count - 12)
        }
        return updated
    }

    private static func format(seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds / 60)
        let remainder = seconds - (Double(minutes) * 60)
        return "\(minutes)m \(String(format: "%.1fs", remainder))"
    }
}

@MainActor
private final class ProgressRelay: @unchecked Sendable {
    var value = GenerationProgress()
}

private struct VoiceListPayload: Decodable {
    let voices: [String]
}

private struct BridgeEvent: Decodable {
    let type: String
    let name: String?
    let stage: String?
    let message: String?
    let current: Int?
    let total: Int?
    let title: String?
    let jobDir: String?
    let manifestPath: String?
    let textPath: String?
    let audioPath: String?
    let metadataSummary: String?
    let metadataTags: [String]?
    let metadataModel: String?
    let inputPrepSeconds: Double?
    let renderSeconds: Double?
    let totalSeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case stage
        case message
        case current
        case total
        case title
        case jobDir = "job_dir"
        case manifestPath = "manifest_path"
        case textPath = "text_path"
        case audioPath = "audio_path"
        case metadataSummary = "metadata_summary"
        case metadataTags = "metadata_tags"
        case metadataModel = "metadata_model"
        case inputPrepSeconds = "input_prep_seconds"
        case renderSeconds = "tts_render_seconds"
        case totalSeconds = "total_seconds"
    }
}

private struct ParsedCompletion {
    let title: String
    let jobDirectory: String
    let textPath: String
    let audioPath: String
    let summary: String
    let metadataSummary: String?
    let tags: [String]
    let metadataModel: String?
}
