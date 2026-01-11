import SwiftUI
import AVFoundation
import AVKit
import Combine
import FirebaseFirestore
import CoreLocation

struct WhisperDetailView: View {
    let whisper: Whisper

    @StateObject private var vm: WhisperAttachmentsViewModel
    @State private var audioPlayer: AVPlayer?

    init(whisper: Whisper) {
        self.whisper = whisper
        _vm = StateObject(wrappedValue: WhisperAttachmentsViewModel(whisperId: whisper.id))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text("Whisper")
                        .font(.title2).bold()
                    Text(whisper.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Lat \(String(format: "%.5f", whisper.latitude)), Lng \(String(format: "%.5f", whisper.longitude))")
                        .font(.caption).foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Label("Radius \(Int(whisper.radiusMeters)) m", systemImage: "dot.circle.and.cursorarrow")
                        Label("Unlocks \(whisper.unlockAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "lock.open")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                // Audio
                GroupBox("Audio") {
                    HStack(spacing: 12) {
                        Button {
                            playAudio()
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            audioPlayer?.pause()
                        } label: {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        .buttonStyle(.bordered)

                        Link(destination: whisper.audioURL) {
                            Label("Open URL", systemImage: "link")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // Media
                GroupBox("Media") {
                    if vm.isLoading {
                        HStack { ProgressView(); Text("Loading…") }
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if let err = vm.errorMessage {
                        Text("⚠️ \(err)").font(.footnote).foregroundStyle(.secondary)
                    } else if vm.attachments.isEmpty {
                        Text("No photos")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(vm.attachments) { att in
                                AttachmentRow(att: att)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Whisper Detail")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .onDisappear { audioPlayer?.pause() }
        .onAppear {
            // Optional: make sure video audio routes correctly
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback, options: [.duckOthers])
                try session.setActive(true)
            } catch {
                print("⚠️ audio session:", error.localizedDescription)
            }
        }
    }

    private func playAudio() {
        guard whisper.audioURL.scheme?.hasPrefix("http") == true else { return }
        audioPlayer = AVPlayer(url: whisper.audioURL)
        audioPlayer?.play()
    }
}

private struct AttachmentRow: View {
    let att: Attachment

    // Keep a player alive per row so playback works
    @State private var player: AVPlayer?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if att.isImage {
                AsyncImage(url: att.url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    case .failure:
                        placeholder("Failed to load image")
                    case .empty:
                        progress()
                    @unknown default:
                        progress()
                    }
                }
                .frame(maxWidth: .infinity)

            } else if att.isVideo {
                ZStack {
                    VideoPlayer(player: player)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .onAppear {
                            // Build & retain a player for this row
                            let item = AVPlayerItem(url: att.url)
                            let p = AVPlayer(playerItem: item)
                            p.automaticallyWaitsToMinimizeStalling = true
                            player = p
                            p.play()
                            isLoading = true
                        }
                        .onDisappear {
                            player?.pause()
                            player = nil
                        }

                    if isLoading {
                        ProgressView()
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                // Lightweight spinner control: hide when actually playing
                .task(id: player) {
                    guard let player else { return }
                    // Poll for a short while until playing
                    for _ in 0..<30 {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                        if player.timeControlStatus == .playing { break }
                    }
                    isLoading = false
                }
            }

            HStack(spacing: 12) {
                Label(att.kind.rawValueCap, systemImage: att.isImage ? "photo" : "play.rectangle")
                if let bytes = att.bytes {
                    Text(byteString(bytes))
                }
                if let d = att.durationSec, att.isVideo {
                    Text("\(Int(round(d))) sec")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func progress() -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.blue.opacity(0.08))
            .frame(height: 160)
            .overlay(ProgressView())
    }

    private func placeholder(_ msg: String) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4]))
            .frame(height: 160)
            .overlay(Text(msg).font(.footnote).foregroundStyle(.secondary))
    }

    private func byteString(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024.0
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024.0)
    }
}

// Tiny extension to pretty-case the label
private extension AttachmentKind {
    var rawValueCap: String { rawValue.capitalized }
}
