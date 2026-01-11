//
//  MoneyHubLauncher.swift
//  EchoTether
//
//  Created by Bobby Smith on 10/12/25.
//

import SwiftUI
import FirebaseAuth

/// Put this in the place where you show the Money Hub entry point (e.g., Home tab).
struct MoneyHubLauncher: View {
    @StateObject private var authVM = AuthViewModel()  // from earlier
    @State private var showAuthSheet = false
    @State private var openMoneyHub = false            // triggers navigation after auth

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Your normal UI...
                Text("EchoTether")
                    .font(.title).bold()

                // The entry button/tile for Money Hub:
                Button {
                    if Auth.auth().currentUser != nil {
                        // Already signed in → go straight in
                        openMoneyHub = true
                    } else {
                        // Not signed in → show login sheet
                        showAuthSheet = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "dollarsign.circle.fill")
                        Text("Open Money Hub")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
                }
                .padding(.horizontal)

                Spacer()
            }
            .navigationDestination(isPresented: $openMoneyHub) {
                MoneyHubView()  // ← your existing screen
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button("Sign Out", role: .destructive) { authVM.signOut() }
                            } label: { Image(systemName: "person.crop.circle.fill.badge.xmark") }
                        }
                    }
            }
            .sheet(isPresented: $showAuthSheet) {
                AuthSheet(authVM: authVM) {
                    // On successful auth, close sheet and navigate
                    showAuthSheet = false
                    openMoneyHub = true
                }
            }
        }
    }
}

/// Wraps the AuthScreen inside a sheet and calls onSuccess when user becomes non-nil.
fileprivate struct AuthSheet: View {
    @ObservedObject var authVM: AuthViewModel
    var onSuccess: () -> Void

    var body: some View {
        AuthScreen() // from earlier response
            .environmentObject(authVM)
            .onChange(of: authVM.user) { _, newUser in
                if newUser != nil { onSuccess() }
            }
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(24)
    }
}
