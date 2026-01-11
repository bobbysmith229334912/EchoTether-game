import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseStorage
import FirebaseFirestore
import FirebaseFunctions   // callable functions
import AVFoundation
import CoreLocation
import RevenueCat
import CryptoKit
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import Combine // username publisher

// MARK: - Helpers

private func sha256Hex(_ input: String) -> String {
    let data = Data(input.utf8)
    let hash = SHA256.hash(data: data)
    return hash.compactMap { String(format: "%02x", $0) }.joined()
}

struct PickedVideo: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            try FileManager.default.copyItem(at: received.file, to: tmpURL)
            return .init(url: tmpURL)
        }
    }
}

// MARK: - Wallet Snapshot (NEW, for money vs free uploads)

final class WalletSnapshotStore: ObservableObject {
    @Published var availableCents: Int = 0
    @Published var isLoading: Bool = false
    @Published var lastError: String?

    func refresh() {
        guard let uid = Auth.auth().currentUser?.uid else {
            availableCents = 0
            lastError = nil
            return
        }

        isLoading = true
        lastError = nil

        Firestore.firestore()
            .collection("users")
            .document(uid)
            .getDocument { snapshot, error in
                DispatchQueue.main.async {
                    self.isLoading = false
                    if let error = error {
                        self.lastError = error.localizedDescription
                        self.availableCents = 0
                        return
                    }
                    self.availableCents = snapshot?.data()?["availableCents"] as? Int ?? 0
                }
            }
    }
}

// MARK: - Reusable UI

struct ChipButton: View {
    let systemImage: String
    let title: String
    var tint: Color = .blue
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .imageScale(.large)
                    .frame(width: 36, height: 36)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(tint.opacity(0.25), lineWidth: 1)
            )
        }
        .tint(tint)
        .contentShape(Rectangle())
    }
}

struct StatusBanner: View {
    let text: String
    var icon: String = "info.circle"
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(text).lineLimit(2)
            Spacer()
        }
        .font(.footnote)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

struct BalanceBadge: View {
    @EnvironmentObject var whisperStore: WhisperBalanceStore
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
            Text("\(whisperStore.balance)")
                .font(.headline)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.2)))
        .accessibilityLabel("Whisper balance \(whisperStore.balance)")
    }
}

// MARK: - Payout Prompt (included so it compiles)

