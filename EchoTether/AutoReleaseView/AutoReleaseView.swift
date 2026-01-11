//
//  AutoReleaseView.swift
//  EchoTether
//
//  Created by Bobby Smith on 10/15/25.
//

import SwiftUI
import CoreLocation

struct AutoReleaseView: View {
    // Optional: supply when viewing an existing drop so the Claim button appears
    let dropId: String?

    @StateObject private var vm = AutoReleaseVM()
    @StateObject private var loc = LocationManager()   // GPS manager for Claim

    // local inputs
    @State private var amountString: String = ""
    @FocusState private var amountFocused: Bool

    // sheets
    @State private var showPersonPicker = false
    @State private var showMapPicker = false

    // claim alert state
    @State private var claimMessage = ""
    @State private var showClaimAlert = false
    @State private var claiming = false

    var body: some View {
        NavigationStack {
            Form {
                // MARK: Recipient
                Section("Recipient") {
                    Picker("", selection: Binding(
                        get: { vm.mode },
                        set: { vm.mode = $0; vm.selectedUser = nil; vm.selectedGroup = nil }
                    )) {
                        Text("Person").tag(AutoReleaseVM.Mode.person)
                        Text("Group").tag(AutoReleaseVM.Mode.group)
                        Text("Trusted Any").tag(AutoReleaseVM.Mode.trustedAny)
                    }
                    .pickerStyle(.segmented)

                    if vm.mode == .person {
                        Button {
                            showPersonPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.circle")
                                Text(vm.selectedUser?.handle ?? "Select person")
                                    .foregroundStyle(vm.selectedUser == nil ? .secondary : .primary)
                                Spacer()
                            }
                        }
                        .accessibilityIdentifier("selectPersonButton")
                    }

                    if vm.mode == .group {
                        HStack {
                            Image(systemName: "person.3")
                            Text(vm.selectedGroup?.name ?? "Select group")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        Picker("Claim policy", selection: $vm.policy) {
                            Text("First eligible only").tag(ClaimPolicy.first)
                            Text("One per person").tag(ClaimPolicy.each)
                        }
                        if vm.policy == .each {
                            Stepper("Per-person cap: \(vm.perUserCap)", value: $vm.perUserCap, in: 1...10)
                        }
                    }

                    if vm.mode == .trustedAny {
                        Picker("Claim policy", selection: $vm.policy) {
                            Text("First eligible only").tag(ClaimPolicy.first)
                            Text("One per person").tag(ClaimPolicy.each)
                        }
                        if vm.policy == .each {
                            Stepper("Per-person cap: \(vm.perUserCap)", value: $vm.perUserCap, in: 1...10)
                        }
                        Text("Auto-releases to anyone in your Trusted list who qualifies.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: Trigger
                Section("Trigger") {
                    Button {
                        showMapPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "mappin.and.ellipse")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vm.place?.name ?? "Choose place")
                                Text("Radius: \(Int(vm.radiusM)) m")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .accessibilityIdentifier("choosePlaceButton")

                    Slider(value: $vm.radiusM, in: 20...200, step: 5) {
                        Text("Radius (m)")
                    } minimumValueLabel: { Text("20") } maximumValueLabel: { Text("200") }

                    Toggle("Unlock after specific time", isOn: Binding(
                        get: { vm.notBefore != nil },
                        set: { vm.notBefore = $0 ? Date().addingTimeInterval(3600) : nil }
                    ))
                    if let _ = vm.notBefore {
                        DatePicker("Not before", selection: Binding(
                            get: { vm.notBefore ?? Date() },
                            set: { vm.notBefore = $0 }),
                                   displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }

                // MARK: Payment
                Section("Amount & Message") {
                    TextField("$0.00", text: $amountString)
                        .keyboardType(.decimalPad)
                        .focused($amountFocused)
                        .onChange(of: amountString) { oldValue, newValue in
                            let cleaned = newValue.replacingOccurrences(of: "$", with: "")
                            let v = Double(cleaned) ?? 0
                            vm.amountCents = Int((v * 100).rounded())
                        }

                    TextField("Add a note", text: $vm.message)
                }

                // MARK: Summary
                Section("Summary") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Releases to: \(summaryRecipient)")
                        Text("When: arrive at \(vm.place?.name ?? "—"), radius \(Int(vm.radiusM))m")
                        if let nb = vm.notBefore {
                            Text("Not before: \(nb.formatted(date: .abbreviated, time: .shortened))")
                        }
                        if vm.mode != .person {
                            Text("Policy: \(vm.policy == .first ? "First eligible" : "One per person (cap \(vm.perUserCap))")")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                // MARK: Create (disabled until valid)
                Section {
                    Button {
                        // TODO: wire create-drop call to Firestore/Functions
                    } label: {
                        Text("Create Auto Release")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.isValid)
                }

                // MARK: Claim (only when viewing an existing drop)
                if let dropId {
                    Section("Claim Funds") {
                        Button {
                            claim(dropId: dropId)
                        } label: {
                            if claiming { ProgressView().frame(maxWidth: .infinity) }
                            else { Text("Claim Auto Release").frame(maxWidth: .infinity) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(claiming)
                        .alert("Claim", isPresented: $showClaimAlert) {
                            Button("OK", role: .cancel) {}
                        } message: {
                            Text(claimMessage)
                        }
                    }
                }
            }
            .navigationTitle("Auto Release")
            .toolbar {
                ToolbarItem(placement: .keyboard) {
                    Button("Done") { amountFocused = false }
                }
            }
            // Sheets
            .sheet(isPresented: $showPersonPicker) {
                PersonPickerView { user in
                    vm.selectedUser = user
                }
            }
            .sheet(isPresented: $showMapPicker) {
                MapPickerView(radiusM: vm.radiusM) { place in
                    vm.place = place
                }
            }
        }
        .onAppear { loc.start() }
        .onDisappear { loc.stop() }
    }

    private var summaryRecipient: String {
        switch vm.mode {
        case .person:     return vm.selectedUser?.handle ?? "—"
        case .group:      return vm.selectedGroup?.name ?? "Group —"
        case .trustedAny: return "Any trusted person"
        }
    }

    private func claim(dropId: String) {
        claiming = true
        loc.getFreshCoordinate(minAccuracyMeters: 50, timeout: 8, maxAge: 10) { result in
            switch result {
            case .success(let coord):
                Task {
                    do {
                        let (_, msg) = try await AutoReleaseService.claim(dropId: dropId, at: coord)

                        claimMessage = msg
                    } catch {
                        claimMessage = error.localizedDescription
                    }
                    claiming = false
                    showClaimAlert = true
                }
            case .failure(let err):
                claimMessage = err.localizedDescription
                claiming = false
                showClaimAlert = true
            }
        }
    }
}

#Preview {
    // Preview without claim button
    AutoReleaseView(dropId: nil)
}
