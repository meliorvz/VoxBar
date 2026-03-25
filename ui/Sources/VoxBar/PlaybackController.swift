@preconcurrency import AVFoundation
import Foundation

@MainActor
final class PlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTitle: String?
    @Published private(set) var currentSubtitle: String?
    @Published private(set) var playbackError: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func loadAndPlay(url: URL, title: String, subtitle: String? = nil) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            currentTime = 0
            currentTitle = title
            currentSubtitle = subtitle
            playbackError = nil
            player.play()
            isPlaying = true
            startTimer()
        } catch {
            playbackError = error.localizedDescription
        }
    }

    func togglePlayPause(url: URL? = nil, title: String? = nil, subtitle: String? = nil) {
        if let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
                startTimer()
            }
            return
        }

        guard let url, let title else { return }
        loadAndPlay(url: url, title: title, subtitle: subtitle)
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        currentTitle = nil
        currentSubtitle = nil
        stopTimer()
    }

    func seek(by delta: TimeInterval) {
        guard let player else { return }
        let newTime = min(max(player.currentTime + delta, 0), player.duration)
        player.currentTime = newTime
        currentTime = newTime
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        let newTime = min(max(player.duration * fraction, 0), player.duration)
        player.currentTime = newTime
        currentTime = newTime
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTimer()
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                self.duration = player.duration
                self.isPlaying = player.isPlaying
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
