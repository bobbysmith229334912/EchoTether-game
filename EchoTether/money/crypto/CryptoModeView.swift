//
//  CryptoModeView.swift
//  EchoTether
//
//  Created by Bobby Smith on 11/09/2025.
//

import SwiftUI
import FirebaseAuth
import FirebaseFunctions
import FirebaseFirestore
import UIKit

// MARK: - Crypto Mode Screen (wired to get/setCryptoPreferences)

final class CryptoModeViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var errorMessage: String?

    // From getDigitalWalletConfig
    @Published var backendEnabled = false
    @Published var krakenEnv: String = ""
    @Published var supportedAssets: [String] = []

    // User prefs (from getCryptoPreferences / setCryptoPreferences)
    @Published var enableCryptoMode = false
    @Published var notifyNearCrypto = false
    @Published var krakenReferralLinked = false   // local flag we also persist

    private let functions = Functions.functions(region: "us-central1")

    func onAppear() {
        Task {
            await loadConfig()
            await loadUserPrefs()
        }
    }

    // MARK: - Load global config

    func loadConfig() async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }

        do {
            let result = try await functions.httpsCallable("getDigitalWalletConfig").call([:])
            if let data = result.data as? [String: Any] {
                await MainActor.run {
                    backendEnabled = data["digitalWalletModeEnabled"] as? Bool ?? false
                    krakenEnv = (data["krakenEnvironment"] as? String) ?? ""
                    if let assets = data["supportedAssets"] as? [String], !assets.isEmpty {
                        supportedAssets = assets
                    }
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to load Digital Wallet config."
            }
        }

        await MainActor.run {
            isLoading = false
        }
    }

    // MARK: - Load user prefs (Cloud Function)

    func loadUserPrefs() async {
        guard Auth.auth().currentUser != nil else { return }

        do {
            let result = try await functions.httpsCallable("getCryptoPreferences").call([:])
            if let data = result.data as? [String: Any] {
                await MainActor.run {
                    enableCryptoMode = data["enableCryptoMode"] as? Bool ?? false
                    notifyNearCrypto = data["notifyNearCryptoDrops"] as? Bool ?? false
                    krakenReferralLinked = data["krakenReferralLinked"] as? Bool ?? false
                }
            }
        } catch {
            // fall back silently; user can toggle to create prefs
        }
    }

    // MARK: - Save prefs (Cloud Function)

    func savePrefs() {
        guard Auth.auth().currentUser != nil else {
            errorMessage = "Sign in required."
            return
        }

        isSaving = true
        errorMessage = nil

        let payload: [String: Any] = [
            "enableCryptoMode": enableCryptoMode,
            "notifyNearCryptoDrops": notifyNearCrypto,
            "krakenReferralLinked": krakenReferralLinked
        ]

        functions.httpsCallable("setCryptoPreferences").call(payload) { [weak self] _, error in
            guard let self = self else { return }
            self.isSaving = false
            if let error = error {
                self.errorMessage = "Save failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Kraken referral flag

    func markKrakenLinked() {
        krakenReferralLinked = true
        savePrefs()
    }
}

// MARK: - View

struct CryptoModeView: View {
    @StateObject private var vm = CryptoModeViewModel()

    var body: some View {
        Form {
            // DIGITAL WALLET MODE
            Section(header: Text("DIGITAL WALLET MODE")) {
                HStack {
                    Text("Backend Status")
                    Spacer()
                    Text(vm.backendEnabled ? "Enabled" : "Disabled")
                        .foregroundColor(vm.backendEnabled ? .green : .red)
                }

                HStack {
                    Text("Kraken Environment")
                    Spacer()
                    Text(vm.krakenEnv.isEmpty ? "—" : vm.krakenEnv)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Supported Assets")
                    Spacer()
                    Text(vm.supportedAssets.isEmpty
                         ? "—"
                         : vm.supportedAssets.joined(separator: ", "))
                        .foregroundColor(.secondary)
                }

                Toggle("Enable Crypto Mode", isOn: Binding(
                    get: { vm.enableCryptoMode },
                    set: { newValue in
                        vm.enableCryptoMode = newValue
                        vm.savePrefs()
                    })
                )
                .disabled(!vm.backendEnabled)
            }

            // DISCOVERY & ALERTS
            Section(
                header: Text("DISCOVERY & ALERTS"),
                footer: Text("When enabled, your device can be notified if you’re near crypto-backed EchoTether drops (subject to location/notification permissions and future geo logic).")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            ) {
                Toggle("Notify when near hidden crypto", isOn: Binding(
                    get: { vm.notifyNearCrypto },
                    set: { newValue in
                        vm.notifyNearCrypto = newValue
                        vm.savePrefs()
                    })
                )
                .disabled(!vm.enableCryptoMode || !vm.backendEnabled)
                .opacity((vm.enableCryptoMode && vm.backendEnabled) ? 1.0 : 0.4)
            }

            // KRAKEN LINK-UP
            Section(header: Text("KRAKEN LINK-UP")) {
                Button {
                    if let url = URL(string: "https://www.kraken.com/sign-up?ref=ttkbj3kg") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Text("Open Kraken via EchoTether link")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                    }
                }

                Button {
                    vm.markKrakenLinked()
                } label: {
                    HStack {
                        Image(systemName: vm.krakenReferralLinked ? "checkmark.seal.fill" : "link")
                            .foregroundColor(vm.krakenReferralLinked ? .green : .accentColor)
                        Text(vm.krakenReferralLinked
                             ? "Kraken referral linked"
                             : "I used the official Kraken link")
                    }
                }
            }

            // STATUS
            if vm.isLoading || vm.isSaving {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(vm.isLoading ? "Loading…" : "Saving…")
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let error = vm.errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Crypto Mode")
        .onAppear {
            vm.onAppear()
        }
    }
}
