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
    @Published private(set) var isBufferingStream = false
    @Published private(set) var canSeek = true

    private var filePlayer: AVAudioPlayer?
    private var streamPlayer: AVQueuePlayer?
    private var timer: Timer?
    private var streamChunks: [BufferedChunk] = []
    private var streamChunkDurations: [ObjectIdentifier: TimeInterval] = [:]
    private var streamObserverTokens: [ObjectIdentifier: NSObjectProtocol] = [:]
    private var streamBufferedDuration: TimeInterval = 0
    private var streamConsumedDuration: TimeInterval = 0
    private var streamFirstChunkAt: Date?
    private var streamStarted = false
    private var streamFinished = false
    private var streamWaitingForBuffer = false
    private var streamUserPaused = false
    private var finalStreamURL: URL?

    private let initialBufferFloor: TimeInterval = 16
    private let generousBufferFloor: TimeInterval = 26
    private let resumeBufferFloor: TimeInterval = 10
    private let lowBufferFloor: TimeInterval = 4
    private let startRateFloor: Double = 1.12

    var isBufferedSessionActive: Bool {
        streamPlayer != nil
    }

    func loadAndPlay(url: URL, title: String, subtitle: String? = nil) {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            filePlayer = player
            duration = player.duration
            currentTime = 0
            currentTitle = title
            currentSubtitle = subtitle
            playbackError = nil
            canSeek = true
            isBufferingStream = false
            player.play()
            isPlaying = true
            startTimer()
        } catch {
            playbackError = error.localizedDescription
            AppLogger.error(
                "Playback failed",
                metadata: [
                    "audio_path": url.path,
                    "title": title,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    func beginBufferedPlayback(title: String, subtitle: String? = nil) {
        stop()
        let player = AVQueuePlayer()
        player.actionAtItemEnd = .advance
        streamPlayer = player
        currentTitle = title
        currentSubtitle = subtitle
        playbackError = nil
        currentTime = 0
        duration = 0
        canSeek = false
        isBufferingStream = true
        streamChunks = []
        streamBufferedDuration = 0
        streamConsumedDuration = 0
        streamStarted = false
        streamFinished = false
        streamWaitingForBuffer = false
        streamUserPaused = false
        streamFirstChunkAt = nil
        finalStreamURL = nil
        startTimer()
        AppLogger.info("Buffered playback session prepared", metadata: ["title": title])
    }

    func appendBufferedChunk(url: URL, duration chunkDuration: TimeInterval) {
        guard let streamPlayer else { return }
        if streamFirstChunkAt == nil {
            streamFirstChunkAt = Date()
        }

        let chunk = BufferedChunk(url: url, duration: chunkDuration)
        streamChunks.append(chunk)
        enqueueBufferedChunk(chunk, on: streamPlayer)
        streamBufferedDuration += chunkDuration
        duration = max(duration, streamBufferedDuration)
        canSeek = true
        maybeStartOrResumeBufferedPlayback()
    }

    @discardableResult
    func completeBufferedPlayback(finalURL: URL, title: String, subtitle: String? = nil) -> Bool {
        guard streamPlayer != nil else { return false }
        currentTitle = title
        currentSubtitle = subtitle
        finalStreamURL = finalURL
        streamFinished = true
        canSeek = true
        isBufferingStream = false

        if !streamStarted {
            loadAndPlay(url: finalURL, title: title, subtitle: subtitle)
            return true
        }

        maybeStartOrResumeBufferedPlayback()
        AppLogger.info(
            "Buffered playback finalized",
            metadata: [
                "audio_path": finalURL.path,
                "title": title,
            ]
        )
        return true
    }

    func abortBufferedPlayback(error: String) {
        guard streamPlayer != nil else { return }
        playbackError = error
        AppLogger.error("Buffered playback aborted", metadata: ["error": error])
        stop()
    }

    func togglePlayPause(url: URL? = nil, title: String? = nil, subtitle: String? = nil) {
        if let filePlayer {
            if filePlayer.isPlaying {
                filePlayer.pause()
                isPlaying = false
            } else {
                filePlayer.play()
                isPlaying = true
                startTimer()
            }
            return
        }

        if let streamPlayer {
            if isPlaying {
                streamPlayer.pause()
                streamUserPaused = true
                isPlaying = false
                isBufferingStream = false
            } else {
                streamUserPaused = false
                maybeStartOrResumeBufferedPlayback(forceUserResume: true)
            }
            return
        }

        guard let url, let title else { return }
        loadAndPlay(url: url, title: title, subtitle: subtitle)
    }

    func stop() {
        filePlayer?.stop()
        filePlayer = nil

        streamPlayer?.pause()
        streamPlayer?.removeAllItems()
        streamPlayer = nil
        clearStreamObservers()

        isPlaying = false
        currentTime = 0
        duration = 0
        currentTitle = nil
        currentSubtitle = nil
        playbackError = nil
        isBufferingStream = false
        canSeek = true

        streamBufferedDuration = 0
        streamConsumedDuration = 0
        streamChunks = []
        streamFirstChunkAt = nil
        streamStarted = false
        streamFinished = false
        streamWaitingForBuffer = false
        streamUserPaused = false
        finalStreamURL = nil

        stopTimer()
    }

    func seek(by delta: TimeInterval) {
        if let filePlayer {
            let newTime = min(max(filePlayer.currentTime + delta, 0), filePlayer.duration)
            filePlayer.currentTime = newTime
            currentTime = newTime
            return
        }

        if let finalStreamURL {
            let target = min(max(currentTime + delta, 0), duration)
            switchBufferedPlaybackToFile(at: target, url: finalStreamURL)
            return
        }

        seekBufferedPlayback(to: currentTime + delta)
    }

    func seek(to fraction: Double) {
        if let filePlayer {
            let newTime = min(max(filePlayer.duration * fraction, 0), filePlayer.duration)
            filePlayer.currentTime = newTime
            currentTime = newTime
            return
        }

        if let finalStreamURL {
            let newTime = min(max(duration * fraction, 0), duration)
            switchBufferedPlaybackToFile(at: newTime, url: finalStreamURL)
            return
        }

        seekBufferedPlayback(to: duration * fraction)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isPlaying = false
            stopTimer()
        }
    }

    private func handleStreamItemEnded(_ item: AVPlayerItem) {
        let identifier = ObjectIdentifier(item)
        let chunkDuration = streamChunkDurations.removeValue(forKey: identifier) ?? 0
        if let token = streamObserverTokens.removeValue(forKey: identifier) {
            NotificationCenter.default.removeObserver(token)
        }

        streamConsumedDuration += chunkDuration
        currentTime = min(streamConsumedDuration, streamBufferedDuration)

        guard let streamPlayer else { return }
        if streamPlayer.items().isEmpty {
            if streamFinished {
                isPlaying = false
                isBufferingStream = false
            } else {
                streamWaitingForBuffer = true
                isPlaying = false
                isBufferingStream = true
                AppLogger.info(
                    "Buffered playback waiting for more audio",
                    metadata: [
                        "buffered_ahead": String(format: "%.2f", max(streamBufferedDuration - currentTime, 0)),
                    ]
                )
            }
        }
    }

    private func seekBufferedPlayback(to targetTime: TimeInterval) {
        guard streamPlayer != nil, !streamChunks.isEmpty else { return }

        let upperBound = max(streamBufferedDuration - 0.001, 0)
        let clampedTarget = min(max(targetTime, 0), upperBound)
        rebuildBufferedPlayback(at: clampedTarget, shouldResume: isPlaying)
    }

    private func rebuildBufferedPlayback(at targetTime: TimeInterval, shouldResume: Bool) {
        guard let oldPlayer = streamPlayer else { return }

        let anchor = bufferedChunkAnchor(for: targetTime)

        oldPlayer.pause()
        oldPlayer.removeAllItems()
        clearStreamObservers()

        let player = AVQueuePlayer()
        player.actionAtItemEnd = .advance
        streamPlayer = player
        streamConsumedDuration = anchor.startTime
        streamStarted = true
        streamWaitingForBuffer = false
        streamFinished = false
        currentTime = targetTime
        duration = max(duration, streamBufferedDuration)
        canSeek = true
        isBufferingStream = shouldResume ? false : isBufferingStream

        for chunk in streamChunks[anchor.startIndex...] {
            enqueueBufferedChunk(chunk, on: player)
        }

        if anchor.offset > 0 {
            player.seek(
                to: CMTime(seconds: anchor.offset, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }

        if shouldResume {
            player.play()
            isPlaying = true
            isBufferingStream = false
        } else {
            isPlaying = false
        }
        startTimer()
    }

    private func bufferedChunkAnchor(for time: TimeInterval) -> (startIndex: Int, startTime: TimeInterval, offset: TimeInterval) {
        var accumulated: TimeInterval = 0

        for (index, chunk) in streamChunks.enumerated() {
            let nextBoundary = accumulated + chunk.duration
            if time < nextBoundary || index == streamChunks.count - 1 {
                return (index, accumulated, max(time - accumulated, 0))
            }
            accumulated = nextBoundary
        }

        return (0, 0, 0)
    }

    private func enqueueBufferedChunk(_ chunk: BufferedChunk, on player: AVQueuePlayer) {
        let item = AVPlayerItem(url: chunk.url)
        let identifier = ObjectIdentifier(item)
        streamChunkDurations[identifier] = chunk.duration
        streamObserverTokens[identifier] = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            guard let self, let item else { return }
            Task { @MainActor in
                self.handleStreamItemEnded(item)
            }
        }
        player.insert(item, after: nil)
    }

    private func maybeStartOrResumeBufferedPlayback(forceUserResume: Bool = false) {
        guard let streamPlayer else { return }
        if streamUserPaused && !forceUserResume {
            return
        }

        let bufferedAhead = max(streamBufferedDuration - currentTime, 0)
        let shouldStartNow = shouldStartBufferedPlayback(bufferedAhead: bufferedAhead)
        let shouldResumeNow = streamFinished || bufferedAhead >= resumeBufferFloor

        if !streamStarted {
            if shouldStartNow || forceUserResume {
                streamPlayer.play()
                streamStarted = true
                streamWaitingForBuffer = false
                isPlaying = true
                isBufferingStream = false
                AppLogger.info(
                    "Buffered playback started",
                    metadata: [
                        "buffered_seconds": String(format: "%.2f", bufferedAhead),
                        "production_rate": String(format: "%.2f", audioProductionRate),
                    ]
                )
            } else {
                isPlaying = false
                isBufferingStream = true
            }
            return
        }

        if streamWaitingForBuffer && shouldResumeNow {
            streamPlayer.play()
            streamWaitingForBuffer = false
            isPlaying = true
            isBufferingStream = false
            AppLogger.info(
                "Buffered playback resumed",
                metadata: [
                    "buffered_seconds": String(format: "%.2f", bufferedAhead),
                ]
            )
        } else if forceUserResume && !streamWaitingForBuffer {
            streamPlayer.play()
            isPlaying = true
            isBufferingStream = false
        }
    }

    private func shouldStartBufferedPlayback(bufferedAhead: TimeInterval) -> Bool {
        if streamFinished {
            return bufferedAhead > 0
        }
        if bufferedAhead >= generousBufferFloor {
            return true
        }
        return bufferedAhead >= initialBufferFloor && audioProductionRate >= startRateFloor
    }

    private var audioProductionRate: Double {
        guard let streamFirstChunkAt else { return 0 }
        let elapsed = max(Date().timeIntervalSince(streamFirstChunkAt), 0.1)
        return streamBufferedDuration / elapsed
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func tick() {
        if let filePlayer {
            currentTime = filePlayer.currentTime
            duration = filePlayer.duration
            isPlaying = filePlayer.isPlaying
            return
        }

        guard let streamPlayer else { return }

        let itemTime = streamPlayer.currentItem?.currentTime().seconds ?? 0
        let normalizedItemTime = itemTime.isFinite && itemTime >= 0 ? itemTime : 0
        currentTime = min(streamConsumedDuration + normalizedItemTime, max(duration, streamBufferedDuration))
        duration = max(duration, streamBufferedDuration)
        isPlaying = streamPlayer.rate > 0

        let bufferedAhead = max(streamBufferedDuration - currentTime, 0)
        if streamStarted,
           !streamFinished,
           !streamUserPaused,
           !streamWaitingForBuffer,
           isPlaying,
           bufferedAhead < lowBufferFloor {
            streamPlayer.pause()
            streamWaitingForBuffer = true
            isPlaying = false
            isBufferingStream = true
            AppLogger.info(
                "Buffered playback paused for rebuffer",
                metadata: [
                    "buffered_seconds": String(format: "%.2f", bufferedAhead),
                    "production_rate": String(format: "%.2f", audioProductionRate),
                ]
            )
        }

        if streamWaitingForBuffer {
            maybeStartOrResumeBufferedPlayback()
        }
    }

    private func switchBufferedPlaybackToFile(at time: TimeInterval, url: URL) {
        let shouldResume = isPlaying
        let title = currentTitle
        let subtitle = currentSubtitle
        clearStreamObservers()
        streamPlayer?.pause()
        streamPlayer?.removeAllItems()
        streamPlayer = nil
        streamStarted = false
        streamWaitingForBuffer = false
        streamUserPaused = false
        streamFinished = true
        isBufferingStream = false

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.currentTime = min(max(time, 0), player.duration)
            filePlayer = player
            duration = player.duration
            currentTime = player.currentTime
            currentTitle = title
            currentSubtitle = subtitle
            canSeek = true
            if shouldResume {
                player.play()
                isPlaying = true
            } else {
                isPlaying = false
            }
            AppLogger.info(
                "Buffered playback switched to final file",
                metadata: [
                    "audio_path": url.path,
                    "time": String(format: "%.2f", currentTime),
                ]
            )
        } catch {
            playbackError = error.localizedDescription
            AppLogger.error(
                "Buffered playback switch failed",
                metadata: [
                    "audio_path": url.path,
                    "error": error.localizedDescription,
                ]
            )
        }
    }

    private func clearStreamObservers() {
        for token in streamObserverTokens.values {
            NotificationCenter.default.removeObserver(token)
        }
        streamObserverTokens.removeAll(keepingCapacity: false)
        streamChunkDurations.removeAll(keepingCapacity: false)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

private struct BufferedChunk {
    let url: URL
    let duration: TimeInterval
}
