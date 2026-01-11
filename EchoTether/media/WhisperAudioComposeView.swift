import SwiftUI
import AVFoundation

/// Screen for recording an audio whisper, previewing it, and uploading.
/// - Requirements:
///   - AudioRecorder (Step 1)
///   - AudioPreviewPlayer (Step 2)
///   - MediaUploadService.uploadAudio(...) (Step 3)
struct WhisperAudioComposeView: View {
    // Inject from the caller
    let whisperId: String
    let ownerId: String

    @StateObject private var rec = AudioRecorder()
    @StateObject private var player = AudioPreviewPlayer()

    private enum Phase { case idle, recording, preview }
    @State private var phase: Phase = .idle

    @State private var isUploading = false
    @State private var errorMsg: String?
    @State private var successMsg: String?

    var body: some View {
        VStack(spacing: 18) {
            switch phase {
            case .idle:
                VStack(spacing: 8) {
                    Text("Ready to record your whisper")
                        .font(.headline)
                    Button {
                        rec.startRecording()
                        phase = .recording
                    } label: {
                        Label("Start Recording", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }

            case .recording:
                VStack(spacing: 12) {
                    Text("🎙️ Recording…")
                        .font(.headline)
                    Button {
                        rec.stopRecording()
                        if let url = rec.recordedURL {
                            do { try player.load(url: url) }
                            catch { errorMsg = error.localizedDescription }
                            phase = .preview
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                }

            case .preview:
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Button {
                            player.playPause()
                        } label: {
                            Label(player.isPlaying ? "Pause" : "Play",
                                  systemImage: player.isPlaying ? "pause.circle" : "play.circle")
                        }
                        .buttonStyle(.bordered)

                        Slider(
                            value: Binding(
                                get: { player.currentTime },
                                set: { player.seek(to: $0) }
                            ),
                            in: 0...(max(player.duration, 1))
                        )

                        Text("\(fmt(player.currentTime)) / \(fmt(player.duration))")
                            .font(.caption)
                            .monospacedDigit()
                            .frame(minWidth: 90, alignment: .trailing)
                    }

                    HStack {
                        Button(role: .destructive) {
                            player.stop()
                            rec.discard()         // delete temp file
                            phase = .idle
                            errorMsg = nil
                            successMsg = nil
                        } label: {
                            Label("Re-record", systemImage: "arrow.counterclockwise.circle")
                        }

                        Spacer()

                        if let url = rec.recordedURL {
                            Button {
                                Task { await upload(url: url) }
                            } label: {
                                if isUploading {
                                    ProgressView()
                                } else {
                                    Label("Upload Whisper", systemImage: "icloud.and.arrow.up")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isUploading)
                        }
                    }
                }
            }

            if let s = successMsg {
                Text(s).foregroundStyle(.green).font(.footnote)
            }
            if let e = errorMsg {
                Text(e).foregroundStyle(.red).font(.footnote)
            }
        }
        .padding()
        .navigationTitle("Audio Whisper")
        .onDisappear {
            // Clean up if user bails mid-flow
            player.stop()
            if phase != .preview { rec.discard() }
        }
    }

    // MARK: - Helpers

    private func upload(url: URL) async {
        guard !isUploading else { return }
        isUploading = true
        errorMsg = nil
        successMsg = nil
        do {
            _ = try await MediaUploadService.shared.uploadAudio(
                at: url,
                whisperId: whisperId,
                ownerId: ownerId
            )
            // Remove local temp after success
            try? FileManager.default.removeItem(at: url)
            rec.recordedURL = nil
            successMsg = "✅ Uploaded!"
        } catch {
            errorMsg = error.localizedDescription
        }
        isUploading = false
    }

    private func fmt(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
