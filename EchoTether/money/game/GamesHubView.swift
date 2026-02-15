//
//  GamesHubView.swift
//  EchoTether
//
//  Games use REAL wallet money (Stripe/Firestore), not free whisper credits.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore

struct GamesHubView: View {

    // MARK: - Game selection
    private enum ActiveGame {
        case plinko
        case bubblePop
    }

    // Wallet balance in cents from Firestore: users/{uid}.availableCents
    @State private var walletCents: Int? = nil
    @State private var isLoading = true
    @State private var errorMessage: String?

    // Present dedicated wallet screen (Stripe add money JUST for games)
    @State private var showWalletSheet = false

    // Shared age gate + game sheet
    @State private var pendingGame: ActiveGame? = nil
    @State private var activeGame: ActiveGame? = nil
    @State private var showAgeGate = false
    @State private var showGameSheet = false

    private var formattedBalance: String {
        guard let cents = walletCents else { return "--" }
        return String(format: "$%.2f", Double(cents) / 100.0)
    }

    var body: some View {
        List {
            headerSection
            balanceSection

            if Auth.auth().currentUser == nil {
                notSignedInSection
            } else {
                availableGamesSection
            }

            comingSoonSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Games")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadWalletBalance()
        }
        .sheet(isPresented: $showWalletSheet, onDismiss: {
            // Reload wallet after Stripe checkout completes
            loadWalletBalance()
        }) {
            WalletAddFundsSheet()
        }
        // 🔒 Age gate alert for all real-money games
        .alert("Age & Legal Confirmation",
               isPresented: $showAgeGate) {
            Button("Yes, I’m 18+ and allowed", role: .none) {
                if let pending = pendingGame {
                    activeGame = pending
                    pendingGame = nil
                    showGameSheet = true
                }
            }
            Button("No", role: .cancel) {
                pendingGame = nil
                activeGame = nil
            }
        } message: {
            Text("""
These games use REAL money from your EchoTether game wallet.

By continuing, you confirm:
• You are at least 18 years old (or the legal age in your region).
• You understand this is a real-money game and not free whispers.
• You are playing in a location where this type of game is allowed.
""")
        }
        // 🧩 Present the selected game in a sheet
        .sheet(isPresented: $showGameSheet, onDismiss: {
            activeGame = nil
        }) {
            NavigationStack {
                Group {
                    switch activeGame {
                    case .plinko:
                        EchoPlinkoView()
                    case .bubblePop:
                        BubblePopGameView() // ✅ matches stub below, compiles
                    case .none:
                        ContentUnavailableView("No game selected",
                                               systemImage: "gamecontroller",
                                               description: Text("Pick a game from the list to start playing."))
                    }
                }
                .navigationTitle(navTitle(for: activeGame))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    // MARK: - Helper

    private func navTitle(for game: ActiveGame?) -> String {
        switch game {
        case .plinko:
            return "Echo Plinko"
        case .bubblePop:
            return "Bubble Pop"
        case .none:
            return "Game"
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "gamecontroller.fill")
                        .imageScale(.large)
                    Text("Games")
                        .font(.largeTitle.bold())
                }

                Text("Play mini-games using your cash wallet balance. Echo Plinko and Bubble Pop are the first — more games are coming soon.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var balanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your Game Wallet")
                            .font(.subheadline.weight(.semibold))
                        Text("Money loaded via Add Funds / Stripe (not free whispers).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isLoading {
                        ProgressView()
                    } else if let message = errorMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text(formattedBalance)
                            .font(.title2.bold())
                            .monospacedDigit()
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        showWalletSheet = true
                    } label: {
                        Label("Add Funds", systemImage: "plus.circle.fill")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var notSignedInSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Sign in to play for money", systemImage: "person.fill.questionmark")
                    .font(.headline)

                Text("Games use your real EchoTether wallet balance. Sign in and add funds using the Add Funds button above.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var availableGamesSection: some View {
        Section("Available Games") {

            // Echo Plinko row
            Button {
                pendingGame = .plinko
                showAgeGate = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "target")
                            .imageScale(.large)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Echo Plinko")
                            .font(.headline)
                        Text("Drop chips down a themed board using your game wallet for entries and unlock EchoTether rewards.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .imageScale(.medium)
                        .foregroundStyle(Color.secondary.opacity(0.6))
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            // Bubble Pop row
            Button {
                pendingGame = .bubblePop
                showAgeGate = true
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.pink.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "circle.grid.3x3.fill")
                            .imageScale(.large)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bubble Pop")
                            .font(.headline)
                        Text("Tap popping bubbles against the clock using your game wallet for entries and chase high-score rewards.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .imageScale(.medium)
                        .foregroundStyle(Color.secondary.opacity(0.6))
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
    }

    private var comingSoonSection: some View {
        Section("Coming Soon") {
            VStack(alignment: .leading, spacing: 8) {
                Label("Daily streak bonuses", systemImage: "calendar.badge.clock")
                Label("Head-to-head games with friends", systemImage: "person.2.crop.square.stack")
                Label("Location-based game boards", systemImage: "map.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Firestore wallet load

    /// Load REAL money balance from Firestore: users/{uid}.availableCents
    private func loadWalletBalance() {
        guard let user = Auth.auth().currentUser else {
            isLoading = false
            walletCents = nil
            errorMessage = "Not signed in"
            return
        }

        isLoading = true
        errorMessage = nil

        Firestore.firestore()
            .collection("users")
            .document(user.uid)
            .getDocument { snap, error in
                DispatchQueue.main.async {
                    self.isLoading = false

                    if let error = error {
                        self.errorMessage = "Error: \(error.localizedDescription)"
                        self.walletCents = nil
                        return
                    }

                    let cents = (snap?.data()?["availableCents"] as? Int) ?? 0
                    self.walletCents = cents
                }
            }
    }
}

// MARK: - Temporary stub for Bubble Pop game

struct BubblePopGameView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 42))

            Text("Bubble Pop")
                .font(.largeTitle.bold())

            Text("This is a placeholder screen. We’ll wire up the real Bubble Pop gameplay next.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Spacer(minLength: 0)
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
    }
}
