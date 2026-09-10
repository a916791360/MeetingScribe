@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class MeetingAudioPlayer: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var isAvailable = false

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadedURL: URL?

    func load(url: URL?) {
        guard loadedURL != url else { return }
        stop()
        loadedURL = url
        guard let url else {
            isAvailable = false
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.enableRate = true
            player.rate = playbackRate
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            isAvailable = player.duration > 0
        } catch {
            self.player = nil
            duration = 0
            isAvailable = false
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            stopTimer()
            isPlaying = false
        } else {
            player.play()
            startTimer()
            isPlaying = player.isPlaying
        }
    }

    func skip(by seconds: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, player.currentTime + seconds), player.duration)
        currentTime = player.currentTime
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        player?.rate = rate
    }

    func stop() {
        player?.stop()
        player = nil
        stopTimer()
        isPlaying = false
        currentTime = 0
        duration = 0
        isAvailable = false
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopTimer()
        isPlaying = false
        currentTime = duration
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(updatePlayback),
            userInfo: nil,
            repeats: true
        )
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func updatePlayback() {
        currentTime = player?.currentTime ?? 0
        isPlaying = player?.isPlaying ?? false
    }

}
