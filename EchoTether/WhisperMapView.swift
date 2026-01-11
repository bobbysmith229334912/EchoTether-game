import SwiftUI
import MapKit
import FirebaseFirestore
import FirebaseAuth
import FirebaseStorage
import AVFoundation
import AVKit
import Combine
import CoreLocation
import UIKit
import CryptoKit

struct WhisperMapView: View {
    // MARK: - View Mode / Sort
    private enum ViewMode: String, CaseIterable, Identifiable {
        case map = "Map"
        case list = "List"
        var id: String { rawValue }
    }
    private enum SortOption: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case closest = "Closest"
        var id: String { rawValue }
    }

    @State private var mode: ViewMode = .map
    @State private var sort: SortOption = .newest
    @State private var nearbyRadiusMeters: Double = 1000

    // MARK: - Map / Data
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var whispers: [Whisper] = []
    @State private var userLocation: CLLocation?
    @State private var locationManager = CLLocationManager()
    @State private var locationTimer: Timer?

    // Media flags: does whisper have any attachments?
    @State private var mediaFlags: [String: Bool] = [:]

    // AVPlayer (kept if you ever want silent bg playback)
    @State private var player: AVPlayer?

    // MARK: - Visible player overlay
    @State private var showPlayer = false
    @State private var currentURL: URL?

    // MARK: - Password Prompt
    @State private var showPasswordSheet = false
    @State private var passwordInput: String = ""
    @State private var pendingPlay: Whisper? = nil
    @State private var passwordError: String? = nil

    // Current user id (for delete permissions)
    private var currentUserId: String? { Auth.auth().currentUser?.uid }

    var body: some View {
        VStack(spacing: 12) {
            Picker("Mode", selection: $mode) {
                ForEach(ViewMode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if mode == .map {
                mapContent
            } else {
                listContent
            }
        }
        .navigationTitle("🗺️ Whisper Map")
        .task {
            configureLocation()
            await fetchWhispers()
            await fetchMediaFlags(for: whispers)
            if let loc = userLocation {
                GeoWhisperManager.shared.monitorNearest(whispers: whispers, userLocation: loc)
            }
        }
        .onChange(of: userLocation) { _, newValue in
            guard let loc = newValue else { return }
            if case .automatic = cameraPosition { centerMap(on: loc) }
            GeoWhisperManager.shared.monitorNearest(whispers: whispers, userLocation: loc)
        }
        .onDisappear {
            locationTimer?.invalidate()
            locationTimer = nil
        }
        .sheet(isPresented: $showPasswordSheet, onDismiss: {
            passwordInput = ""
            passwordError = nil
            pendingPlay = nil
        }) {
            passwordSheet
        }
        // Full-screen player overlay (with spinner)
        .sheet(isPresented: $showPlayer) {
            if let url = currentURL {
                WhisperPlayerView(url: url).ignoresSafeArea()
            }
        }
    }

    // MARK: - Map Content
    private var mapContent: some View {
        Map(position: $cameraPosition) {
            ForEach(whispers) { whisper in
                let coord = CLLocationCoordinate2D(latitude: whisper.latitude, longitude: whisper.longitude)
                let unlocked = whisper.isUnlocked(for: userLocation)
                let isMedia = mediaFlags[whisper.id] ?? false

                MapCircle(center: coord, radius: whisper.radiusMeters)
                    .foregroundStyle((isMedia ? Color.blue : Color.green).opacity(0.08))
                    .stroke((isMedia ? Color.blue : Color.green).opacity(0.25), lineWidth: 1)

                Annotation("", coordinate: coord) {
                    VStack(spacing: 6) {
                        if unlocked {
                            Image(systemName: "mappin.circle.fill")
                                .resizable()
                                .frame(width: 30, height: 30)
                                .foregroundColor(isMedia ? .blue : .green)
                            HStack(spacing: 8) {
                                Button("▶️ Play") { attemptPlay(whisper) }
                                    .font(.caption)
                                NavigationLink("Info") {
                                    WhisperDetailView(whisper: whisper) // shows images
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                            }
                        } else {
                            Image(systemName: "lock.circle.fill")
                                .resizable()
                                .frame(width: 30, height: 30)
                                .foregroundColor(isMedia ? .blue : .yellow)
                            Text(lockedReason(for: whisper))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(width: 120)
                        }
                    }
                }
            }
        }
        .mapStyle(.standard)
    }

    // MARK: - List Content
    private var listContent: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Sort", selection: $sort) {
                    ForEach(SortOption.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)

                Text("≤ \(formatDistance(nearbyRadiusMeters))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            List {
                ForEach(nearbySortedWhispers, id: \.id) { whisper in
                    let distance = distanceTo(whisper)
                    let unlocked = whisper.isUnlocked(for: userLocation)
                    let isMedia = mediaFlags[whisper.id] ?? false

                    HStack(spacing: 12) {
                        if unlocked {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundColor(isMedia ? .blue : .green)
                        } else {
                            Image(systemName: "lock.fill")
                                .foregroundColor(isMedia ? .blue : .yellow)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(relativeTimeString(from: whisper.timestamp)) • \(absoluteTimeString(from: whisper.timestamp))")
                                .font(.subheadline)
                            Text("Lat \(String(format: "%.5f", whisper.latitude)), Lng \(String(format: "%.5f", whisper.longitude))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 4) {
                            Text(formatDistance(distance))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if unlocked {
                                HStack {
                                    Button("▶️ Play") { attemptPlay(whisper) }
                                        .font(.caption)
                                    NavigationLink("Info") {
                                        WhisperDetailView(whisper: whisper) // images
                                    }
                                    .font(.caption)
                                    .buttonStyle(.bordered)
                                }
                            } else {
                                Text(lockBadge(for: whisper))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        centerMap(on: CLLocation(latitude: whisper.latitude, longitude: whisper.longitude))
                        mode = .map
                    }
                    // 🔄 Soft-delete swipe
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if whisper.canBeDeleted(by: currentUserId) {
                            Button(role: .destructive) {
                                Task { await softDeleteWhisper(whisper) }
                            } label: {
                                Label("Delete (free – 24h)", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    // MARK: - Nearby + Sorting
    private var nearbyWhispers: [Whisper] {
        guard let userLocation else { return [] }
        return whispers.filter { w in
            let loc = CLLocation(latitude: w.latitude, longitude: w.longitude)
            return userLocation.distance(from: loc) <= nearbyRadiusMeters
        }
    }
    private var nearbySortedWhispers: [Whisper] {
        switch sort {
        case .newest:  return nearbyWhispers.sorted { $0.timestamp > $1.timestamp }
        case .closest: return nearbyWhispers.sorted { distanceTo($0) < distanceTo($1) }
        }
    }

    // MARK: - Location
    private func configureLocation() {
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestWhenInUseAuthorization()
        locationManager.startUpdatingLocation()

        if let loc = locationManager.location {
            userLocation = loc
            centerMap(on: loc)
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { _ in
            if let loc = self.locationManager.location { self.userLocation = loc }
        }

        locationTimer?.invalidate()
        locationTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            if let loc = self.locationManager.location { self.userLocation = loc }
        }
    }

    private func centerMap(on location: CLLocation) {
        let region = MKCoordinateRegion(
            center: location.coordinate,
            span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
        cameraPosition = .region(region)
    }

    // MARK: - Data
    private func fetchWhispers() async {
        let db = Firestore.firestore()
        do {
            let snap = try await db.collection("whispers").getDocuments()
            self.whispers = snap.documents
                .compactMap { Whisper(id: $0.documentID, data: $0.data()) }
                .filter { !$0.isDeleted }

            if let loc = self.userLocation {
                GeoWhisperManager.shared.monitorNearest(whispers: self.whispers, userLocation: loc)
            }
        } catch {
            print("❌ Failed to fetch whispers: \(error.localizedDescription)")
        }
    }

    // Media flags: quick “has any attachments” lookup
    private func fetchMediaFlags(for whispers: [Whisper]) async {
        let db = Firestore.firestore()
        await withTaskGroup(of: (String, Bool)?.self) { group in
            for w in whispers {
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
            var temp: [String: Bool] = [:]
            for await pair in group {
                if let (id, hasAny) = pair {
                    temp[id] = hasAny
                }
            }
            await MainActor.run { self.mediaFlags.merge(temp) { _, new in new } }
        }
    }

    // MARK: - Playback (with password gate + mark found)
    private func attemptPlay(_ whisper: Whisper) {
        if whisper.requiresPassword {
            pendingPlay = whisper
            passwordInput = ""
            passwordError = nil
            showPasswordSheet = true
        } else {
            currentURL = whisper.audioURL
            showPlayer = true
            markFoundAndStop(whisper)
        }
    }

    // (keep this around if you ever want silent background playback without UI)
    private func playAudio(from url: URL) {
        guard url.scheme?.hasPrefix("http") == true else {
            print("❌ Not a playable HTTP(S) URL: \(url)")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            print("⚠️ Could not set audio session: \(error.localizedDescription)")
        }
        let newPlayer = AVPlayer(url: url)
        self.player = newPlayer
        newPlayer.play()
        print("▶️ Streaming: \(url.absoluteString)")
    }

    // MARK: - SOFT DELETE (queued purge)
    private func softDeleteWhisper(_ whisper: Whisper, instant: Bool = false) async {
        let db = Firestore.firestore()
        let docRef = db.collection("whispers").document(whisper.id)

        let now = Date()
        let purgeAtDate = instant ? now : now.addingTimeInterval(24 * 60 * 60)

        do {
            try await docRef.updateData([
                "deleted": true,
                "deletedAt": Timestamp(date: now),
                "purgeAt": Timestamp(date: purgeAtDate),
                "deleteTier": instant ? "instant" : "free-queued"
            ])

            await MainActor.run {
                whispers.removeAll { $0.id == whisper.id }
                mediaFlags.removeValue(forKey: whisper.id)
            }
        } catch {
            print("❌ Soft delete failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Password Sheet
    private var passwordSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("This whisper is password-protected")
                    .font(.headline)
                SecureField("Enter password", text: $passwordInput)
                    .textContentType(.password)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)

                if let passwordError {
                    Text(passwordError)
                        .font(.footnote)
                        .foregroundColor(.red)
                }

                Button("Unlock & Play") {
                    guard let whisper = pendingPlay else { return }
                    if verifyPassword(input: passwordInput, against: whisper.passwordHash) {
                        showPasswordSheet = false
                        currentURL = whisper.audioURL
                        showPlayer = true
                        markFoundAndStop(whisper)
                    } else {
                        passwordError = "Incorrect password. Try again."
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") { showPasswordSheet = false }
                    .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("Protected Whisper")
        }
    }

    private func verifyPassword(input: String, against storedHash: String?) -> Bool {
        guard let storedHash else { return false }
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        let inputHex = hash.compactMap { String(format: "%02x", $0) }.joined()
        return inputHex.caseInsensitiveCompare(storedHash) == .orderedSame
    }

    private func markFoundAndStop(_ whisper: Whisper) {
        FoundAndNotifyStore.markFound(whisper.id)
        GeoWhisperManager.shared.stopMonitoring(id: whisper.id)
    }

    // MARK: - Helpers
    private func distanceTo(_ whisper: Whisper) -> CLLocationDistance {
        guard let userLocation else { return .infinity }
        let drop = CLLocation(latitude: whisper.latitude, longitude: whisper.longitude)
        return userLocation.distance(from: drop)
    }
    private func formatDistance(_ meters: CLLocationDistance) -> String {
        meters < 1000 ? "\(Int(meters)) m" : String(format: "%.1f km", meters / 1000.0)
    }
    private func relativeTimeString(from date: Date) -> String {
        let r = RelativeDateTimeFormatter()
        r.unitsStyle = .short
        return r.localizedString(for: date, relativeTo: Date())
    }
    private func absoluteTimeString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
    private func lockedReason(for whisper: Whisper) -> String {
        if Date() < whisper.unlockAt { return "🔒 Unlocks at\n\(absoluteTimeString(from: whisper.unlockAt))" }
        guard let userLocation else { return "🔒 Move closer" }
        let drop = CLLocation(latitude: whisper.latitude, longitude: whisper.longitude)
        let metersLeft = max(0, whisper.radiusMeters - userLocation.distance(from: drop))
        return "🔒 Move closer\n(~\(Int(metersLeft))m)"
    }
    private func lockBadge(for whisper: Whisper) -> String {
        Date() < whisper.unlockAt ? "⏳ Time" : "📍 Proximity"
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
        guard url.scheme?.lowercased() == "https" else {
            isLoading = false
            errorText = "Blocked by ATS (URL must be https)."
            return
        }

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

                    self.statusCancellable = item.publisher(for: \.status, options: [.initial, .new])
                        .receive(on: DispatchQueue.main)
                        .sink { status in
                            switch status {
                            case .readyToPlay:
                                break
                            case .failed:
                                self.isLoading = false
                                self.errorText = item.error?.localizedDescription ?? "Playback failed."
                            default:
                                break
                            }
                        }

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
