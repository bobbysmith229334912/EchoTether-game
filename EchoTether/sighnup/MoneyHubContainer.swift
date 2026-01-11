//
//  MoneyHubContainer.swift
//  EchoTether
//
//  Created by Bobby Smith on 10/12/25.
//

import SwiftUI

/// Wraps MoneyHubView and adds a Sign Out button when inside.
struct MoneyHubContainer: View {
    @StateObject private var auth = AuthViewModel()

    let initialWhisperId: String?
    let initialName: String

    var body: some View {
        NavigationStack {
            MoneyHubView(
                initialWhisperId: initialWhisperId,
                initialName: initialName
            )
            .navigationTitle("Money Hub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign Out", role: .destructive) { auth.signOut() }
                }
            }
        }
    }
}


