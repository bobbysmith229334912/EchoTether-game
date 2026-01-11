import AVFoundation
import SwiftUI

final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordedURL: URL?

    private let session = AVAudioSession.sharedInstance()
    private var recorder: AVAudioRecorder?

    /// Start a new recording to a temp .m4a file (do not upload yet)
    func startRecording() {
        do {
            // Route preview through speaker; allow BT mics; duck others.
            try session.setCategory(.playAndRecord,
                                    mode: .spokenAudio,
                                    options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
            try session.setActive(true)

            // New temp file
            recordedURL = nil
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("echo-\(UUID().uuidString).m4a")

            // CD quality mono AAC
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            rec.prepareToRecord()
            rec.record()
            recorder = rec
            isRecording = true

            print("🎙️ Recording started at:", url.path)
        } catch {
            isRecording = false
            print("❌ Failed to start recording:", error.localizedDescription)
        }
    }

    /// Stop and expose the local file URL for preview
    func stopRecording() {
        guard let rec = recorder else { return }
        rec.stop()
        recorder = nil
        isRecording = false
        recordedURL = rec.url
        print("✅ Recording saved to:", recordedURL?.path ?? "Unknown")

        // Let other audio resume
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Throw away the last take (for “Re-record”)
    func discard() {
        if let url = recordedURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordedURL = nil
        isRecording = false
        recorder = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}
