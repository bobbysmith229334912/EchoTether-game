//
//  EchoPlinkoAgeGateSheet.swift
//  EchoTether
//
//  Created by Bobby Smith on 11/16/25.
//

import SwiftUI

struct EchoPlinkoAgeGateSheet: View {
    let onAccept: () -> Void
    let onCancel: () -> Void

    @State private var isOver18 = false
    @State private var acceptsRisk = false
    @State private var isInAllowedRegion = false

    private var canContinue: Bool {
        isOver18 && acceptsRisk && isInAllowedRegion
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Age & Location") {
                    Toggle("I am at least 18 years old.", isOn: $isOver18)
                    Toggle("I am in a location where real-money games are allowed.", isOn: $isInAllowedRegion)
                }

                Section("Risk & Terms") {
                    Text("Echo Plinko uses **real money** stored in your wallet. You can lose your stake. Play responsibly.")
                        .font(.footnote)
                    Toggle("I understand the risks and agree to the terms of use.", isOn: $acceptsRisk)
                }

                Section {
                    Button {
                        onAccept()
                    } label: {
                        Text("I Agree & Continue to Echo Plinko")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)

                    Button(role: .cancel) {
                        onCancel()
                    } label: {
                        Text("Cancel")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Confirm Eligibility")
        }
    }
}
