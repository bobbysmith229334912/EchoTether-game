// MoneyHubKit.swift
// Provides: WhisperItem, MoneyHubVM, AddMoneySheet, MoneyHubView
// Region-pinned (us-central1), verbose debug logging, correct production URLs.

import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import CoreLocation

// MARK: - Tiny logger
@inline(__always) private func dbg(_ items: Any..., fn: String = #function) {
    #if DEBUG
    print("💬 [MoneyHub] \(fn):", items.map { "\($0)" }.joined(separator: " "))
    #endif
}

// MARK: - Data model used in the list
public struct WhisperItem: Identifiable, Hashable {
    public var id: String
    public var name: String?
    public var balanceCents: Int
    public var latitude: Double
    public var longitude: Double
    public var country: String?
    public var region: String?
    public var city: String?
    public var deleted: Bool
    public var claimed: Bool
    public var unlockAt: Date?
}

// MARK: - ViewModel
@MainActor
public final class MoneyHubVM: ObservableObject {
    @Published public var whispers: [WhisperItem] = []
    @Published public var loading = false
    @Published public var errorText: String = ""
    @Published public var checkingConnect = false
    @Published public var chargesEnabled = false
    @Published public var payoutsEnabled = false
    @Published public var accountId: String?
    @Published public var showingAmountFor: WhisperItem?   // drives AddMoneySheet

    // injected by the view for opening Stripe/Connect URLs
    public var openURL: ((URL) -> Void)?

    private let db = Firestore.firestore()
    private let functions: Functions

    /// Explicitly bind to your Cloud Functions region to avoid silent region mismatches.
    public init(region: String = "us-central1") {
        self.functions = Functions.functions(region: region)
        dbg("Functions region =", region)
    }

    // Load current user's whispers
    public func loadWhispers() {
        guard let uid = Auth.auth().currentUser?.uid else {
            self.errorText = "You must be signed in."
            dbg("Not signed in; abort loadWhispers")
            return
        }
        loading = true
        Task {
            defer { loading = false }
            do {
                dbg("Query whispers for uid:", uid)
                let snap = try await db.collection("whispers")
                    .whereField("ownerId", isEqualTo: uid)
                    .order(by: "timestamp", descending: true)
                    .limit(to: 100)
                    .getDocuments()

                var items: [WhisperItem] = []
                for doc in snap.documents {
                    let d = doc.data()
                    let bal = d["balanceCents"] as? Int
                        ?? d["balance"] as? Int
                        ?? 0
                    let lat = d["latitude"] as? Double ?? 0
                    let lon = d["longitude"] as? Double ?? 0
                    let deleted = d["deleted"] as? Bool ?? false
                    let claimed = d["claimed"] as? Bool ?? false
                    let ts = (d["unlockAt"] as? Timestamp)?.dateValue()

                    let item = WhisperItem(
                        id: doc.documentID,
                        name: d["name"] as? String,
                        balanceCents: bal,
                        latitude: lat,
                        longitude: lon,
                        country: d["country"] as? String,
                        region: d["region"] as? String,
                        city: d["city"] as? String,
                        deleted: deleted,
                        claimed: claimed,
                        unlockAt: ts
                    )
                    items.append(item)
                }
                self.whispers = items
                dbg("Loaded whispers:", items.count)
            } catch {
                self.errorText = "Load error: \(error.localizedDescription)"
                dbg("Load error:", error.localizedDescription)
            }
        }
    }

    // Check (and create) Stripe Connect account; fetch status
    public func refreshConnectStatus() {
        checkingConnect = true
        Task {
            defer { checkingConnect = false }
            do {
                guard Auth.auth().currentUser?.uid != nil else {
                    self.errorText = "You must be signed in."
                    dbg("Not signed in; abort refreshConnectStatus")
                    return
                }

                // idempotent create/get
                let getRes = try await functions.httpsCallable("connectCreateOrGetAccount").call([:])
                dbg("connectCreateOrGetAccount response:", String(describing: getRes.data))
                if let dict = getRes.data as? [String: Any] {
                    if let ok = dict["success"] as? Bool, ok {
                        self.accountId = dict["accountId"] as? String
                    } else {
                        let msg = (dict["message"] as? String) ?? "Unknown error creating account."
                        self.errorText = msg
                        dbg("Create/Get account failed:", msg)
                    }
                }

                // status
                let res = try await functions.httpsCallable("connectAccountStatus").call([:])
                dbg("connectAccountStatus response:", String(describing: res.data))
                if let dict = res.data as? [String: Any] {
                    if let ok = dict["success"] as? Bool, ok {
                        self.chargesEnabled = (dict["chargesEnabled"] as? Bool) ?? false
                        self.payoutsEnabled = (dict["payoutsEnabled"] as? Bool) ?? false
                    } else {
                        let msg = (dict["message"] as? String) ?? "Unknown status error."
                        self.errorText = msg
                        dbg("Status failed:", msg)
                    }
                }
            } catch {
                self.errorText = "Connect error: \(error.localizedDescription)"
                dbg("Connect error:", error.localizedDescription)
            }
        }
    }

