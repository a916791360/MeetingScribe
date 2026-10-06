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
    @Published private(set) var unavailableMessage = "暂无可播放音频"

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadedURL: URL?

    func load(url: URL?) {
        guard loadedURL != url || !isAvailable else { return }
        stop()
        guard let url else {
            unavailableMessage = "暂无可播放音频"
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            unavailableMessage = "音频文件不在本机"
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
            if isAvailable {
                loadedURL = url
                unavailableMessage = ""
            } else {
                self.player = nil
                duration = 0
                unavailableMessage = "音频还没准备好"
            }
        } catch {
            self.player = nil
            duration = 0
            isAvailable = false
            unavailableMessage = "音频文件暂时无法播放"
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
        loadedURL = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        stopTimer()
        isPlaying = false
        currentTime = duration
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.updatePlayback() }
        }
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
