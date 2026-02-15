//
//  ContentView.swift
//  EchoTether
//
//  FULL REWRITE (copy-paste safe) — UI reorganized for usability
//  ✅ No features removed (from the code you provided)
//  ✅ No logic removed (same actions / same flows)
//  ✅ Fixes build errors: ProInfoSheet scope + PresentationDetent inference
//

import SwiftUI
import FirebaseCore
import FirebaseAuth
import FirebaseStorage
import FirebaseFirestore
import FirebaseFunctions
import AVFoundation
import CoreLocation
import RevenueCat
import CryptoKit
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import Combine
import CoreTransferable


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

// MARK: - Wallet Snapshot (money vs free uploads)

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
                    .minimumScaleFactor(0.75)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(minHeight: 68)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(tint.opacity(0.25), lineWidth: 1)
            )
        }
        .tint(tint)
        .contentShape(Rectangle())
        .accessibilityLabel(title)
    }
}

struct StatusBanner: View {
    let text: String
    var icon: String = "info.circle"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
            Text(text).lineLimit(3)
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
        .accessibilityLabel("Free uploads \(whisperStore.balance)")
    }
}

// MARK: - Payout Prompt (kept so it compiles)

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

    // Wallet snapshot for money vs free uploads
    @StateObject private var walletStore = WalletSnapshotStore()

    // Auth + Money Hub routing
    @StateObject private var auth = AuthViewModel()
    @State private var showAuthSheet = false
    @State private var showMoneyHub = false
    @State private var showWallet = false
    
    // ✅ Username gate (Creator Code)
    @State private var requiresUsernameGate: Bool = false

    // ✅ Creator Code alert (shown once)
    @State private var showCreatorCodeAlert: Bool = false
    @AppStorage("didAcknowledgeCreatorCode")
    private var didAcknowledgeCreatorCode: Bool = false

    // Crypto Mode navigation
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
                VStack(spacing: 18) {

                    // Header + balance
                    HomeHeaderRow(title: "EchoTether", showsBalanceBadge: true)

                    // Actions
                    HomeActionChipsGrid(
                        currentHandle: currentHandle,
                        onHelp: { showInfoSheet = true },
                        onUsername: { showUsernameSheet = true },
                        onWallet: {
                            if Auth.auth().currentUser == nil { showAuthSheet = true }
                            else { showWallet = true }
                        },
                        onAddMoney: {
                            if Auth.auth().currentUser == nil { showAuthSheet = true }
                            else { showMoneyHub = true }
                        },
                        onCryptoMode: {
                            if Auth.auth().currentUser == nil { showAuthSheet = true }
                            else { showCryptoMode = true }
                        },
                        onSupport: {
                            if let url = URL(string: "mailto:support@echotether.app?subject=EchoTether%20Support&body=Describe%20the%20issue%20here...") {
                                UIApplication.shared.open(url)
                            }
                        }
                    )

                    // ✅ Username Gate Banner (blocks upload)  ✅✅✅ PASTE HERE
                    if requiresUsernameGate {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: "person.crop.circle.badge.exclamationmark")
                                Text("Set a username to continue")
                                    .font(.subheadline.weight(.semibold))
                            }

                            Text("Your username is your Creator Code. It’s used for attribution and payouts.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 12) {
                                Button {
                                    if Auth.auth().currentUser == nil {
                                        showAuthSheet = true
                                    } else {
                                        showUsernameSheet = true
                                    }
                                } label: {
                                    Label("Set Username", systemImage: "at")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)

                                Button {
                                    showAuthSheet = true
                                } label: {
                                    Text("Sign In")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .disabled(Auth.auth().currentUser != nil)
                                .opacity(Auth.auth().currentUser != nil ? 0.5 : 1)
                            }
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                        )
                    }

                    // Plan status  ✅ this should come right after the banner
                    PlanStatusSection(
                        isPro: subscription.isPro,
                        freeUploads: whisperStore.balance,
                        onViewPro: { showPaywallSheet = true },
                        onEnableAlerts: { GeoWhisperManager.shared.requestAlwaysIfNeeded() },
                        onHelp: { showInfoSheet = true }
                    )

                    

                    // Wallet vs free uploads box
                    WalletCreditsBox(
                        isLoading: walletStore.isLoading,
                        walletCents: walletStore.availableCents,
                        walletError: walletStore.lastError,
                        freeUploads: whisperStore.balance
                    )

                    Divider()

                    // Primary recording CTA
                    PrimaryRecordButton(
                        isRecording: recorder.isRecording,
                        onStart: { recorder.startRecording() },
                        onStop: {
                            recorder.stopRecording()
                            if let url = recorder.recordedURL {
                                do { try player.load(url: url) }
                                catch { uploadStatus = "❌ Preview load failed: \(error.localizedDescription)" }
                            }
                        }
                    )

                    // Preview
                    if player.isLoaded {
                        PreviewSection(
                            isPlaying: player.isPlaying,
                            currentTime: player.currentTime,
                            duration: player.duration,
                            onPlayPause: { player.playPause() },
                            onSeek: { player.seek(to: $0) },
                            onRerecord: {
                                player.stop()
                                recorder.discard()
                                uploadStatus = ""
                            },
                            formatTime: formatTime
                        )
                    }

                    // Drop options
                    DropOptionsSection(
                        whisperNameInput: $whisperNameInput,
                        radiusMeters: $radiusMeters,
                        useTimeLock: $useTimeLock,
                        selectedUnlockAt: $selectedUnlockAt,
                        requirePassword: $requirePassword,
                        passwordPlain: $passwordPlain
                    )

                    // Media picker
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
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Upload
                    if let url = recorder.recordedURL {
                        Button {
                            if player.isPlaying { player.playPause() }
                            attemptUploadOrPaywall(fileURL: url)
                        } label: {
                            Label("Upload & Save Whisper", systemImage: "icloud.and.arrow.up.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!whisperStore.isLoaded || requiresUsernameGate)
                        .opacity((!whisperStore.isLoaded || requiresUsernameGate) ? 0.6 : 1)

                    }

                    // Last whisper tools
                    if let wid = lastWhisperId {
                        LastWhisperToolsRow(
                            whisperId: wid,
                            onCopy: { UIPasteboard.general.string = wid },
                            onFund: {
                                if Auth.auth().currentUser == nil { showAuthSheet = true }
                                else { showMoneyHub = true }
                            }
                        )

                        NavigationLink {
                            AutoReleaseView(dropId: wid)
                        } label: {
                            Label("Open in Auto Release", systemImage: "bolt.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    // Location
                    if let loc = locationManager.lastLocation {
                        Text("📡 Location: \(loc.coordinate.latitude), \(loc.coordinate.longitude)")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("📡 Getting location…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Explore buttons
                    VStack(spacing: 10) {
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

                        NavigationLink {
                            AutoReleaseView(dropId: nil)
                        } label: {
                            Text("⚡ Auto Release")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    // Status banner
                    if !uploadStatus.isEmpty {
                        StatusBanner(
                            text: whisperStore.isLoaded ? uploadStatus : "Loading balance…",
                            icon: whisperStore.isLoaded ? "info.circle" : "hourglass"
                        )
                        .padding(.top, 4)
                    }
                }
                .padding()
            }

            // MARK: Navigation / Sheets
            .navigationDestination(isPresented: $showMap) { WhisperMapView() }
            .navigationDestination(isPresented: $showAR) { ARWhisperView().environmentObject(locationManager) }
            .navigationDestination(isPresented: $showMoneyHub) {
                MoneyHubContainer(initialWhisperId: lastWhisperId, initialName: whisperNameInput)
            }
            .navigationDestination(isPresented: $showWallet) { MyMoneyView() }
            .navigationDestination(isPresented: $showCryptoMode) { CryptoModeView() }

            .sheet(isPresented: $showPaywallSheet) {
                ScrollView { subscriptionInfoSection.padding() }
            }
            .sheet(isPresented: $showAuthSheet) {
                AuthScreen()
                    .environmentObject(auth)
                    .onChange(of: auth.user) { _, user in
                        if user != nil {
                            showAuthSheet = false
                            showWallet = true
                        }
                    }
                    .safeSheetDetents([.medium, .large])
                    .safeSheetCornerRadius(24)
            }
            .sheet(isPresented: $showInfoSheet) {
                ProInfoSheet()
                    .safeSheetDetents([.large])
                    .safeSheetCornerRadius(24)
            }
            .sheet(isPresented: $showUsernameSheet) {
                SetUsernameView(currentHandle: $currentHandle)
                    .safeSheetDetents([.medium])
                    .safeSheetCornerRadius(24)
                    .onDisappear {
                        Task { await refreshUsernameGateState() }
                    }
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
                            } catch { }
                        }
                    },
                    onLater: { showPayoutPrompt = false }
                )
                .safeSheetDetents([.medium])
                .safeSheetCornerRadius(24)
                
            }
            
            .alert("Your Username = Your Creator Code", isPresented: $showCreatorCodeAlert) {
                Button("I Understand") {
                    didAcknowledgeCreatorCode = true
                    showCreatorCodeAlert = false
                }
            } message: {
                Text("""
            Your username is your Creator Code.

            • It identifies you as the creator of whispers
            • It is used for payments, attribution, and rewards
            • It may be visible to other users

            You can change it later in Settings.
            """)
            }

        }
        .onAppear {
            locationManager.start()
            GeoWhisperManager.shared.configure()

            usernameCancellable = UsernameService.shared.usernamePublisher()
                .receive(on: DispatchQueue.main)
                .sink { name in
                    let cleaned = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

                    if !cleaned.isEmpty {
                        currentHandle = "@\(cleaned)"
                        requiresUsernameGate = false

                        if !didAcknowledgeCreatorCode {
                            showCreatorCodeAlert = true
                        }
                    } else {
                        currentHandle = nil
                        requiresUsernameGate = (Auth.auth().currentUser != nil)
                    }
                }


            Task { await evaluatePayoutPrompt() }
            
            
            walletStore.refresh()

            #if DEBUG
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
            #endif
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

    // MARK: - Subscription Info (non-Pro)

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
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)

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

    // MARK: - Upload gating (unchanged)

    private func attemptUploadOrPaywall(fileURL: URL) {
        guard whisperStore.isLoaded else {
            uploadStatus = "⏳ Loading your balance…"
            return
        }
        
        // ✅ Username gate hard block (if signed in but no username)
        if requiresUsernameGate {
            uploadStatus = "❌ Set your username (Creator Code) before uploading."
            showUsernameSheet = true
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

    // MARK: - Upload (unchanged)

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

    // MARK: - Save Whisper (unchanged)

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

    // MARK: - Media attachments (unchanged)

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
    
    // ✅ Gate Refresh Helper (forces username state after sheet closes)
    private func refreshUsernameGateState() async {
        guard let uid = Auth.auth().currentUser?.uid else {
            await MainActor.run {
                requiresUsernameGate = false
                currentHandle = nil
            }
            return
        }

        do {
            let snap = try await Firestore.firestore().collection("users").document(uid).getDocument()
            let raw = (snap.data()?["username"] as? String) ?? (snap.data()?["handle"] as? String) ?? ""
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            await MainActor.run {
                if !cleaned.isEmpty {
                    currentHandle = "@\(cleaned)"
                    requiresUsernameGate = false
                } else {
                    currentHandle = nil
                    requiresUsernameGate = true
                }
            }
        } catch {
            // keep current state if fetch fails
        }
    }

    // MARK: - Wallet / Payout prompt logic (unchanged)

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

// MARK: - Pro Info (kept intact) ✅ (Fixes "Cannot find ProInfoSheet in scope")

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

// MARK: - Subviews (UI only; no logic moved)

private struct HomeHeaderRow: View {
    let title: String
    let showsBalanceBadge: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Label {
                Text(title)
                    .font(.largeTitle.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } icon: {
                Text("📍")
                    .font(.largeTitle)
                    .padding(.trailing, -4)
            }

            Spacer(minLength: 8)

            if showsBalanceBadge {
                BalanceBadge()
            }
        }
        .padding(.top, 6) // helps prevent top overlap on Dynamic Island devices
    }
}



private struct HomeActionChipsGrid: View {
    let currentHandle: String?
    let onHelp: () -> Void
    let onUsername: () -> Void
    let onWallet: () -> Void
    let onAddMoney: () -> Void
    let onCryptoMode: () -> Void
    let onSupport: () -> Void

    private let rows: [GridItem] = [
        GridItem(.fixed(72), spacing: 12),
        GridItem(.fixed(72), spacing: 12)
    ]

    var body: some View {
        let items: [(String, String, () -> Void)] = [
            ("questionmark.circle", "Help", onHelp),
            ("at.circle.fill", currentHandle ?? "Username", onUsername),
            ("wallet.pass.fill", "Wallet", onWallet),
            ("creditcard.fill", "Add Money", onAddMoney),
            ("bitcoinsign.circle.fill", "Crypto Mode", onCryptoMode),
            ("bubble.left.and.bubble.right", "Support", onSupport)
        ]

        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: rows, alignment: .center, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    ChipButton(systemImage: item.0, title: item.1, action: item.2)
                        .frame(width: 104)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
    }
}



private struct PlanStatusSection: View {
    let isPro: Bool
    let freeUploads: Int
    let onViewPro: () -> Void
    let onEnableAlerts: () -> Void
    let onHelp: () -> Void

    var body: some View {
        if isPro {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                Text("Premium Active")
                    .font(.subheadline)
                    .foregroundColor(.green)
                Spacer()
                Button(action: onHelp) {
                    Label("Help", systemImage: "questionmark.circle")
                }
                .buttonStyle(.bordered)
            }
        } else {
            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("EchoTether Pro").font(.headline)
                        Text("Your first 100 uploads are free.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("View Pro", action: onViewPro)
                        .buttonStyle(.borderedProminent)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background alerts").font(.subheadline).bold()
                        Text("Get notified when a whisper unlocks nearby.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Enable", action: onEnableAlerts)
                        .buttonStyle(.bordered)
                }

                Text("Free uploads left: \(freeUploads)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }
}

private struct WalletCreditsBox: View {
    let isLoading: Bool
    let walletCents: Int
    let walletError: String?
    let freeUploads: Int

    var body: some View {
        GroupBox("Money & Credits") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Wallet balance", systemImage: "creditcard.and.123")
                    Spacer()
                    if isLoading {
                        ProgressView()
                    } else {
                        Text(String(format: "$%.2f", Double(walletCents) / 100.0))
                            .font(.headline)
                            .monospacedDigit()
                    }
                }

                if let err = walletError {
                    Text("Wallet error: \(err)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Divider().padding(.vertical, 4)

                HStack {
                    Label("Free uploads", systemImage: "bubble.left.and.bubble.right")
                    Spacer()
                    Text("\(freeUploads)")
                        .font(.subheadline.monospacedDigit())
                }

                Text("Free uploads are used for recording & dropping whispers. Money in your wallet is for funding whispers and Auto Release.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PrimaryRecordButton: View {
    let isRecording: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        Button {
            isRecording ? onStop() : onStart()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title2)

                Text(isRecording ? "Stop Recording" : "Start Recording")
                    .font(.headline)

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(isRecording ? .red : .blue)
        .controlSize(.large)
    }
}

private struct PreviewSection: View {
    let isPlaying: Bool
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onPlayPause: () -> Void
    let onSeek: (TimeInterval) -> Void
    let onRerecord: () -> Void
    let formatTime: (TimeInterval) -> String

    var body: some View {
        GroupBox("Preview Your Whisper") {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Button(action: onPlayPause) {
                        Label(isPlaying ? "Pause" : "Play",
                              systemImage: isPlaying ? "pause.circle" : "play.circle")
                    }
                    .buttonStyle(.bordered)

                    Slider(
                        value: Binding(
                            get: { currentTime },
                            set: { onSeek($0) }
                        ),
                        in: 0...(max(duration, 1))
                    )

                    Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(minWidth: 90, alignment: .trailing)
                }

                HStack {
                    Button(role: .destructive, action: onRerecord) {
                        Label("Re-record", systemImage: "arrow.counterclockwise.circle")
                    }
                    Spacer()
                }
            }
            .padding(.top, 4)
        }
    }
}

private struct DropOptionsSection: View {
    @Binding var whisperNameInput: String
    @Binding var radiusMeters: Double
    @Binding var useTimeLock: Bool
    @Binding var selectedUnlockAt: Date
    @Binding var requirePassword: Bool
    @Binding var passwordPlain: String

    var body: some View {
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
    }
}

private struct LastWhisperToolsRow: View {
    let whisperId: String
    let onCopy: () -> Void
    let onFund: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Whisper ID:")
            Text(whisperId)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Button(action: onFund) {
                Label("Fund", systemImage: "creditcard")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Safe sheet helpers (fixes `.large` inference + iOS availability issues cleanly)

private extension View {
    @ViewBuilder
    func safeSheetDetents(_ detents: [PresentationDetent]) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents(Set(detents))
        } else {
            self
        }
    }

    @ViewBuilder
    func safeSheetCornerRadius(_ radius: CGFloat) -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCornerRadius(radius)
        } else {
            self
        }
    }
}
