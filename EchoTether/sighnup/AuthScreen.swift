//
//  AuthScreen.swift
//  EchoTether
//
//  Created by Bobby Smith on 10/12/25.
//

import SwiftUI
import FirebaseAuth

struct AuthScreen: View {
    @StateObject private var auth = AuthViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""

    var onSuccess: (() -> Void)?    // called after successful auth

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    SecureField("Password (min 6)", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }

                if let msg = auth.errorMessage, !msg.isEmpty {
                    Section {
                        Text(msg).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            await auth.signIn(email: email, password: password)
                            if auth.user != nil { onSuccess?(); dismiss() }
                        }
                    } label: {
                        HStack {
                            if auth.isLoading { ProgressView() }
                            Text("Log In")
                        }
                    }
                    .disabled(auth.isLoading || email.isEmpty || password.count < 6)

                    Button(role: .none) {
                        Task {
                            await auth.signUp(email: email, password: password)
                            if auth.user != nil { onSuccess?(); dismiss() }
                        }
                    } label: {
                        Text("Sign Up")
                    }
                    .disabled(auth.isLoading || email.isEmpty || password.count < 6)
                }
            }
            .navigationTitle("Sign in to Money Hub")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
