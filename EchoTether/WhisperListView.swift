import SwiftUI
import AVFoundation
import AVKit
import Combine
import FirebaseFirestore
import CoreLocation

struct WhisperListView: View {
    @State private var whispers: [Whisper] = []
    @StateObject private var locationManager = LocationManager()

    // AVPlayer for streaming (kept in case you later want inline controls)
    @State private var player: AVPlayer?

    // 🔵 Media badge flags
    @State private var mediaFlags: [String: Bool] = [:]
    @State private var isLoading = false

    // ▶️ Visible player overlay
    @State private var showPlayer = false
    @State private var currentURL: URL?

    var body: some View {
        NavigationStack {
            List {
                // -- Where you are (uses LocationManager.lastLocation)
                Section {
                    if let loc = locationManager.lastLocation {
                        Text("📡 You: \(String(format: "%.5f", loc.coordinate.latitude)), \(String(format: "%.5f", loc.coordinate.longitude))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("📡 Getting location…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // -- Only show whispers that are currently unlocked at this location
                ForEach(whispers.filter { w in
                    w.isUnlocked(for: locationManager.lastLocation)    // NOTE: method should accept CLLocation?
                }) { whisper in
                    HStack(alignment: .top, spacing: 12) {

                        // Leading dot: blue if has media, green if audio-only
                        Circle()
                            .fill((mediaFlags[whisper.id] ?? false) ? Color.blue : Color.green)
                            .frame(width: 10, height: 10)
                            .padding(.top, 6)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Text("📍 \(String(format: "%.5f", whisper.latitude)), \(String(format: "%.5f", whisper.longitude))")
                                    .font(.subheadline)
                                    .lineLimit(1)

                                if mediaFlags[whisper.id] == true {
                                    Label("Media", systemImage: "photo.on.rectangle")
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.12), in: Capsule())
                                }
                            }

                            Text("🕓 Unlocked at: \(whisper.unlockAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                Button("▶️ Play Whisper") {
                                    currentURL = whisper.audioURL
                                    showPlayer = true
                                }
                                .buttonStyle(.borderedProminent)

                                NavigationLink("Info") {
                                    WhisperDetailView(whisper: whisper)
                                }
                                .buttonStyle(.bordered)
                            }
                            .font(.caption)
                            .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle("🗃️ Nearby Whispers")
            .overlay { if isLoading { ProgressView().controlSize(.large) } }
            .task { await refresh() }
            .refreshable { await refresh() }
        }
        // start/stop GPS only while this screen is visible
        .onAppear { locationManager.start() }
        .onDisappear { locationManager.stop() }

        // Full-screen player overlay
        .sheet(isPresented: $showPlayer) {
            if let url = currentURL {
                WhisperPlayerView(url: url)
                    .ignoresSafeArea()
            }
        }
    }


    // MARK: - Data
    private func refresh() async {
        await MainActor.run { isLoading = true }
        defer { Task { await MainActor.run { isLoading = false } } }

        let db = Firestore.firestore()
        do {
            let snap = try await db.collection("whispers").getDocuments()
            let list = snap.documents
                .compactMap { Whisper(id: $0.documentID, data: $0.data()) }
                .filter { !$0.isDeleted }

            await MainActor.run { self.whispers = list }
            await fetchMediaFlags(for: list)
        } catch {
            print("❌ Fetch error: \(error.localizedDescription)")
        }
    }

    /// Quick “has any attachments?” probe per whisper (limit 1 per subcollection)
    private func fetchMediaFlags(for list: [Whisper]) async {
        let db = FirebaseFirestore.Firestore.firestore()
        await withTaskGroup(of: (String, Bool)?.self) { group in
            for w in list {
                group.addTask {
                    do {
                        let snap = try await db.collection("whispers")
                            .document(w.id)
                            .collection("attachments")
                            .limit(to: 1)
                            .getDocuments()
                        return (w.id, !snap.documents.isEmpty)
                    } catch {
                        print("⚠️ attachments check failed for \(w.id): \(error.localizedDescription)")
                        return (w.id, false)
                    }
                }
            }
            var flags: [String: Bool] = [:]
            for await pair in group {
                if let (id, hasAny) = pair {
                    flags[id] = hasAny
                }
            }
            await MainActor.run { self.mediaFlags = flags }
        }
    }
}

// MARK: - Full-screen player with buffering spinner + error surfacing
private struct WhisperPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var errorText: String?

    // Combine KVO tokens
    @State private var statusCancellable: AnyCancellable?
    @State private var timeCtrlCancellable: AnyCancellable?

    var body: some View {
        ZStack {
            VideoPlayer(player: player)
                .onAppear(perform: setup)
                .onDisappear(perform: teardown)

            if isLoading {
                Color.black.opacity(0.35).ignoresSafeArea()
                ProgressView("Loading…")
                    .padding(12)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            if let errorText {
                VStack {
                    Spacer()
                    Text("⚠️ \(errorText)")
                        .font(.footnote)
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.red.opacity(0.85), in: Capsule())
                        .padding(.bottom, 24)
                }
                .transition(.opacity)
            }
        }
    }

    private func setup() {
        // ATS sanity: VideoPlayer needs HTTPS
        guard url.scheme?.lowercased() == "https" else {
            isLoading = false
            errorText = "Blocked by ATS (URL must be https)."
            return
        }

        // Preflight: confirm the asset is playable on device (codec/container)
        let asset = AVURLAsset(url: url)
        Task {
            do {
                let playable = try await asset.load(.isPlayable)
                _ = try? await asset.load(.duration)

                guard playable else {
                    await MainActor.run {
                        self.isLoading = false
                        self.errorText = "This file isn’t playable on iOS."
                    }
                    return
                }

                let item = AVPlayerItem(asset: asset)
                let p = AVPlayer(playerItem: item)
                p.allowsExternalPlayback = false
                p.automaticallyWaitsToMinimizeStalling = true

                await MainActor.run {
                    self.player = p
                    self.isLoading = true
                    self.errorText = nil

                    // Observe item.status for ready/failed
                    self.statusCancellable = item.publisher(for: \.status, options: [.initial, .new])
                        .receive(on: DispatchQueue.main)
                        .sink { status in
                            switch status {
                            case .readyToPlay:
                                // Spinner hides once timeControlStatus becomes .playing
                                break
                            case .failed:
                                self.isLoading = false
                                self.errorText = item.error?.localizedDescription ?? "Playback failed."
                            default:
                                break
                            }
                        }

                    // Observe player timeControlStatus to toggle spinner on buffer
                    self.timeCtrlCancellable = p.publisher(for: \.timeControlStatus, options: [.initial, .new])
                        .receive(on: DispatchQueue.main)
                        .sink { status in
                            switch status {
                            case .playing:
                                self.isLoading = false
                            case .paused, .waitingToPlayAtSpecifiedRate:
                                self.isLoading = true
                            @unknown default:
                                break
                            }
                        }
                }

                // Configure audio + start playback
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .default, options: [.duckOthers])
                    try session.setActive(true)
                } catch {
                    print("⚠️ Audio session error: \(error.localizedDescription)")
                }

                await MainActor.run { p.play() }

            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    private func teardown() {
        statusCancellable?.cancel()
        timeCtrlCancellable?.cancel()
        player?.pause()
        player = nil
    }
}
