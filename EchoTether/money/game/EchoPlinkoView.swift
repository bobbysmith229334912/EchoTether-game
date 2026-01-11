//
//  EchoPlinkoView.swift
//  EchoTether
//
//  Echo Plinko — REAL wallet money (Stripe/Firestore)
//  + Location-based Ball Skins (ball pouch)
//
//  IMPORTANT:
//  - House edge is enforced in Cloud Function: games_playEchoPlinko
//  - This view is purely visual + wallet UI
//  - Plinko funds are topped up via Cloud Function: wallet_createTopUpCheckoutSession
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import CoreLocation

// MARK: - Ball Skin Model & Catalog

private struct BallSkin: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let primaryColor: Color
    let badgeDescription: String
    /// Optional ISO country code this skin is unlocked from (e.g., "JP")
    let countryCode: String?
}

private enum BallSkinCatalog {
    /// Default ball everyone has
    static let defaultSkin = BallSkin(
        id: "default",
        name: "Classic Echo",
        emoji: "🔵",
        primaryColor: .blue,
        badgeDescription: "Standard Echo ball.",
        countryCode: nil
    )

    // Location-themed skins
    static let japanSkin = BallSkin(
        id: "japan",
        name: "Tokyo Drop",
        emoji: "🗼",
        primaryColor: .red,
        badgeDescription: "Unlocked in Japan (JP).",
        countryCode: "JP"
    )

    static let usaSkin = BallSkin(
        id: "usa",
        name: "Stars & Stripes",
        emoji: "🗽",
        primaryColor: .red,
        badgeDescription: "Unlocked in the USA (US).",
        countryCode: "US"
    )

    static let ukSkin = BallSkin(
        id: "uk",
        name: "London Echo",
        emoji: "🎡",
        primaryColor: .purple,
        badgeDescription: "Unlocked in the UK (GB).",
        countryCode: "GB"
    )

    static let brazilSkin = BallSkin(
        id: "brazil",
        name: "Rio Bounce",
        emoji: "🎉",
        primaryColor: .green,
        badgeDescription: "Unlocked in Brazil (BR).",
        countryCode: "BR"
    )

    static let all: [BallSkin] = [
        defaultSkin,
        japanSkin,
        usaSkin,
        ukSkin,
        brazilSkin
    ]

    static func skin(for id: String) -> BallSkin {
        all.first(where: { $0.id == id }) ?? defaultSkin
    }

    static func skinsFor(countryCode: String) -> [BallSkin] {
        let code = countryCode.uppercased()
        return all.filter { $0.countryCode?.uppercased() == code }
    }
}

// MARK: - Location Helper (no main-thread location access)

private final class PlinkoLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    /// Callback fired when we resolve a country code like "US", "JP", etc.
    var onCountryCode: ((String) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    func start() {
        guard CLLocationManager.locationServicesEnabled() else { return }
        manager.requestWhenInUseAuthorization()
    }

    // iOS 14+ unified callback
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            // Safe: ask Core Location for one location; result comes via delegate
            manager.requestLocation()
        case .denied, .restricted, .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }

        // Reverse-geocode OFF the main thread using async/await
        Task {
            let geocoder = CLGeocoder()
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(loc)
                if let code = placemarks.first?.isoCountryCode {
                    // Hand result back to the view on the main thread
                    await MainActor.run { [weak self] in
                        self?.onCountryCode?(code)
                    }
                }
            } catch {
                print("reverseGeocode error:", error)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("PlinkoLocationManager didFailWithError:", error)
    }
}

// MARK: - EchoPlinkoView

struct EchoPlinkoView: View {
    // MARK: - Config

    /// Available entry costs in cents (like 0.25, 0.50, 1.00, etc.)
    private let entryCostOptionsCents: [Int] = [25, 50, 100]   // $0.25, $0.50, $1.00

    /// Plinko board layout (visual only – backend controls real result)
    private let boardColumns = 7
    private let boardRows = 10
    private let slotMultipliers: [Double] = [0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0]

    // MARK: - Wallet / backend state

    @State private var walletCents: Int? = nil
    @State private var isLoadingWallet = false
    @State private var isPlaying = false
    @State private var errorMessage: String?