struct PayoutPromptSheet: View {
    let availableCents: Int
    var onSetup: () -> Void
    var onLater: () -> Void = {}

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "creditcard.and.123")
                        .imageScale(.large)
                    Text("Finish your wallet to receive funds")
                        .font(.title3.bold())
                }

                Text("You have money waiting but no connected payout account.")
                    .foregroundStyle(.secondary)

                GroupBox {
                    HStack {
                        Text("Available")
                        Spacer()
                        Text("$\(Double(availableCents)/100, specifier: "%.2f")")
                            .font(.title3.bold())
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                }

                VStack(spacing: 12) {
                    Button {
                        onSetup()
                    } label: {
                        Text("Connect Payout Account")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Maybe later") { onLater() }
                        .frame(maxWidth: .infinity)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Wallet")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject var subscription: SubscriptionManager
    @EnvironmentObject var whisperStore: WhisperBalanceStore

    @StateObject private var recorder = AudioRecorder()
    @StateObject private var locationManager = LocationManager()
    @StateObject private var player = AudioPreviewPlayer()

    // NEW: Wallet snapshot for money vs free uploads
    @StateObject private var walletStore = WalletSnapshotStore()

    // NEW: Games hub navigation (view will be in its own file)
    @State private var showGamesHub = false

    // Auth + Money Hub routing
    @StateObject private var auth = AuthViewModel()
    @State private var showAuthSheet = false
    @State private var showMoneyHub = false
    @State private var showWallet = false

    // NEW: Crypto Mode navigation
    @State private var showCryptoMode = false

    // UI / form state
    @State private var uploadStatus: String = ""
    @State private var showMap = false
    @State private var showAR = false
    @State private var showInfoSheet = false

    // Locks
    @State private var useTimeLock = false
    @State private var selectedUnlockAt = Date()
    @State private var radiusMeters: Double = 50

    // Password lock
    @State private var requirePassword = false
    @State private var passwordPlain = ""

    // Whisper name (always persisted with fallback)
    @State private var whisperNameInput: String = ""
    @State private var lastWhisperId: String? = nil

    // Paywall
    @State private var showPaywallSheet = false

    // Media picker (images + videos)
    @State private var selectedMediaItems: [PhotosPickerItem] = []
    @State private var pickedMediaCount: Int = 0

    // Username
    @State private var showUsernameSheet = false
    @State private var currentHandle: String? = nil
    @State private var usernameCancellable: AnyCancellable? = nil

    // Wallet prompt
    @State private var showPayoutPrompt = false
    @State private var walletAvailableCents: Int = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {

                    // MARK: Header (spacious)
                    HStack(alignment: .center, spacing: 12) {
                        Label {
                            Text("EchoTether")
                                .font(.largeTitle.bold())
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        } icon: {
                            Text("📍")
                                .font(.largeTitle)
                                .padding(.trailing, -4)
                        }
                        Spacer(minLength: 8)
                        BalanceBadge()
                    }

                    // MARK: Action chip tray (scrolls to avoid crowding)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ChipButton(systemImage: "questionmark.circle", title: "Help") {
                                showInfoSheet = true
                            }
                            ChipButton(systemImage: "at.circle.fill",
                                       title: (currentHandle ?? "Username")) {
                                showUsernameSheet = true
                            }
                            ChipButton(systemImage: "wallet.pass.fill", title: "Wallet") {
                                if Auth.auth().currentUser == nil {
                                    showAuthSheet = true
                                } else {
                                    showWallet = true
                                }
                            }
                            ChipButton(systemImage: "creditcard.fill", title: "Add Money") {
                                if Auth.auth().currentUser == nil {
                                    showAuthSheet = true
                                } else {
                                    showMoneyHub = true
                                }
                            }
                            // NEW: Games entry (view itself is in another file)
                            ChipButton(systemImage: "gamecontroller.fill", title: "Games") {
                                if Auth.auth().currentUser == nil {
                                    showAuthSheet = true
                                } else {
                                    showGamesHub = true
                                }
                            }
                            // NEW: Crypto Mode entry
                            ChipButton(systemImage: "bitcoinsign.circle.fill", title: "Crypto Mode") {
                                if Auth.auth().currentUser == nil {
                                    showAuthSheet = true
                                } else {
                                    showCryptoMode = true
                                }
                            }
                            ChipButton(systemImage: "bubble.left.and.bubble.right", title: "Support") {
                                if let url = URL(string: "mailto:support@echotether.app?subject=EchoTether%20Support&body=Describe%20the%20issue%20here...") {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                    }

                    // MARK: Plan status
                    if subscription.isPro {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                            Text("Premium Active")
                                .font(.subheadline)
                                .foregroundColor(.green)
                            Spacer()
                            Button {
                                showInfoSheet = true
                            } label: {
                                Label("Help", systemImage: "questionmark.circle")
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("EchoTether Pro").font(.headline)
                                Text("Your first 100 uploads are free.")
                                    .font(.footnote).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("View Pro") { showPaywallSheet = true }
                                .buttonStyle(.borderedProminent)
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Background alerts").font(.subheadline).bold()
                                Text("Get notified when a whisper unlocks nearby.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Enable") { GeoWhisperManager.shared.requestAlwaysIfNeeded() }
                                .buttonStyle(.bordered)
                        }
                        Text("Free uploads left: \(whisperStore.balance)")
                            .font(.footnote).foregroundColor(.secondary)
                    }

                    // NEW: Money vs Credits breakdown (wallet vs 100 free uploads)
                    GroupBox("Money & Credits") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Wallet balance", systemImage: "creditcard.and.123")
                                Spacer()
                                if walletStore.isLoading {
                                    ProgressView()
                                } else {
                                    Text(String(format: "$%.2f", Double(walletStore.availableCents) / 100.0))
                                        .font(.headline)
                                        .monospacedDigit()
                                }
                            }

                            if let err = walletStore.lastError {
                                Text("Wallet error: \(err)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Divider().padding(.vertical, 4)

                            HStack {
                                Label("Free uploads", systemImage: "bubble.left.and.bubble.right")
                                Spacer()
                                Text("\(whisperStore.balance)")
                                    .font(.subheadline.monospacedDigit())
                            }

                            Text("Free uploads are only used for recording & dropping whispers. Money in your wallet is for funding whispers, Auto Release, and future games.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    // MARK: Recording
                    if recorder.isRecording {
                        Button("🛑 Stop Recording") {
                            recorder.stopRecording()
                            if let url = recorder.recordedURL {
                                do { try player.load(url: url) }
                                catch { uploadStatus = "❌ Preview load failed: \(error.localizedDescription)" }
                            }
                        }
                        .font(.title2).foregroundColor(.red)
                    } else {
                        Button("🎙️ Start Recording") { recorder.startRecording() }
                            .font(.title2).foregroundColor(.blue)
                    }

                    // MARK: Preview
                    if player.isLoaded {
                        GroupBox("Preview Your Whisper") {
                            VStack(spacing: 12) {
                                HStack(spacing: 12) {
                                    Button { player.playPause() } label: {
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

                                    Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
                                        .font(.caption)
                                        .monospacedDigit()
                                        .frame(minWidth: 90, alignment: .trailing)
                                }

                                HStack {
                                    Button(role: .destructive) {
                                        player.stop()
                                        recorder.discard()
                                        uploadStatus = ""
                                    } label: {
                                        Label("Re-record", systemImage: "arrow.counterclockwise.circle")
                                    }
                                    Spacer()
                                }
                            }
                            .padding(.top, 4)
                        }
                    }

                    // MARK: Drop Options
                    GroupBox("Drop Options") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Title").font(.caption).foregroundColor(.secondary)
                            TextField("Whisper Name (helps you find & fund it)", text: $whisperNameInput)
                                .textInputAutocapitalization(.words)
                                .textFieldStyle(.roundedBorder)
                                .submitLabel(.done)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Proximity Radius: \(Int(radiusMeters)) m")
                                    .font(.subheadline)
                                Slider(value: $radiusMeters, in: 10...500, step: 10)
                            }

                            Toggle("Time Lock (unlock at a future time)", isOn: $useTimeLock)
                            if useTimeLock {
                                DatePicker("Unlock At",
                                           selection: $selectedUnlockAt,
                                           in: Date()...,
                                           displayedComponents: [.date, .hourAndMinute])
                                .datePickerStyle(.compact)
                            }

                            Toggle("Require password to play", isOn: $requirePassword)
                            if requirePassword {
                                SecureField("Password (min 4 chars)", text: $passwordPlain)
                                    .textContentType(.password)
                                    .autocorrectionDisabled(true)
                                    .textInputAutocapitalization(.never)
                                    .font(.subheadline)
                            }
                        }
                        .padding(.top, 4)
                    }

                    // MARK: Media
                    GroupBox("Add Photos or Videos (optional)") {
                        VStack(alignment: .leading, spacing: 10) {
                            PhotosPicker(
                                selection: $selectedMediaItems,
                                maxSelectionCount: 5,
                                matching: .any(of: [.images, .videos]),
                                preferredItemEncoding: .automatic
                            ) {
                                HStack {
                                    Image(systemName: "paperclip")
                                    Text(pickedMediaCount > 0 ? "Selected \(pickedMediaCount) item(s)" : "Pick photos or videos")
                                    Spacer()
                                    if pickedMediaCount > 0 {
                                        Text("\(pickedMediaCount)")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.15), in: Capsule())
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .onChange(of: selectedMediaItems) { _, newValue in
                                pickedMediaCount = newValue.count
                            }

                            Text("You can attach up to 5 items. Videos are compressed to ~1080p with a thumbnail.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }

                    // MARK: Upload
                    if let url = recorder.recordedURL {
                        Button("📤 Upload & Save Whisper") {
                            if player.isPlaying { player.playPause() }
                            attemptUploadOrPaywall(fileURL: url)
                        }
                        .padding()
                        .disabled(!whisperStore.isLoaded)
                    }

                    // Last whisper tools
                    if let wid = lastWhisperId {
                        HStack(spacing: 8) {
                            Text("Whisper ID:")
                            Text(wid)
                                .font(.caption)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = wid
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                if Auth.auth().currentUser == nil {
                                    showAuthSheet = true
                                } else {
                                    showMoneyHub = true
                                }
                            } label: {
                                Label("Fund", systemImage: "creditcard")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.horizontal, 4)

                        NavigationLink("Open in Auto Release") {
                            AutoReleaseView(dropId: wid)
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal, 4)
                    }

                    // Location
                    if let loc = locationManager.lastLocation {
                        Text("📡 Location: \(loc.coordinate.latitude), \(loc.coordinate.longitude)")
                            .font(.caption).multilineTextAlignment(.center)
                    } else {
                        Text("📡 Getting location…")
                            .font(.caption).foregroundColor(.secondary)
                    }

                    // Map + AR
                    Button("🗺️ View Whispers on Map") { showMap = true }
                        .font(.headline)

                    Button("👓 View in AR") {
                        let cm = CLLocationManager()
                        if cm.authorizationStatus == .notDetermined {
                            cm.requestWhenInUseAuthorization()
                        }
                        showAR = true
                    }
                    .font(.headline)

                    NavigationLink("⚡ Auto Release") {
                        AutoReleaseView(dropId: nil)
                    }
                    .font(.headline)
                    .buttonStyle(.bordered)

                    // Bottom banner for status
                    if !uploadStatus.isEmpty {
                        StatusBanner(text: whisperStore.isLoaded ? uploadStatus : "Loading balance…",
                                     icon: whisperStore.isLoaded ? "info.circle" : "hourglass")
                            .padding(.top, 4)
                    }
                }
                .padding()
            }

            // MARK: Navigation / Sheets
            .navigationDestination(isPresented: $showMap) {
                WhisperMapView()
            }
            .navigationDestination(isPresented: $showAR) {
                ARWhisperView().environmentObject(locationManager)
            }
            .navigationDestination(isPresented: $showMoneyHub) {
                MoneyHubContainer(initialWhisperId: lastWhisperId, initialName: whisperNameInput)
            }
            .navigationDestination(isPresented: $showWallet) {
                MyMoneyView()   // existing wallet + leaderboard screen
            }
            // NEW: Crypto Mode destination
            .navigationDestination(isPresented: $showCryptoMode) {
                CryptoModeView()
            }
            // NEW: Games hub destination (view in separate file)
            .navigationDestination(isPresented: $showGamesHub) {
                GamesHubView()  // define this in GamesHubView.swift
            }

            .sheet(isPresented: $showPaywallSheet) {
                ScrollView { subscriptionInfoSection.padding() }
            }
            .sheet(isPresented: $showAuthSheet) {
                AuthScreen()
                    .environmentObject(auth)
                    .onChange(of: auth.user) { _, user in
                        if user != nil {
                            showAuthSheet = false
                            showWallet = true   // open MyMoneyView after successful sign-in
                        }
                    }
                    .presentationDetents([.medium, .large])
                    .presentationCornerRadius(24)
            }
            .sheet(isPresented: $showInfoSheet) {
                ProInfoSheet()
                    .presentationDetents([.large])
                    .presentationCornerRadius(24)
            }
            .sheet(isPresented: $showUsernameSheet) {
                SetUsernameView(currentHandle: $currentHandle)
                    .presentationDetents([.medium])
                    .presentationCornerRadius(24)
            }
            .sheet(isPresented: $showPayoutPrompt) {
                PayoutPromptSheet(
                    availableCents: walletAvailableCents,
                    onSetup: {
                        Task {
                            do {
                                let url = try await WalletService.shared.openOnboarding(
                                    refreshURL: "echotether://stripe-refresh",
                                    returnURL:  "echotether://stripe-return"
                                )
                                await UIApplication.shared.open(url)
                            } catch { /* ignore */ }
                        }
                    },
                    onLater: { showPayoutPrompt = false }
                )
                .presentationDetents([.medium])
                .presentationCornerRadius(24)
            }
        }
        .onAppear {
            // ✅ Start location updates as soon as home screen appears
            locationManager.start()

            GeoWhisperManager.shared.configure()

            // Live username chip
            usernameCancellable = UsernameService.shared.usernamePublisher()
                .sink { name in
                    if let name = name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        currentHandle = "@\(name)"
                    } else {
                        currentHandle = nil
                    }
                }

            // Show payout prompt if: user has $ > 0 AND payouts not enabled
            Task { await evaluatePayoutPrompt() }

            // NEW: refresh wallet snapshot for the Money & Credits box
            walletStore.refresh()

            // (kept) sample username flow
            Task {
                do {
                    let ok = try await UsernameService.shared.checkAvailability("Bobby_Smith")
                    print("available?", ok)
                    if ok {
                        let final = try await UsernameService.shared.setUsername("Bobby_Smith")
                        print("set to", final)
                    }
                } catch {
                    print("username error:", error.localizedDescription)
                }
            }
        }

        .onDisappear {
            player.stop()
            usernameCancellable?.cancel()
            usernameCancellable = nil
        }
        .onChange(of: recorder.recordedURL) { _, newURL in
            if let url = newURL {
                do { try player.load(url: url) }
                catch { uploadStatus = "❌ Preview load failed: \(error.localizedDescription)" }
                if whisperNameInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    whisperNameInput = "Whisper • " + Date.now.formatted(date: .abbreviated, time: .shortened)
                }
            } else {
                player.stop()
            }
        }
    }

    // MARK: - Subscription Info (for non-Pro)

    private var subscriptionInfoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("🔓 EchoTether Pro").font(.title3).bold()
            Text("$1.99/month").font(.largeTitle).bold().foregroundColor(.primary)
            Text("3-day free trial").font(.headline).foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("• Auto-renewing subscription, billed monthly.")
                Text("• After the trial, your Apple ID is charged $1.99/month unless canceled.")
                Text("• Cancel anytime in Settings ▸ Apple ID ▸ Subscriptions. Charges may apply if not canceled at least 24 hours before the period ends.")
            }
            .font(.footnote).foregroundColor(.secondary)

            HStack(spacing: 16) {
                Link("Privacy Policy", destination: URL(string: "https://hardcoreamature.com/echotether-privacy-policy/")!)
                Link("Terms of Use", destination: URL(string: "https://hardcoreamature.com/etterms-of-use/")!)
                Link("EULA", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            }
            .font(.footnote)

            Button {
                subscription.purchasePro()
            } label: {
                Text("Subscribe for $1.99/month")
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            .background(Color.blue).foregroundColor(.white).cornerRadius(12)

            HStack {
                Button("Restore Purchases") {
                    Purchases.shared.restorePurchases { customerInfo, error in
                        if let error = error {
                            print("❌ Restore error: \(error.localizedDescription)")
                        } else if let customerInfo = customerInfo {
                            subscription.updateSubscriptionStatus(from: customerInfo)
                            print("✅ Purchases restored.")
                        }
                    }
                }
                Spacer()
                Link("Manage Subscription",
                     destination: URL(string: "itms-apps://apps.apple.com/account/subscriptions")!)
            }
            .font(.subheadline)
        }
        .padding(.horizontal)
    }

    // MARK: - Upload gating

    private func attemptUploadOrPaywall(fileURL: URL) {
        guard whisperStore.isLoaded else {
            uploadStatus = "⏳ Loading your balance…"
            return
        }

        if requirePassword {
            let trimmed = passwordPlain.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 4 else {
                uploadStatus = "❌ Password must be at least 4 characters."
                return
            }
        }

        if subscription.isPro {
            uploadRecording(fileURL: fileURL, spentCredit: false)
            return
        }

        if whisperStore.spend(1) {
            uploadRecording(fileURL: fileURL, spentCredit: true)
        } else {
            uploadStatus = "🔒 You’re out of free uploads. Unlock Pro to continue."
            showPaywallSheet = true
        }
    }

    // MARK: - Upload

    private func uploadRecording(fileURL: URL) {
        uploadRecording(fileURL: fileURL, spentCredit: false)
    }

    private func uploadRecording(fileURL: URL, spentCredit: Bool) {
        if let opts = FirebaseApp.app()?.options {
            print("🧭 Firebase projectID=\(opts.projectID ?? "nil") bucket=\(opts.storageBucket ?? "nil")")
        } else {
            print("❌ FirebaseApp not configured")
        }

        guard let location = locationManager.lastLocation else {
            uploadStatus = "❌ Location not available yet."
            if spentCredit { whisperStore.grant(1) }
            return
        }

        let path = "recordings/\(UUID().uuidString).m4a"
        let storageRef = Storage.storage().reference().child(path)
        let metadata = StorageMetadata()
        metadata.contentType = "audio/m4a"

        uploadStatus = "Uploading to \(path)…"

        storageRef.putFile(from: fileURL, metadata: metadata) { _, error in
            if let error = error {
                self.uploadStatus = "❌ Upload failed: \(error.localizedDescription)"
                if spentCredit { self.whisperStore.grant(1) }
                return
            }
            storageRef.downloadURL { url, error in
                if let error = error {
                    self.uploadStatus = "❌ Failed to get download URL: \(error.localizedDescription)"
                    if spentCredit { self.whisperStore.grant(1) }
                    return
                }
                guard let downloadURL = url else {
                    self.uploadStatus = "❌ Failed to get download URL (nil)"
                    if spentCredit { self.whisperStore.grant(1) }
                    return
                }
                self.uploadStatus = "✅ Uploaded! Saving metadata…"
                self.saveToFirestore(audioURL: downloadURL, location: location, spentCredit: spentCredit)
            }
        }
    }

    // MARK: - Save Whisper

    private func saveToFirestore(audioURL: URL, location: CLLocation, spentCredit: Bool) {
        let effectiveUnlockDate: Date = {
            if useTimeLock {
                let minDate = Date().addingTimeInterval(60)
                return max(selectedUnlockAt, minDate)
            } else {
                return Date()
            }
        }()

        let db = Firestore.firestore()

        var data: [String: Any] = [
            "audioURL": audioURL.absoluteString,
            "timestamp": Timestamp(date: Date()),
            "unlockAt": Timestamp(date: effectiveUnlockDate),
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "radiusMeters": radiusMeters,
            "deleted": false,
            "balance": 0.0
        ]

        if let uid = Auth.auth().currentUser?.uid {
            data["ownerId"] = uid
        } else {
            let dev = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            data["ownerId"] = "device-\(dev)"
        }

        let trimmedName = whisperNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultName = "Whisper • " + Date.now.formatted(date: .abbreviated, time: .shortened)
        data["name"] = trimmedName.isEmpty ? defaultName : trimmedName

        if requirePassword {
            let trimmed = passwordPlain.trimmingCharacters(in: .whitespacesAndNewlines)
            data["passwordHash"] = sha256Hex(trimmed)
        }

        let docRef = db.collection("whispers").document()

        docRef.setData(data) { error in
            if let error = error {
                uploadStatus = "❌ Firestore error: \(error.localizedDescription)"
                if spentCredit { whisperStore.grant(1) }
            } else {
                let newId = docRef.documentID
                lastWhisperId = newId

                uploadStatus = "📥 Whisper saved (ID: \(newId)). Radius \(Int(radiusMeters))m, unlocks \(useTimeLock ? "at \(effectiveUnlockDate.formatted())" : "now")."
                recorder.recordedURL = nil
                requirePassword = false
                passwordPlain = ""

                let ownerIdStr = (data["ownerId"] as? String) ?? "device-unknown"
                if !selectedMediaItems.isEmpty {
                    let whisperId = newId
                    Task { await uploadSelectedMedia(items: selectedMediaItems, whisperId: whisperId, ownerId: ownerIdStr) }
                } else {
                    selectedMediaItems.removeAll()
                    pickedMediaCount = 0
                }
            }
        }
    }

    // MARK: - Media attachments

    @MainActor
    private func uploadSelectedMedia(items: [PhotosPickerItem], whisperId: String, ownerId: String) async {
        guard !items.isEmpty else { return }

        uploadStatus = "📎 Uploading \(items.count) attachment(s)…"

        var success = 0
        for item in items {
            do {
                if let picked = try? await item.loadTransferable(type: PickedVideo.self) {
                    _ = try await MediaUploadService.shared.uploadVideo(
                        at: picked.url,
                        whisperId: whisperId,
                        ownerId: ownerId
                    )
                    try? FileManager.default.removeItem(at: picked.url)
                    success += 1
                    continue
                }

                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data),
                   let jpeg = img.jpegData(compressionQuality: 0.8) {
                    _ = try await MediaUploadService.shared.uploadImageData(
                        jpeg,
                        whisperId: whisperId,
                        ownerId: ownerId
                    )
                    success += 1
                    continue
                }

                print("⚠️ Unsupported media item; skipping.")
            } catch {
                print("❌ Media upload failed:", error)
            }
        }

        selectedMediaItems.removeAll()
        pickedMediaCount = 0

        uploadStatus = success > 0
            ? "✅ Uploaded \(success) attachment(s)."
            : "⚠️ No attachments were uploaded."
    }

    // MARK: - mm:ss

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Wallet / Payout prompt logic

    private func evaluatePayoutPrompt() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let db = Firestore.firestore()
        do {
            let snap = try await db.collection("users").document(uid).getDocument()
            let available = (snap.data()?["availableCents"] as? Int) ?? 0
            self.walletAvailableCents = available

            // TODO: plug in real payout status
            let needsSetup = true

            await MainActor.run {
                if available > 0 && needsSetup {
                    showPayoutPrompt = true
                }
            }
        } catch {
            // ignore
        }
    }
}