    /// Ensure Stripe account exists, then open the onboarding link.
    public func ensureAccountThenOnboard(refreshURL: String, returnURL: String) {
        checkingConnect = true
        Task {
            defer { checkingConnect = false }
            do {
                guard Auth.auth().currentUser?.uid != nil else {
                    self.errorText = "You must be signed in."
                    dbg("Not signed in; abort ensureAccountThenOnboard")
                    return
                }

                // 1) Idempotent create/get
                let getRes = try await functions.httpsCallable("connectCreateOrGetAccount").call([:])
                dbg("connectCreateOrGetAccount response:", String(describing: getRes.data))
                if let d = getRes.data as? [String: Any],
                   let ok = d["success"] as? Bool, ok {
                    self.accountId = d["accountId"] as? String
                } else {
                    let msg = (getRes.data as? [String: Any])?["message"] as? String
                        ?? "Could not create/get Stripe account."
                    self.errorText = msg
                    dbg("Create/Get account failed:", msg)
                    return
                }

                // 2) Request onboarding link
                let linkRes = try await functions.httpsCallable("connectOnboardingLink")
                    .call(["refreshUrl": refreshURL, "returnUrl": returnURL])
                dbg("connectOnboardingLink response:", String(describing: linkRes.data))

                if let d = linkRes.data as? [String: Any],
                   let ok = d["success"] as? Bool, ok,
                   let urlStr = d["url"] as? String,
                   let url = URL(string: urlStr) {
                    dbg("Opening onboarding URL:", urlStr)
                    self.openURL?(url)
                } else {
                    let msg = (linkRes.data as? [String: Any])?["message"] as? String
                        ?? "Could not start onboarding."
                    self.errorText = msg
                    dbg("Onboarding link failed:", msg)
                }
            } catch {
                self.errorText = "Onboarding error: \(error.localizedDescription)"
                dbg("Onboarding exception:", error.localizedDescription)
            }
        }
    }

    // Launch Stripe Checkout to fund a whisper
    public func launchCheckout(whisperId: String, cents: Int, successURL: String, cancelURL: String) {
        Task {
            do {
                dbg("createCheckoutSession → whisper:", whisperId, "cents:", cents)
                let res = try await functions.httpsCallable("createCheckoutSession").call([
                    "whisperId": whisperId,
                    "cents": cents,
                    "successUrl": successURL,
                    "cancelUrl": cancelURL
                ])
                dbg("createCheckoutSession response:", String(describing: res.data))

                if let dict = res.data as? [String: Any],
                   let ok = dict["success"] as? Bool, ok,
                   let urlStr = dict["url"] as? String,
                   let url = URL(string: urlStr) {
                    dbg("Opening checkout URL:", urlStr)
                    self.openURL?(url)
                } else {
                    let msg = (res.data as? [String: Any])?["message"] as? String
                        ?? "Could not start checkout."
                    self.errorText = msg
                    dbg("Checkout failed:", msg)
                }
            } catch {
                self.errorText = "Checkout error: \(error.localizedDescription)"
                dbg("Checkout exception:", error.localizedDescription)
            }
        }
    }
}

// MARK: - Amount entry sheet (local to Money Hub)
struct AddMoneySheet: View {
    let whisper: WhisperItem
    var onConfirm: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var amountStr = "5" // dollars default

