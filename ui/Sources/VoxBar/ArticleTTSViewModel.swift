import Foundation

@MainActor
final class ArticleTTSViewModel: ObservableObject {
    static let preferredDefaultVoice = "af_alloy"
    static let minSpeed = 0.5
    static let maxSpeed = 1.5
    static let speedStep = 0.05
    static let maxFavoriteSettings = 5

    @Published var inputText: String
    @Published var selectedVoice: String
    @Published var selectedSpeed: Double
    @Published var favoriteSettings: [FavoriteVoiceSetting]
    @Published var availableVoices: [String] = []
    @Published var isLoadingVoices = false
    @Published var isGenerating = false
    @Published var previewingVoiceID: String?
    @Published var progress = GenerationProgress()
    @Published var history: [GenerationRecord]
    @Published var selectedRecordID: GenerationRecord.ID?

    let playback = PlaybackController()

    private let historyStore = HistoryStore()
    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        inputText = defaults.string(forKey: "lastInput") ?? ""
        let savedVoice = defaults.string(forKey: "defaultVoice")
        let savedSpeed = defaults.object(forKey: "defaultSpeed") as? Double ?? 1.0
        selectedSpeed = Self.normalizedSpeed(savedSpeed)
        if let data = defaults.data(forKey: "favoriteVoiceSettings"),
           let decoded = try? decoder.decode([FavoriteVoiceSetting].self, from: data) {
            favoriteSettings = decoded
        } else {
            favoriteSettings = []
        }
        if let savedVoice, savedVoice != "af_sarah" {
            selectedVoice = savedVoice
        } else {
            selectedVoice = Self.preferredDefaultVoice
            defaults.set(Self.preferredDefaultVoice, forKey: "defaultVoice")
        }
        history = historyStore.load()
        if let first = history.first {
            selectedRecordID = first.id
        }
        defaults.set(selectedSpeed, forKey: "defaultSpeed")
    }

    func onAppear() {
        loadVoices()
    }

    func loadVoices() {
        guard !isLoadingVoices else { return }
        isLoadingVoices = true

        Task {
            let service = GenerationService()
            do {
                let voices = try await service.listVoices()
                availableVoices = voices
                if voices.contains(Self.preferredDefaultVoice) {
                    if defaults.string(forKey: "defaultVoice") == nil || selectedVoice == "af_sarah" {
                        selectedVoice = Self.preferredDefaultVoice
                        defaults.set(Self.preferredDefaultVoice, forKey: "defaultVoice")
                    }
                } else if !voices.contains(selectedVoice), let first = voices.first {
                    selectedVoice = first
                    defaults.set(first, forKey: "defaultVoice")
                }
            } catch {
                progress.lastError = error.localizedDescription
                progress.message = "Voice load failed"
                progress.detail = error.localizedDescription
            }
            isLoadingVoices = false
        }
    }

    func generate() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            progress = GenerationProgress(phase: .failed, message: "Input required", detail: "Paste a URL or text before generating.", lastError: "Empty input")
            return
        }

        defaults.set(trimmed, forKey: "lastInput")
        defaults.set(selectedVoice, forKey: "defaultVoice")
        defaults.set(selectedSpeed, forKey: "defaultSpeed")

        isGenerating = true
        progress = GenerationProgress(
            phase: .fetching,
            message: trimmed.looksLikeURL ? "Fetching article" : "Preparing text",
            detail: trimmed.looksLikeURL ? "Downloading and extracting the main article body." : "Rendering the pasted text directly."
        )

        Task {
            let service = GenerationService()
            do {
                let result = try await service.generate(
                    inputValue: trimmed,
                    sourceKind: trimmed.looksLikeURL ? .url : .text,
                    voice: selectedVoice,
                    speed: selectedSpeed
                ) { [weak self] update in
                    Task { @MainActor in
                        self?.progress = update
                    }
                }

                history.insert(result.record, at: 0)
                historyStore.save(history)
                play(result.record)
                progress.phase = .ready
                progress.message = "Ready"
                progress.detail = "Saved and playing \(result.record.audioURL.lastPathComponent)"
            } catch {
                progress.phase = .failed
                progress.message = "Generation failed"
                progress.detail = error.localizedDescription
                progress.lastError = error.localizedDescription
            }
            isGenerating = false
        }
    }

    func delete(_ record: GenerationRecord) {
        if selectedRecordID == record.id {
            playback.stop()
        }

        historyStore.delete(record)
        history.removeAll { $0.id == record.id }
        historyStore.save(history)

        if selectedRecordID == record.id {
            selectedRecordID = history.first?.id
        }
    }

    func play(_ record: GenerationRecord) {
        selectedRecordID = record.id
        playback.loadAndPlay(
            url: record.audioURL,
            title: record.title,
            subtitle: playbackSubtitle(for: record)
        )
    }

    func togglePlayback() {
        if selectedRecord == nil, playback.currentTitle != nil {
            playback.togglePlayPause()
            return
        }

        guard let selected = selectedRecord else { return }
        playback.togglePlayPause(
            url: selected.audioURL,
            title: selected.title,
            subtitle: playbackSubtitle(for: selected)
        )
    }

    func rewind() {
        playback.seek(by: -15)
    }

    func skipForward() {
        playback.seek(by: 30)
    }

    func refreshSelection() {
        if selectedRecord == nil {
            selectedRecordID = history.first?.id
        }
    }

    func setSelectedVoice(_ voice: String) {
        selectedVoice = voice
        defaults.set(voice, forKey: "defaultVoice")
    }

    func setSelectedSpeed(_ speed: Double) {
        selectedSpeed = Self.normalizedSpeed(speed)
        defaults.set(selectedSpeed, forKey: "defaultSpeed")
    }

    func applyFavorite(_ favorite: FavoriteVoiceSetting) {
        setSelectedVoice(favorite.voice)
        setSelectedSpeed(favorite.speed)
    }

    func toggleFavoriteCurrentSetting() {
        let current = FavoriteVoiceSetting(voice: selectedVoice, speed: selectedSpeed)
        if let existingIndex = favoriteSettings.firstIndex(of: current) {
            favoriteSettings.remove(at: existingIndex)
        } else {
            favoriteSettings.removeAll { $0.voice == current.voice && $0.speed == current.speed }
            favoriteSettings.insert(current, at: 0)
            if favoriteSettings.count > Self.maxFavoriteSettings {
                favoriteSettings = Array(favoriteSettings.prefix(Self.maxFavoriteSettings))
            }
        }
        persistFavoriteSettings()
    }

    func removeFavorite(_ favorite: FavoriteVoiceSetting) {
        favoriteSettings.removeAll { $0 == favorite }
        persistFavoriteSettings()
    }

    func decreaseSpeed() {
        setSelectedSpeed(selectedSpeed - Self.speedStep)
    }

    func increaseSpeed() {
        setSelectedSpeed(selectedSpeed + Self.speedStep)
    }

    func previewVoice(_ voice: String) {
        guard previewingVoiceID == nil else { return }

        previewingVoiceID = voice
        progress.lastError = nil

        Task {
            let service = GenerationService()
            do {
                let url = try await service.previewVoice(voice: voice, speed: selectedSpeed)
                let profile = VoiceProfile(id: voice)
                playback.loadAndPlay(
                    url: url,
                    title: "\(profile.displayName) Preview",
                    subtitle: "\(profile.languageLabel) • \(Self.speedLabel(for: selectedSpeed))"
                )
            } catch {
                progress.phase = .failed
                progress.message = "Voice preview failed"
                progress.detail = error.localizedDescription
                progress.lastError = error.localizedDescription
            }
            previewingVoiceID = nil
        }
    }

    var selectedRecord: GenerationRecord? {
        guard let selectedRecordID else { return history.first } // fallback keeps controls usable
        return history.first(where: { $0.id == selectedRecordID }) ?? history.first
    }

    var selectedSpeedLabel: String {
        Self.speedLabel(for: selectedSpeed)
    }

    var currentSettingIsFavorited: Bool {
        favoriteSettings.contains { $0.voice == selectedVoice && $0.speed == selectedSpeed }
    }

    private static func normalizedSpeed(_ value: Double) -> Double {
        let clamped = min(max(value, minSpeed), maxSpeed)
        let stepped = (clamped / speedStep).rounded() * speedStep
        return min(max(stepped, minSpeed), maxSpeed)
    }

    private static func speedLabel(for value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.1fx", value)
        }
        return String(format: "%.2fx", value)
    }

    private func playbackSubtitle(for record: GenerationRecord) -> String {
        let profile = VoiceProfile(id: record.voice)
        let sourceLabel = record.sourceKind == .url ? "Link" : "Text"
        return "\(profile.displayName) • \(sourceLabel)"
    }

    private func persistFavoriteSettings() {
        if let data = try? encoder.encode(favoriteSettings) {
            defaults.set(data, forKey: "favoriteVoiceSettings")
        }
    }
}

private extension String {
    var looksLikeURL: Bool {
        lowercased().hasPrefix("http://") || lowercased().hasPrefix("https://")
    }
}