// MARK: - Pro Info (unchanged content, kept for completeness)

struct ProInfoSheet: View {
    @EnvironmentObject var subscription: SubscriptionManager
    @State private var restoring = false
    @State private var restoreMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Your Plan") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Active", systemImage: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Text("Thanks for supporting EchoTether. Your premium features are unlocked on this device.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Account & Billing") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            if let url = URL(string: "itms-apps://apps.apple.com/account/subscriptions") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Manage Subscription", systemImage: "person.crop.circle.badge.gearshape")
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            restoring = true
                            restoreMessage = nil
                            Purchases.shared.restorePurchases { customerInfo, error in
                                restoring = false
                                if let error = error {
                                    restoreMessage = "Restore failed: \(error.localizedDescription)"
                                } else if let info = customerInfo {
                                    subscription.updateSubscriptionStatus(from: info)
                                    restoreMessage = "Purchases restored."
                                } else {
                                    restoreMessage = "No purchases to restore."
                                }
                            }
                        } label: {
                            Label(restoring ? "Restoring…" : "Restore Purchases", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(restoring)

                        if let msg = restoreMessage {
                            Text(msg)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                GroupBox("Background Alerts") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enable echo alerts so you’re notified when a whisper unlocks nearby.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Enable Alerts") {
                            GeoWhisperManager.shared.requestAlwaysIfNeeded()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                GroupBox("How EchoTether Works") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("A **Whisper** is a location-anchored, optional-password audio note (with optional photos/videos) that can hold funds. Once conditions are met (location, time, password), the recipient can **claim** it and funds are sent to their in-app wallet.")
                            .font(.subheadline)
                        Divider()
                        Text("Core pieces:")
                            .font(.subheadline.bold())
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Drop: record audio, choose a radius/time, optionally add password and media.", systemImage: "mic.circle")
                            Label("Find: recipients see nearby anchors on Map/AR.", systemImage: "location")
                            Label("Unlock: must be within the radius, past unlock time, and enter password if set.", systemImage: "lock.open")
                            Label("Claim: app hits your Cloud Function to move funds to the recipient’s wallet.", systemImage: "creditcard.and.123")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Auto Release (New)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("**Auto Release** lets you pre-authorize funds that unlock automatically when the right person is **in the right place** (and optionally after a time).")
                            .font(.subheadline)
                        Divider()
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Sender sets **who** (person / group / trusted), **where** (location + radius), **when** (optional time), and **how much**.", systemImage: "slider.horizontal.3")
                            Label("Receiver’s app detects entry into the radius and shows **Claim Auto Release**.", systemImage: "figure.walk.circle")
                            Label("Server verifies geo/time/eligibility and moves funds into the receiver’s wallet.", systemImage: "checkmark.seal")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                GroupBox("Auto Release — Sender (User A)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1) Open **Auto Release** from the home screen.")
                        Text("2) Choose recipient type (**Person**, **Group**, or **Trusted Any**).")
                        Text("3) Pick **Location** and **Radius**; optionally set an **Unlock After** time.")
                        Text("4) Enter **Amount** and an optional note.")
                        Text("5) Tap **Create Auto Release** (fund via Add Money if needed).")
                    }
                    .font(.subheadline)
                }

                GroupBox("Auto Release — Receiver (User B)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1) Go to the set location; keep Location Services on.")
                        Text("2) When inside the radius (and past the unlock time), the **Claim** button appears.")
                        Text("3) Tap **Claim Auto Release**; the server verifies and transfers funds to your wallet.")
                        Text("4) Open **Add Money** to view balance and cash out when available.")
                    }
                    .font(.subheadline)
                }

                GroupBox("User A (Sender) — Create & Drop") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1) Tap **Start Recording**, then **Stop** and preview.")
                        Text("2) In **Drop Options**, set **Title** (Whisper Name). If left blank, we’ll auto-fill a friendly default.")
                        Text("3) Choose **Proximity Radius** (10–500m).")
                        Text("4) Optional locks: **Time Lock** and/or **Require password**.")
                        Text("5) Optional: add **Photos/Videos** (up to 5).")
                        Text("6) Tap **Upload & Save Whisper**. The app stores audio, saves metadata, and shows your **Whisper ID**.")
                        Text("7) Share the **Whisper ID** with your recipient or let them discover it on the map/AR if nearby.")
                        Text("8) To fund it (Cash-App style), open **Add Money** → choose the whisper → fund with card. Funds sit on the whisper until it’s claimed.")
                    }
                    .font(.subheadline)
                }

                GroupBox("User B (Receiver) — Find & Claim") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1) Go near the drop location. Open **Map** or **AR** to see the anchor.")
                        Text("2) If it shows locked, move closer or wait for the unlock time.")
                        Text("3) If a password is required, the app will prompt you. Enter it to proceed.")
                        Text("4) When unlocked, tap the whisper. The app calls **claimWhisper**; funds move into **your wallet**.")
                        Text("5) You can then play the audio and view attached media.")
                        Text("6) To withdraw to your bank: open **Add Money** → **Connect Account** (Stripe Express) → **Cash Out**.")
                    }
                    .font(.subheadline)
                }

                GroupBox("Ways to Lock a Whisper") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "location.circle.fill")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Geo Lock (Radius)").font(.subheadline.bold())
                                Text("Recipients must be physically within the set meters to unlock.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "clock.fill")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Time Lock").font(.subheadline.bold())
                                Text("Unlocks only after your chosen date and time.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lock.fill")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Password").font(.subheadline.bold())
                                Text("Server-verified SHA-256 hash. Recipients must enter the correct password to claim.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Text("You can combine all three for maximum control.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                GroupBox("Money — Add, Claim, Cash Out") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Add Money:").font(.subheadline.bold())
                        Text("Open **Add Money** → pick a whisper → checkout. If the whisper is already claimed or closed, we auto-refund.")
                            .font(.footnote).foregroundStyle(.secondary)

                        Text("Claim:").font(.subheadline.bold()).padding(.top, 6)
                        Text("Receiver taps the unlocked whisper; **claimWhisper** moves the balance into the receiver's in-app wallet.")
                            .font(.footnote).foregroundStyle(.secondary)

                        Text("Cash Out:").font(.subheadline.bold()).padding(.top, 6)
                        Text("Open **Add Money** → **Connect Account** (Stripe Express) → **Cash Out Available** to transfer to your bank.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                GroupBox("Examples") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Example 1 — Coffee IOU").font(.subheadline.bold())
                        Text("A drops “Latte On Me ☕️” with 100m radius, no time lock, no password. A funds $5. B walks to the café, taps the whisper, claims $5, and plays A’s audio.")
                            .font(.footnote)

                        Divider()

                        Text("Example 2 — Birthday Surprise").font(.subheadline.bold())
                        Text("A sets 25m radius + time lock for Saturday 6pm + password “candles”. A funds $20. B arrives at 6:05pm, enters password, claims $20, and watches the attached video.")
                            .font(.footnote)

                        Divider()

                        Text("Example 3 — Auto Release Coffee Surprise (New)").font(.subheadline.bold())
                        Text("A creates an **Auto Release** of $5 at the neighborhood Starbucks with a 50m radius for **Trusted Any**. When B walks into that geofence, the app shows **Claim Auto Release**; B taps it, the server verifies location and eligibility, and $5 lands in B’s wallet automatically.")
                            .font(.footnote)
                    }
                }

                GroupBox("Troubleshooting") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("I don’t see the whisper.", systemImage: "exclamationmark.triangle.fill")
                        Text("Enable Location Services and move closer to the drop radius. Check unlock time.")
                            .font(.footnote).foregroundStyle(.secondary)

                        Label("Password not working.", systemImage: "key.fill")
                        Text("Ensure exact spelling/case. The password is hashed server-side; only the correct entry unlocks.")
                            .font(.footnote).foregroundStyle(.secondary)

                        Label("Funds didn’t appear.", systemImage: "creditcard.fill")
                        Text("Claims happen inside the app. If a top-up hit a closed whisper, the system triggers a refund automatically.")
                            .font(.footnote).foregroundStyle(.secondary)

                        Label("Cash out isn’t available.", systemImage: "banknote.fill")
                        Text("Finish Stripe Express onboarding in **Add Money** → **Connect Account**. You need an available balance to cash out.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                GroupBox("Privacy & Terms") {
                    VStack(alignment: .leading, spacing: 8) {
                        Link("Privacy Policy", destination: URL(string: "https://hardcoreamature.com/echotether-privacy-policy/")!)
                        Link("Terms of Use", destination: URL(string: "https://hardcoreamature.com/etterms-of-use/")!)
                        Link("Apple EULA", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    }
                    .font(.subheadline)
                }

                GroupBox("Support") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Need help or want to report an issue? Include your Whisper ID (if relevant) and a short description of what happened.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button {
                            if let url = URL(string: "mailto:support@echotether.app?subject=EchoTether%20Support&body=Describe%20the%20issue%20here...") {
                                UIApplication.shared.open(url)
                            }
                        } label: {
                            Label("Email Support", systemImage: "envelope")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding()
        }
    }
}