    @State private var lastResultTitle: String?
    @State private var lastResultDetail: String?

    // MARK: - Game animation state

    @State private var chipPosition: (row: Int, col: Int)?
    @State private var isDropping = false
    @State private var lastSlotIndex: Int?
    @State private var dropTask: Task<Void, Never>? = nil

    // MARK: - Ball pouch / skins state

    @State private var unlockedSkinIds: Set<String> = [BallSkinCatalog.defaultSkin.id]
    @State private var activeSkinId: String = BallSkinCatalog.defaultSkin.id
    @State private var showBallPouch = false

    // MARK: - UI state

    @State private var selectedEntryIndex: Int = 0
    @State private var showAddFundsSheet = false

    // MARK: - Services

    private let db = Firestore.firestore()
    private let functions = Functions.functions()

    @StateObject private var locationManager = PlinkoLocationManager()

    // MARK: - Computed helpers

    private var selectedEntryCostCents: Int {
        entryCostOptionsCents[selectedEntryIndex]
    }

    private var formattedSelectedEntryCost: String {
        String(format: "$%.2f", Double(selectedEntryCostCents) / 100.0)
    }

    private func formattedAmount(_ cents: Int?) -> String {
        guard let cents = cents else { return "--" }
        return String(format: "$%.2f", Double(cents) / 100.0)
    }

    private var formattedBalance: String {
        formattedAmount(walletCents)
    }

    private var canAffordPlay: Bool {
        guard let cents = walletCents else { return false }
        return cents >= selectedEntryCostCents
    }

    private var isBusy: Bool {
        isLoadingWallet || isPlaying || isDropping
    }

    private var activeSkin: BallSkin {
        BallSkinCatalog.skin(for: activeSkinId)
    }

