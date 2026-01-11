//
//  SetUsernameView.swift
//  EchoTether
//
//  Created by Bobby Smith on 10/18/25.
//

import SwiftUI

struct SetUsernameView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var currentHandle: String?

    @State private var desired = ""
    @State private var helperText: String?
    @State private var isChecking = false
    @State private var isSaving = false
    @State private var available: Bool?

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Choose a username")) {
                    TextField("e.g. Bobby_Smith", text: $desired)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .onChange(of: desired) { _, _ in
                            helperText = nil
                            available = nil
                        }

                    if let helper = helperText {
                        Text(helper).font(.footnote).foregroundColor(.secondary)
                    }

                    if let ok = available {
                        Label(ok ? "Available" : "Not available",
                              systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundColor(ok ? .green : .red)
                        .font(.subheadline)
                    }

                    HStack {
                        Button("Check availability") { Task { await doCheck() } }
                            .disabled(desired.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChecking || isSaving)

                        Spacer()

                        Button("Save") { Task { await doSave() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!(available ?? false) || isSaving)
                    }
                }
            }
            .navigationTitle("Username")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                if let h = currentHandle, desired.isEmpty {
                    desired = h.hasPrefix("@") ? String(h.dropFirst()) : h
                }
            }
            // Detents/corner radius only on iOS 16+
            .applySheetStyling()
        }
    }

    private func doCheck() async {
        let candidate = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            let ok = try await UsernameService.shared.checkAvailability(candidate)
            available = ok
            helperText = ok ? "Looks good!" : "That one’s taken or invalid."
        } catch {
            available = nil
            helperText = error.localizedDescription
        }
    }

    private func doSave() async {
        let candidate = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let final = try await UsernameService.shared.setUsername(candidate)
            currentHandle = "@\(final)"
            dismiss()
        } catch {
            helperText = error.localizedDescription
        }
    }
}

// MARK: - Sheet styling helper (guards iOS version)
private struct SheetStyling: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .presentationDetents([.medium])
                .presentationCornerRadius(24)
        } else {
            content
        }
    }
}

private extension View {
    func applySheetStyling() -> some View { modifier(SheetStyling()) }
}
