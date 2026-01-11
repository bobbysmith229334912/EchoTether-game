//
//  WalletView.swift
//  EchoTether
//
//  Created by Bobby Smith on 10/21/25.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore

fileprivate func dollars(from cents: Int) -> String {
    let amount = Double(cents) / 100.0
    return String(format: "$%.2f", amount)
}

struct WalletView: View {
    @State private var availableCents: Int = 0
    @State private var pendingCents: Int = 0
    @State private var payoutStatus: PayoutStatus = .unknown

    @State private var loading = true
    @State private var errorText: String?
    @State private var doingAction = false
    @State private var cashOutAmount: String = "" // optional custom amount

    private var uid: String? { Auth.auth().currentUser?.uid }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {

                // SUMMARY CARD
                GroupBox {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Wallet")
                                .font(.title2).bold()

                            HStack(spacing: 12) {
                                VStack(alignment: .leading) {
                                    Text("Available")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(dollars(from: availableCents))
                                        .font(.title).bold()
                                }
                                Divider().frame(height: 32)
                                VStack(alignment: .leading) {
                                    Text("Pending")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(dollars(from: pendingCents))
                                        .font(.title3).bold()
                                }
                            }
                        }
                        Spacer()
                    }
                }

                // STATUS / WARNING
                Group {
                    switch payoutStatus {
                    case .unknown:
                        EmptyView()
                    case .notCreated:
                        BannerView(
                            icon: "exclamationmark.triangle.fill",
                            title: "Set up cash-out",
                            message: "You’ve got money here. Connect your payout account to withdraw."
                        )
                    case let .created(_, payoutsEnabled, accountId):
                        if !payoutsEnabled {
                            BannerView(
                                icon: "exclamationmark.triangle.fill",
                                title: "Finish payout setup",
                                message: "Your Stripe account (\(accountId)) isn’t ready for payouts yet."
                            )
                        } else {
                            BannerView(
                                style: .success,
                                icon: "checkmark.seal.fill",
                                title: "Payouts ready",
                                message: "You can transfer your balance to your bank."
                            )
                        }
                    }
                }

                // ACTIONS
                GroupBox("Actions") {
                    VStack(spacing: 10) {
                        Button {
                            Task { await openOnboarding(mode: "onboarding") }
                        } label: {
                            Label("Set up / Manage payout account", systemImage: "person.crop.circle.badge.gearshape")
                        }
                        .buttonStyle(.bordered)

                        HStack {
                            TextField("Amount (optional)", text: $cashOutAmount)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                Task { await cashOut() }
                            } label: {
                                if doingAction { ProgressView() } else { Text("Cash Out") }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(doingAction || availableCents <= 0)
                        }
                        .accessibilityElement(children: .contain)

                        if availableCents <= 0 {
                            Text("You’ll see funds here after you claim a Whisper.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // EXPLAINER
                GroupBox("Why am I seeing a balance but can’t withdraw?") {
                    Text("""
If you’ve claimed funds but haven’t finished Stripe Express onboarding, your money will show in **Available** but cash-out is disabled. Tap **Set up / Manage payout account** and complete the steps. Once **payouts** are enabled, you can withdraw anytime.
""")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }
            .padding()
        }
        .navigationTitle("Wallet")
        .task { await startListening() }
        .refreshable { await refreshStatus() }
    }

    // MARK: - Data

    private func startListening() async {
        guard let uid = uid else { return }
        let db = Firestore.firestore()
        // Live updates to the user doc (allowed by your rules)
        db.collection("users").document(uid).addSnapshotListener { snap, err in
            if let d = snap?.data() {
                self.availableCents = d["availableCents"] as? Int ?? 0
                self.pendingCents = d["pendingWithdrawalCents"] as? Int ?? 0
            }
            self.loading = false
        }
        await refreshStatus()
    }

    private func refreshStatus() async {
        do {
            self.payoutStatus = try await WalletService.shared.fetchPayoutStatus()
        } catch {
            self.payoutStatus = .unknown
        }
    }

    // MARK: - Actions

    private func openOnboarding(mode: String) async {
        guard !doingAction else { return }
        doingAction = true
        defer { doingAction = false }
        do {
            // Use your app’s deep links if available
            let url = try await WalletService.shared.openOnboarding(
                refreshURL: "echotether://stripe-refresh",
                returnURL:  "echotether://stripe-return",
                mode: mode
            )
            await MainActor.run {
                UIApplication.shared.open(url)
            }
        } catch {
            await MainActor.run {
                self.errorText = error.localizedDescription
            }
        }
    }

    private func cashOut() async {
        guard !doingAction else { return }
        doingAction = true
        defer { doingAction = false }

        do {
            // Optional custom amount
            var centsToCash: Int? = nil
            if let v = Double(cashOutAmount.replacingOccurrences(of: "$", with: "")), v > 0 {
                centsToCash = Int((v * 100).rounded())
            }
            try await WalletService.shared.cashOut(cents: centsToCash)
            await refreshStatus()
            await MainActor.run {
                self.cashOutAmount = ""
            }
        } catch {
            await MainActor.run {
                self.errorText = error.localizedDescription
            }
        }
    }
}

// MARK: - Banner

fileprivate struct BannerView: View {
    enum Style { case info, warn, success }
    var style: Style = .warn
    var icon: String
    var title: String
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var background: Color {
        switch style {
        case .info: return Color.blue.opacity(0.12)
        case .warn: return Color.yellow.opacity(0.18)
        case .success: return Color.green.opacity(0.14)
        }
    }
}
