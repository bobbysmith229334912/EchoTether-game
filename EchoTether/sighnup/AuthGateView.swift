//
//  AuthGateView.swift
//  EchoTether
//
//  Created by Bobby Smith on 10/11/25.
//

import SwiftUI
import FirebaseAuth

struct AuthGateView<Content: View>: View {
    @StateObject private var authVM = AuthViewModel()
    let content: () -> Content

    var body: some View {
        Group {
            if authVM.user != nil {
                content()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button("Sign Out", role: .destructive) { authVM.signOut() }
                            } label: {
                                Image(systemName: "person.crop.circle.fill.badge.xmark")
                            }
                        }
                    }
            } else {
                AuthScreen()
                    .environmentObject(authVM)
            }
        }
    }
}

// Reusable form field
fileprivate struct LabeledField: View {
    let title: String
    @Binding var text: String
    var isSecure: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            if isSecure {
                SecureField(title, text: $text)
                    .textContentType(.password)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            } else {
                TextField(title, text: $text)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

