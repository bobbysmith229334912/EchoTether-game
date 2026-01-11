import AVFoundation
import SwiftUI

final class AudioPreviewPlayer: NSObject, ObservableObject {
    @Published var isLoaded = false
    @Published var isPlaying = false
    @Published var duration: TimeInterval = 0
    @Published var currentTime: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var tick: CADisplayLink?

    /// Load a local audio file (e.g., the temp URL from AudioRecorder)
    func load(url: URL) throws {
        stop()
        let p = try AVAudioPlayer(contentsOf: url)
        p.prepareToPlay()
        p.delegate = self
        player = p
        duration = p.duration
        currentTime = 0
        isLoaded = true
        isPlaying = false
        startTick()
    }

    func playPause() {
        guard let p = player, isLoaded else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
        } else {
            p.play()
            isPlaying = true
        }
    }

    func stop() {
        tick?.invalidate(); tick = nil
        player?.stop()
        player = nil
        isPlaying = false
        isLoaded = false
        duration = 0
        currentTime = 0
    }

    /// Seek in seconds (0...duration)
    func seek(to time: TimeInterval) {
        guard let p = player, isLoaded else { return }
        p.currentTime = max(0, min(time, p.duration))
        currentTime = p.currentTime
    }

    private func startTick() {
        tick?.invalidate()
        tick = CADisplayLink(target: self, selector: #selector(onTick))
        tick?.add(to: .main, forMode: .common)
    }

    @objc private func onTick() {
        guard let p = player, isLoaded else { return }
        currentTime = p.currentTime
        if !p.isPlaying { isPlaying = false }
    }

    deinit { tick?.invalidate() }
}

extension AudioPreviewPlayer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentTime = duration
    }
}