    var body: some View {
        NavigationStack {
            Form {
                Section("Amount") {
                    HStack {
                        Text("$")
                        TextField("Amount (USD)", text: $amountStr)
                            .keyboardType(.numberPad)
                    }
                    HStack(spacing: 12) {
                        ForEach([5, 10, 20, 50], id: \.self) { v in
                            Button("$\(v)") { amountStr = "\(v)" }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                Section("Whisper") {
                    Text(whisper.name ?? "Unnamed")
                    Text(whisper.id)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Money")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        let dollars = Int(amountStr) ?? 0
                        guard dollars > 0 else { return }
                        onConfirm(dollars * 100) // to cents
                        dismiss()
                    }
                    .disabled((Int(amountStr) ?? 0) <= 0)
                }
            }
        }
    }
}

// MARK: - Main Money Hub View
public struct MoneyHubView: View {
    // If you ever host functions in a different region, pass it here.
    @StateObject private var vm = MoneyHubVM(region: "us-central1")
    @Environment(\.openURL) private var openURL

    // Optional prefill from where you came (not strictly needed here)
    var initialWhisperId: String?
    var initialName: String?

    // NEW: drives CryptoFundingAddressView sheet
    @State private var cryptoFundingWhisper: WhisperItem?

    public init(initialWhisperId: String? = nil, initialName: String? = nil) {
        self.initialWhisperId = initialWhisperId
        self.initialName = initialName
    }

    public var body: some View {
        List {
            // Stripe Connect card
            Section("Payouts") {
                HStack {
                    Image(systemName: vm.payoutsEnabled ? "banknote.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(vm.payoutsEnabled ? .green : .orange)
                    VStack(alignment: .leading) {
                        Text(vm.payoutsEnabled ? "Payouts enabled" : "Payouts not enabled")
                            .font(.headline)
                        if let acct = vm.accountId {
                            Text("Acct: \(acct)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(vm.payoutsEnabled ? "Refresh" : "Set up") {
                        if vm.payoutsEnabled {
                            vm.refreshConnectStatus()
                        } else {
                            vm.ensureAccountThenOnboard(
                                refreshURL: "https://hardcoreamature.com/stripe-registration-failed/",
                                returnURL:  "https://hardcoreamature.com/registration-complete/"
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.checkingConnect)
                }
            }

            // Your whispers
            Section("Your Whispers") {
                if vm.whispers.isEmpty {
                    Text(vm.loading ? "Loading…" : "No whispers yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.whispers) { w in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(w.name ?? "Unnamed")
                                    .font(.headline)
                                if w.deleted {
                                    Text("deleted")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                                if w.claimed {
                                    Text("claimed")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                Text("$\(String(format: "%.2f", Double(w.balanceCents)/100.0))")
                                    .font(.headline)
                            }

                            if let city = w.city,
                               let region = w.region,
                               let country = w.country {
                                Text("\(city), \(region), \(country)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text(w.id)
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                            HStack {
                                Button {
                                    vm.showingAmountFor = w        // Stripe card funding
                                } label: {
                                    Label("Add Money", systemImage: "creditcard")
                                }
                                .buttonStyle(.borderedProminent)

                                // NEW: per-whisper crypto funding entry
                                Button {
                                    cryptoFundingWhisper = w
                                } label: {
                                    Label("Fund with Crypto", systemImage: "bitcoinsign.circle")
                                }
                                .buttonStyle(.bordered)

                                Button {
                                    UIPasteboard.general.string = w.id
                                } label: {
                                    Label("Copy ID", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if !vm.errorText.isEmpty {
                Section {
                    Text(vm.errorText)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Money Hub")
        .onAppear {
            vm.openURL = { url in openURL(url) }
            vm.loadWhispers()
            vm.refreshConnectStatus()
        }
        .sheet(item: $vm.showingAmountFor) { whisper in
            AddMoneySheet(whisper: whisper) { cents in
                vm.launchCheckout(
                    whisperId: whisper.id,
                    cents: cents,
                    successURL: "https://hardcoreamature.com/checkout-success/",
                    cancelURL:  "https://hardcoreamature.com/checkout-cancel/"
                )
            }
        }
        // NEW: Crypto funding sheet using your Cloud Function
        .sheet(item: $cryptoFundingWhisper) { whisper in
            CryptoFundingAddressView(
                whisperId: whisper.id,
                asset: "USDC"
            )
        }
    }
}
