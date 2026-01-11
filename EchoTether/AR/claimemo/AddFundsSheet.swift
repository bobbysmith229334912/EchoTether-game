import SwiftUI
import FirebaseFunctions
import FirebaseAuth

struct AddFundsSheet: View {
    // Prefill from the place you came from
    let initialWhisperId: String?
    let initialName: String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var whisperId: String = ""
    @State private var whisperName: String = ""
    @State private var amountUSD: String = "5"   // default $5
    @State private var isLoading = false
    @State private var errorText: String = ""

    // 🔗 Your live pages
    private let successURL = "https://hardcoreamature.com/registration-complete/"
    private let cancelURL  = "https://hardcoreamature.com/stripe-registration-failed/"

    private let functions = Functions.functions()

    init(initialWhisperId: String? = nil, initialName: String? = nil) {
        self.initialWhisperId = initialWhisperId
        self.initialName = initialName
        _whisperId = State(initialValue: initialWhisperId ?? "")
        _whisperName = State(initialValue: initialName ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Whisper") {
                    TextField("Whisper ID", text: $whisperId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    TextField("Name (optional label)", text: $whisperName)
                        .textInputAutocapitalization(.words)
                }

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
                        }
                    }
                }

                if !errorText.isEmpty {
                    Section {
                        Text(errorText).foregroundStyle(.red)
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
                        launchCheckout()
                    }
                    .disabled(isLoading || !isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        guard !whisperId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let dollars = Int(amountUSD), dollars > 0 else { return false }
        return true
    }

    @MainActor
    private func launchCheckout() {
        errorText = ""
        guard isValid else {
            errorText = "Enter a whisper ID and a valid amount."
            return
        }
        guard Auth.auth().currentUser != nil else {
            errorText = "You must be signed in."
            return
        }

        let dollars = Int(amountUSD) ?? 0
        var cents = dollars * 100
        cents = max(100, min(500_000, cents))  // backend also enforces

        isLoading = true

        Task {
            defer { isLoading = false }
            do {
                // Cloud Function must read and forward these two URLs to Stripe
                let result = try await functions.httpsCallable("createCheckoutSession").call([
                    "whisperId": whisperId.trimmingCharacters(in: .whitespacesAndNewlines),
                    "cents": cents,
                    "successUrl": successURL,
                    "cancelUrl": cancelURL
                ])

                if let dict = result.data as? [String: Any],
                   let ok = dict["success"] as? Bool, ok,
                   let urlStr = dict["url"] as? String,
                   let url = URL(string: urlStr) {
                    openURL(url)
                } else {
                    errorText = "Could not start checkout."
                }
            } catch {
                errorText = "Checkout error: \(error.localizedDescription)"
            }
        }
    }
}
