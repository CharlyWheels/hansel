import Foundation
import AVFoundation
import Observation

/// Plays one speaker sample at a time from a meeting's recording.
@Observable
@MainActor
final class SpeakerClipPlayer {

    /// The clip playing now, for the UI to show its text and a stop button.
    private(set) var playing: SpeakerClip?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playerURL: URL?
    @ObservationIgnored private var stopTask: Task<Void, Never>?

    /// A little air around the phrase, so the first and last words are not clipped.
    private let padding: Double = 0.25

    func play(_ clip: SpeakerClip, from url: URL) {
        stop()
        do {
            if playerURL != url || player == nil {
                player = try AVAudioPlayer(contentsOf: url)
                playerURL = url
            }
        } catch {
            AppLogger.log("meetings", level: .warning, "speaker_clip_failed: \(error.localizedDescription)")
            return
        }
        guard let player else { return }
        let start = max(0, clip.start - padding)
        let end = min(player.duration, clip.end + padding)
        guard end > start else { return }
        player.currentTime = start
        player.play()
        playing = clip
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(end - start))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.pause()
        playing = nil
    }
}
