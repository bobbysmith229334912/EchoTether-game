import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions

// MARK: - Models

struct WalletUser: Identifiable {
    let id: String
    let availableCents: Int
    let totalEarnedCents: Int
    let totalWhispersClaimed: Int
    let pendingWithdrawalCents: Int
    let hasStripeAccount: Bool

    var availableDollars: String {
        String(format: "$%.2f", Double(availableCents) / 100.0)
    }

    var totalEarnedDollars: String {
        String(format: "$%.2f", Double(totalEarnedCents) / 100.0)
    }

    var pendingDollars: String {
        String(format: "$%.2f", Double(pendingWithdrawalCents) / 100.0)
    }
}

// MARK: - ViewModel

@MainActor
final class MyMoneyViewModel: ObservableObject {
    @Published var user: WalletUser?
    @Published var isLoading: Bool = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private var listener: ListenerRegistration?
    private let db = Firestore.firestore()
    private let functions = Functions.functions()

    func start() {
        guard let uid = Auth.auth().currentUser?.uid else {
            errorMessage = "Sign in to view your wallet."
            return
        }

        listener?.remove()
        listener = db.collection("users").document(uid)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self = self else { return }
                if let error = error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                guard let snap = snapshot, let data = snap.data() else { return }

                let available = data["availableCents"] as? Int ?? 0
                let totalEarned = data["totalEarnedCents"] as? Int ?? 0
                let totalClaims = data["totalWhispersClaimed"] as? Int ?? 0
                let pending = data["pendingWithdrawalCents"] as? Int ?? 0
                let stripeId = data["stripeAccountId"] as? String

                self.user = WalletUser(
                    id: snap.documentID,
                    availableCents: available,
                    totalEarnedCents: totalEarned,
                    totalWhispersClaimed: totalClaims,
                    pendingWithdrawalCents: pending,
                    hasStripeAccount: (stripeId?.isEmpty == false)
                )
            }
    }

    func stop() {
        listener?.remove()
        listener = nil
    }

    func connectStripe(refreshURL: String, returnURL: String) {
        isLoading = true
        errorMessage = nil
        statusMessage = nil

        let data: [String: Any] = [
            "refreshUrl": refreshURL,
            "returnUrl": returnURL,
            "mode": "onboarding"
        ]

        functions.httpsCallable("connectOnboardingLink").call(data) { [weak self] result, error in
            Task { @MainActor in
                self?.isLoading = false

                if let error = error {
                    self?.errorMessage = error.localizedDescription
                    return
                }

                guard
                    let dict = result?.data as? [String: Any],
                    let success = dict["success"] as? Bool,
                    success,
                    let urlString = dict["url"] as? String,
                    let url = URL(string: urlString)
                else {
                    self?.errorMessage = "Unable to start Stripe onboarding."
                    return
                }

                UIApplication.shared.open(url)
            }
        }
    }

    func cashOutAll() {
        guard (user?.availableCents ?? 0) > 0 else {
            statusMessage = "No funds available to cash out."
            return
        }

        isLoading = true
        errorMessage = nil
        statusMessage = nil

        functions.httpsCallable("cashOutAvailable").call([:]) { [weak self] result, error in
            Task { @MainActor in
                self?.isLoading = false

                if let error = error {
                    self?.errorMessage = error.localizedDescription
                    return
                }

                guard
                    let dict = result?.data as? [String: Any],
                    let success = dict["success"] as? Bool,
                    success
                else {
                    let msg = (result?.data as? [String: Any])?["message"] as? String
                    self?.errorMessage = msg ?? "Cash out failed."
                    return
                }

                self?.statusMessage = "Cash out requested. Stripe will process your payout."
            }
        }
    }
}

// MARK: - View

struct MyMoneyView: View {
    @StateObject private var vm = MyMoneyViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                if let user = vm.user {
                    // Wallet summary card
                    VStack(spacing: 8) {
                        Text("Available Balance")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(user.availableDollars)
                            .font(.system(size: 34, weight: .bold, design: .rounded))

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Lifetime Earned")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(user.totalEarnedDollars)
                                    .font(.headline)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Whispers Claimed")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text("\(user.totalWhispersClaimed)")
                                    .font(.headline)
                            }
                        }

                        if user.pendingWithdrawalCents > 0 {
                            Text("Pending payout: \(user.pendingDollars)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)

                    // Stripe connect / cash out buttons
                    if !user.hasStripeAccount {
                        Button(action: {
                            vm.connectStripe(
                                refreshURL: "https://hardcoreamature.com/stripe/refresh",
                                returnURL: "https://hardcoreamature.com/stripe/return"
                            )
                        }) {
                            Text("Set Up Stripe to Get Paid")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                    } else {
                        Button(action: {
                            vm.cashOutAll()
                        }) {
                            Text("Cash Out to Stripe")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(
                                    (user.availableCents > 0)
                                    ? Color.accentColor
                                    : Color.gray
                                )
                                .foregroundColor(.white)
                                .cornerRadius(12)
                        }
                        .disabled(user.availableCents <= 0)
                    }

                    // Leaderboard link
                    NavigationLink(destination: LeaderboardView()) {
                        Text("View Top Earners")
                            .font(.subheadline.weight(.semibold))
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                            )
                    }
                    .padding(.top, 4)

                } else {
                    Text("Sign in or wait for your wallet data…")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                if vm.isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                }

                if let status = vm.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundColor(.green)
                        .multilineTextAlignment(.center)
                }

                if let error = vm.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("My Money")
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }
}
