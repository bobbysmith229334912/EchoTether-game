//
//  CryptoFundingAddressView.swift
//  EchoTether
//
//  Created by Bobby Smith on 11/9/25.
//

// CryptoFundingAddressView.swift
// Shows a Kraken USDC deposit address for a specific Whisper
// Uses: createCryptoWhisperFundingIntent (us-central1)

import SwiftUI
import FirebaseAuth
import FirebaseFunctions

struct CryptoFundingAddressView: View {
    let whisperId: String
    let asset: String   // e.g. "USDC"

    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var address: String?
    @State private var note: String?

    @Environment(\.dismiss) private var dismiss

    // Region-pinned to match your deployed functions
    private var functions: Functions {
        Functions.functions(region: "us-central1")
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Generating deposit address…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(errorMessage)
                            .multilineTextAlignment(.center)
                            .font(.subheadline)
                        Button {
                            Task { await loadAddress() }
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                } else if let address {
                    VStack(alignment: .leading, spacing: 18) {

                        Text("Fund this Whisper directly with \(asset).")
                            .font(.headline)

                        Text("Send **only \(asset)** to this address. Once the deposit confirms on Kraken, our backend will credit this Whisper’s balance.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        GroupBox("Deposit Address") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(address)
                                    .font(.footnote.monospaced())
                                    .textSelection(.enabled)

                                Button {
                                    UIPasteboard.general.string = address
                                } label: {
                                    Label("Copy Address", systemImage: "doc.on.doc")
                                        .font(.subheadline)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                        }

                        if let note {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text("Reminder: Deposits go to the EchoTether master Kraken wallet and are mirrored into this Whisper once confirmed. Do not send from exchanges that don’t support withdrawals to this network/method.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    VStack(spacing: 12) {
                        Text("No address available.")
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await loadAddress() }
                        } label: {
                            Label("Try Again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                }
            }
            .navigationTitle("Fund with \(asset)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            await loadAddress()
        }
    }

    // MARK: - Load from Cloud Function

    private func loadAddress() async {
        guard Auth.auth().currentUser != nil else {
            await MainActor.run {
                isLoading = false
                errorMessage = "You must be signed in to create a crypto funding address."
            }
            return
        }

        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }

        do {
            let result = try await functions
                .httpsCallable("createCryptoWhisperFundingIntent")
                .call([
                    "whisperId": whisperId,
                    "asset": asset
                ])

            guard let dict = result.data as? [String: Any] else {
                await MainActor.run {
                    errorMessage = "Invalid response from server."
                    isLoading = false
                }
                return
            }

            let success = dict["success"] as? Bool ?? false
            if success,
               let addr = dict["address"] as? String {
                let noteText = dict["note"] as? String

                await MainActor.run {
                    self.address = addr
                    self.note = noteText
                    self.isLoading = false
                }
            } else {
                let msg = (dict["message"] as? String) ?? "Unable to create deposit address."
                await MainActor.run {
                    errorMessage = msg
                    isLoading = false
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Error: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }
}
