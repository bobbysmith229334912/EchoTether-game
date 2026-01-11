import SwiftUI
import FirebaseFunctions
import FirebaseAuth

struct WalletAddFundsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var amountUSD: String = "5"   // default $5
    @State private var isLoading = false
    @State private var errorText: String = ""

    // Cloud Functions instance
    private let functions = Functions.functions()

    // If your CF supports success/cancel URLs and you want to use them here too:
    private let successURL = "https://hardcoreamature.com/registration-complete/"
    private let cancelURL  = "https://hardcoreamature.com/stripe-registration-failed/"

    var body: some View {
        NavigationStack {
            Form {
                Section("Amount") {
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
                }

                if !errorText.isEmpty {
                    Section {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                }
            }
            .disabled(isLoading)
            .navigationTitle("Add Money")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isLoading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isLoading ? "Opening…" : "Continue") {
                        startCheckout()     // 👈 no direct async, we wrap in a Task
                    }
                    .disabled(isLoading || !isValid)
                }
            }
        }
    }

    // MARK: - Validation

    private var isValid: Bool {
        guard let dollars = Int(amountUSD),
              dollars > 0 else {
            return false
        }
        return true
    }

    // MARK: - Checkout

    /// Sync entry point — wraps the async work in a Task, with a HARD isLoading guard
    private func startCheckout() {
        // HARD GUARD: if already running, bail immediately
        if isLoading { return }

        Task { @MainActor in
            errorText = ""

            guard isValid else {
                errorText = "Enter a valid amount."
                return
            }

            guard Auth.auth().currentUser != nil else {
                errorText = "You must be signed in."
                return
            }

            // Clamp amount between $1 and $5,000 just to be safe
            let rawDollars = Int(amountUSD) ?? 0
            let clampedDollars = min(max(rawDollars, 1), 5_000)
            amountUSD = "\(clampedDollars)"

            isLoading = true

            do {
                // 🔥 CALLS: exports.wallet_createTopUpCheckoutSession
                let callable = functions.httpsCallable("wallet_createTopUpCheckoutSession")
                let result = try await callable.call([
                    "amountUSD": clampedDollars,
                    "successUrl": successURL,
                    "cancelUrl": cancelURL
                ])

                guard
                    let dict = result.data as? [String: Any],
                    // 👇 IMPORTANT: match what your CF actually returns
                    let urlStr = dict["url"] as? String,
                    let url = URL(string: urlStr)
                else {
                    errorText = "Could not start checkout."
                    isLoading = false
                    return
                }

                openURL(url)
                isLoading = false
                // You can dismiss here if you want:
                // dismiss()

            } catch {
                errorText = "Checkout error: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
}