    private var unlockedSkins: [BallSkin] {
        BallSkinCatalog.all.filter { unlockedSkinIds.contains($0.id) }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                balanceSection
                betPickerSection
                boardSection
                potentialWinsSection
                ballPouchSection
                rulesSection
                playSection

                if lastResultTitle != nil || lastResultDetail != nil {
                    resultSection
                }

                if let error = errorMessage {
                    GroupBox {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Spacer(minLength: 20)
            }
            .padding()
        }
        .navigationTitle("Echo Plinko")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddFundsSheet = true
                } label: {
                    Label("Add Funds", systemImage: "plus.circle.fill")
                }
            }
        }
        .sheet(isPresented: $showAddFundsSheet) {
            // 🔹 Dedicated Plinko top-up sheet (Stripe Checkout).
            PlinkoAddFundsSheet {
                // Reload wallet after user closes the sheet / completes payment
                loadWallet()
            }
        }
        .onAppear {
            loadWallet()

            Task {
                await loadBallPouchFromFirestore()
            }

            // Wire the location manager callback to unlock skins
            locationManager.onCountryCode = { code in
                Task { @MainActor in
                    await unlockSkins(for: code)
                }
            }

            locationManager.start()
        }
        .onDisappear {
            // Cancel any running drop animation
            dropTask?.cancel()
            dropTask = nil
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Echo Plinko")
                    .font(.largeTitle.bold())
                Spacer()
                Button {
                    showBallPouch = true
                } label: {
                    Label("Ball Pouch", systemImage: "circle.grid.3x3.fill")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                }
                .sheet(isPresented: $showBallPouch) {
                    ballPouchSheet
                }
            }

            Text("Drop chips using your **Plinko cash balance**. Each round costs your selected entry amount, and winnings go straight back into your balance.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                startTestDropAnimation()
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                    Text("Test Drop (no money)")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text("Test Drop is for animation only and never touches your balance or the server.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var balanceSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Plinko Balance")
                            .font(.subheadline.weight(.semibold))
                        Text("Real money loaded just for playing Echo Plinko.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isLoadingWallet && walletCents == nil {
                        ProgressView()
                    } else {
                        Text(formattedBalance)
                            .font(.title3.bold())
                            .monospacedDigit()
                    }
                }

                Button {
                    showAddFundsSheet = true
                } label: {
                    Label("Add Funds for Plinko", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
    }

    private var betPickerSection: some View {
        GroupBox("Bet Size") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Entry", selection: $selectedEntryIndex) {
                    ForEach(entryCostOptionsCents.indices, id: \.self) { idx in
                        let cost = entryCostOptionsCents[idx]
                        Text(String(format: "$%.2f", Double(cost) / 100.0))
                            .tag(idx)
                    }
                }
                .pickerStyle(.segmented)

                Text("Each play will cost **\(formattedSelectedEntryCost)** from your Plinko balance.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var boardSection: some View {
        GroupBox("Board") {
            VStack(spacing: 12) {
                PlinkoBoardView(
                    rows: boardRows,
                    columns: boardColumns,
                    chipPosition: chipPosition,
                    slotMultipliers: slotMultipliers,
                    chipColor: activeSkin.primaryColor,
                    chipEmoji: activeSkin.emoji
                )
                .frame(height: 260)

                if let idx = lastSlotIndex,
                   idx >= 0,
                   idx < slotMultipliers.count {
                    let mult = slotMultipliers[idx]
                    Text("Last landing slot: x\(String(format: "%.1f", mult))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap **Play** or **Test Drop** to drop a chip.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var potentialWinsSection: some View {
        GroupBox("Potential Wins") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(slotMultipliers.indices, id: \.self) { idx in
                    let mult = slotMultipliers[idx]
                    let payoutCents = Int(Double(selectedEntryCostCents) * mult)
                    HStack {
                        Text("Slot \(idx + 1)")
                        Spacer()
                        Text("x\(String(format: "%.1f", mult)) → \(formattedAmount(payoutCents))")
                            .monospacedDigit()
                    }
                    .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var ballPouchSection: some View {
        GroupBox("Ball Pouch (travel unlocks skins)") {
            VStack(alignment: .leading, spacing: 8) {
                if unlockedSkins.isEmpty {
                    Text("Play once to unlock your first ball.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(BallSkinCatalog.all) { skin in
                                let isUnlocked = unlockedSkinIds.contains(skin.id)
                                let isActive = activeSkinId == skin.id

                                Button {
                                    if isUnlocked {
                                        activeSkinId = skin.id
                                        Task { await saveBallPouchToFirestore() }
                                    }
                                } label: {
                                    VStack(spacing: 4) {
                                        ZStack {
                                            Circle()
                                                .fill(isUnlocked ? skin.primaryColor : .gray.opacity(0.3))
                                                .frame(width: 32, height: 32)
                                            Text(skin.emoji)
                                                .font(.caption)
                                        }
                                        Text(skin.name)
                                            .font(.caption2)
                                            .lineLimit(1)
                                        if !isUnlocked {
                                            Text("Locked")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        } else if isActive {
                                            Text("Active")
                                                .font(.caption2.weight(.semibold))
                                        }
                                    }
                                    .padding(6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(
                                                isActive ? Color.accentColor : Color.secondary.opacity(0.2),
                                                lineWidth: 1
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(!isUnlocked)
                            }
                        }
                    }
                }

                Text("Travel to different countries and play Echo Plinko to discover special ball skins. When a new skin appears, tap **Use** to make it your active skin.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var ballPouchSheet: some View {
        NavigationStack {
            List {
                ForEach(BallSkinCatalog.all) { skin in
                    let isUnlocked = unlockedSkinIds.contains(skin.id)
                    let isActive = activeSkinId == skin.id

                    HStack {
                        ZStack {
                            Circle()
                                .fill(isUnlocked ? skin.primaryColor : .gray.opacity(0.3))
                                .frame(width: 32, height: 32)
                            Text(skin.emoji)
                                .font(.caption)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skin.name)
                                .font(.headline)
                            Text(skin.badgeDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isActive {
                            Text("Active")
                                .font(.caption2.bold())
                                .padding(6)
                                .background(
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.15))
                                )
                        } else if isUnlocked {
                            Button("Use") {
                                activeSkinId = skin.id
                                Task { await saveBallPouchToFirestore() }
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Text("Locked")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Ball Pouch")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showBallPouch = false }
                }
            }
        }
    }

    private var rulesSection: some View {
        GroupBox("How This Works") {
            VStack(alignment: .leading, spacing: 6) {
                Text("• Choose your **bet size** above.")
                Text("• Each paid play costs that amount from your Plinko balance.")
                Text("• The chip bounces down the board and lands in a slot with a multiplier.")
                Text("• The backend applies the official result to your balance (cost minus winnings, if any).")
                Text("• Use **Test Drop (no money)** above to try the animation without spending anything.")
                Text("• You must be signed in and have enough funds to play for real.")
                Text("• Ball colors & emojis come from your **Ball Pouch** skins. Travel to unlock more.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var playSection: some View {
        GroupBox("Play") {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    startDropAnimationAndPlay()
                } label: {
                    HStack {
                        if isBusy {
                            ProgressView()
                        } else {
                            Image(systemName: "play.circle.fill")
                        }
                        Text(playButtonTitle)
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || !canAffordPlay)

                if !canAffordPlay {
                    Text("Not enough Plinko funds. Add money to your Plinko balance to play.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var playButtonTitle: String {
        if isDropping {
            return "Dropping…"
        } else if isPlaying {
            return "Resolving…"
        } else if isLoadingWallet {
            return "Loading balance…"
        } else {
            return "Play for \(formattedSelectedEntryCost)"
        }
    }

    private var resultSection: some View {
        GroupBox("Last Result") {
            VStack(alignment: .leading, spacing: 4) {
                if let title = lastResultTitle {
                    Text(title)
                        .font(.headline)
                }
                if let detail = lastResultDetail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Game flow

    /// Starts the visual chip drop, then calls the backend once it lands (REAL MONEY).
    private func startDropAnimationAndPlay() {
        guard Auth.auth().currentUser != nil else {
            errorMessage = "Sign in to play."
            return
        }
        guard canAffordPlay else {
            errorMessage = "Not enough Plinko funds. Add more money first."
            return
        }
        guard !isBusy else { return }

        // Reset state
        errorMessage = nil
        lastResultTitle = nil
        lastResultDetail = nil
        lastSlotIndex = nil

        // Start in the middle column
        var row = 0
        var col = boardColumns / 2

        chipPosition = (row, col)
        isDropping = true

        // Cancel any previous animation
        dropTask?.cancel()
        dropTask = Task {
            // Animate down the board
            while row < boardRows - 1 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000) // 0.15s per step

                row += 1

                if row < boardRows - 1 {
                    let direction = Int.random(in: 0...1) == 0 ? -1 : 1
                    col = max(0, min(boardColumns - 1, col + direction))
                }

                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        chipPosition = (row, col)
                    }
                }
            }

            // Final slot index
            let clampedCol = max(0, min(boardColumns - 1, col))
            let slotIndex = min(max(clampedCol, 0), slotMultipliers.count - 1)

            await MainActor.run {
                lastSlotIndex = slotIndex
                isDropping = false
            }

            // Let the chip sit briefly at the bottom
            try? await Task.sleep(nanoseconds: 400_000_000)

            // Fade chip out so it does NOT stay on screen
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) {
                    chipPosition = nil
                }
            }

            // If animation was cancelled (view disappeared), don't call backend
            if Task.isCancelled { return }

            // Once animation is done, call backend for real-money logic
            await playRound()
        }
    }

    /// TEST ONLY: runs the chip animation WITHOUT touching wallet or backend.
    private func startTestDropAnimation() {
        guard !isDropping else { return }

        errorMessage = nil
        lastResultTitle = nil
        lastResultDetail = nil
        lastSlotIndex = nil

        var row = 0
        var col = boardColumns / 2

        chipPosition = (row, col)
        isDropping = true

        dropTask?.cancel()
        dropTask = Task {
            while row < boardRows - 1 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)

                row += 1

                if row < boardRows - 1 {
                    let direction = Int.random(in: 0...1) == 0 ? -1 : 1
                    col = max(0, min(boardColumns - 1, col + direction))
                }

                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        chipPosition = (row, col)
                    }
                }
            }

            let clampedCol = max(0, min(boardColumns - 1, col))
            let slotIndex = min(max(clampedCol, 0), slotMultipliers.count - 1)

            await MainActor.run {
                lastSlotIndex = slotIndex
                isDropping = false
            }

            // Hold at bottom briefly
            try? await Task.sleep(nanoseconds: 400_000_000)

            // Fade chip out
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.25)) {
                    chipPosition = nil
                }
            }
        }
    }

    // MARK: - Data

    private func loadWallet() {
        guard let user = Auth.auth().currentUser else {
            walletCents = nil
            errorMessage = "Sign in to play for real money."
            return
        }

        isLoadingWallet = true
        errorMessage = nil

        db.collection("users").document(user.uid).getDocument { snap, error in
            DispatchQueue.main.async {
                self.isLoadingWallet = false
                if let error = error {
                    self.errorMessage = "Failed to load Plinko balance: \(error.localizedDescription)"
                    return
                }
                // 🔹 Using availableCents as the Plinko balance field.
                let centsValue = (snap?.data()?["availableCents"] as? Int) ?? 0
                self.walletCents = centsValue
            }
        }
    }

    /// Calls Cloud Function `games_playEchoPlinko` to handle ALL real-money logic.
    private func playRound() async {
        guard Auth.auth().currentUser != nil else {
            await MainActor.run {
                errorMessage = "Sign in to play."
            }
            return
        }

        await MainActor.run {
            isPlaying = true
        }

        do {
            let callable = functions.httpsCallable("games_playEchoPlinko")
            let result = try await callable.call([
                "entryCostCents": selectedEntryCostCents
            ])

            let data = result.data as? [String: Any] ?? [:]
            let newBalance = data["newBalanceCents"] as? Int ?? walletCents ?? 0
            let message = data["message"] as? String ?? "Round completed."

            let winCents = data["winAmountCents"] as? Int
            let multiplier = data["multiplier"] as? Double

            await MainActor.run {
                self.walletCents = newBalance
                self.lastResultTitle = message

                if let winCents, let multiplier {
                    let winStr = String(format: "$%.2f", Double(winCents) / 100.0)
                    let multStr = String(format: "%.2fx", multiplier)
                    self.lastResultDetail = "You won \(winStr) (\(multStr) on a \(formattedSelectedEntryCost) entry)."
                } else {
                    self.lastResultDetail = nil
                }

                self.isPlaying = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "Play failed: \(error.localizedDescription)"
                self.isPlaying = false
            }
            loadWallet()
        }
    }

    // MARK: - Ball pouch Firestore helpers

    private func loadBallPouchFromFirestore() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = db.collection("users").document(uid)

        do {
            let snap = try await ref.getDocument()
            guard let data = snap.data() else { return }

            let unlockedIds = data["unlockedBallSkinIds"] as? [String] ?? [BallSkinCatalog.defaultSkin.id]
            let activeId = data["activeBallSkinId"] as? String ?? BallSkinCatalog.defaultSkin.id

            await MainActor.run {
                self.unlockedSkinIds = Set(unlockedIds)
                self.activeSkinId = activeId
            }
        } catch {
            print("loadBallPouchFromFirestore error:", error)
        }
    }

    private func saveBallPouchToFirestore() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = db.collection("users").document(uid)

        let data: [String: Any] = [
            "unlockedBallSkinIds": Array(unlockedSkinIds),
            "activeBallSkinId": activeSkinId,
            "updatedAt": Timestamp(date: Date())
        ]

        do {
            try await ref.setData(data, merge: true)
        } catch {
            print("saveBallPouchToFirestore error:", error)
        }
    }

    // MARK: - Country → unlock skins

    private func unlockSkins(for countryCode: String) async {
        let skins = BallSkinCatalog.skinsFor(countryCode: countryCode)
        guard !skins.isEmpty else { return }

        var changed = false
        for skin in skins where !unlockedSkinIds.contains(skin.id) {
            unlockedSkinIds.insert(skin.id)
            activeSkinId = skin.id
            changed = true
        }

        if changed {
            await saveBallPouchToFirestore()
        }
    }
}

// MARK: - PlinkoBoardView (purely visual)

private struct PlinkoBoardView: View {
    let rows: Int
    let columns: Int
    let chipPosition: (row: Int, col: Int)?
    let slotMultipliers: [Double]
    let chipColor: Color
    let chipEmoji: String

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let colSpacing = width / CGFloat(columns + 1)
            let rowSpacing = height / CGFloat(rows + 1)

            ZStack {
                // Pegs
                ForEach(0..<rows, id: \.self) { row in
                    ForEach(0..<columns, id: \.self) { col in
                        Circle()
                            .frame(width: 7, height: 7)
                            .foregroundStyle(.secondary)
                            .position(
                                x: colSpacing * CGFloat(col + 1),
                                y: rowSpacing * CGFloat(row + 1)
                            )
                    }
                }

                // Chip
                if let chip = chipPosition {
                    ZStack {
                        Circle()
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle()
                                    .strokeBorder(.white.opacity(0.8), lineWidth: 2)
                            )
                            .shadow(radius: 4)
                            .foregroundStyle(chipColor)
                        Text(chipEmoji)
                            .font(.caption2)
                    }
                    .position(
                        x: colSpacing * CGFloat(chip.col + 1),
                        y: rowSpacing * CGFloat(chip.row + 1)
                    )
                    .animation(.easeInOut(duration: 0.15), value: chip.row)
                    .animation(.easeInOut(duration: 0.15), value: chip.col)
                }

                // Bottom slots (multiplier labels)
                VStack {
                    Spacer()
                    HStack(spacing: 0) {
                        ForEach(0..<columns, id: \.self) { col in
                            let idx = min(col, slotMultipliers.count - 1)
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                                    .frame(height: 18)
                                Text("x\(String(format: "%.1f", slotMultipliers[idx]))")
                                    .font(.caption2)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
    }
}

// MARK: - PlinkoAddFundsSheet (dedicated Stripe top-up for Plinko)

private struct PlinkoAddFundsSheet: View {
    let onCompleted: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var amountUSD: String = "5"
    @State private var isLoading = false
    @State private var errorText: String = ""

    private let functions = Functions.functions()

    private let successURL = "https://hardcoreamature.com/registration-complete/"
    private let cancelURL  = "https://hardcoreamature.com/stripe-registration-failed/"

    var body: some View {
        NavigationStack {
            Form {
                Section("Add Plinko Funds") {
                    HStack {
                        Text("$")
                        TextField("Amount (USD)", text: $amountUSD)
                            .keyboardType(.numberPad)
                    }

                    HStack(spacing: 8) {
                        ForEach([5, 10, 20, 50], id: \.self) { v in
                            Button("$\(v)") { amountUSD = "\(v)" }
                                .buttonStyle(.bordered)
                                .disabled(isLoading)
                        }
                    }

                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        startCheckout()
                    } label: {
                        HStack {
                            if isLoading { ProgressView() }
                            Text(isLoading ? "Opening…" : "Continue to Payment")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isLoading || !isValid)
                    .opacity(isLoading ? 0.5 : 1.0)
                }
            }
            .navigationTitle("Add Plinko Funds")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                        onCompleted()
                    }
                    .disabled(isLoading)
                }
            }
        }
    }

    private var isValid: Bool {
        guard let dollars = Int(amountUSD), dollars > 0 else { return false }
        return true
    }

    @MainActor
    private func setError(_ message: String) {
        errorText = message
    }

    // NOTE: this is sync; it spawns its own Task and guards isLoading
    private func startCheckout() {
        // HARD GUARD: if already running, bail immediately
        if isLoading { return }

        Task { @MainActor in
            setError("")

            guard isValid else {
                setError("Enter a valid amount.")
                return
            }
            guard Auth.auth().currentUser != nil else {
                setError("You must be signed in.")
                return
            }

            let dollars = Int(amountUSD) ?? 0
            isLoading = true

            do {
                let callable = functions.httpsCallable("wallet_createTopUpCheckoutSession")
                let result = try await callable.call([
                    "amountUSD": dollars,
                    "successUrl": successURL,
                    "cancelUrl": cancelURL
                ])

                guard
                    let dict = result.data as? [String: Any],
                    let urlStr = dict["url"] as? String,
                    let url = URL(string: urlStr)
                else {
                    setError("Could not start checkout.")
                    isLoading = false
                    return
                }

                openURL(url)
                isLoading = false
            } catch {
                setError("Checkout error: \(error.localizedDescription)")
                isLoading = false
            }
        }
    }
}
