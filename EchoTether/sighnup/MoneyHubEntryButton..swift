import SwiftUI
import FirebaseAuth

struct MoneyHubEntryButton: View {
    @State private var showAuth = false
    @State private var goHub = false

    var initialWhisperId: String?
    var initialName: String?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if Auth.auth().currentUser != nil {
                    goHub = true
                } else {
                    showAuth = true
                }
            } label: {
                Label("Money Hub", systemImage: "creditcard.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .sheet(isPresented: $showAuth) {
                AuthScreen {
                    goHub = true    // on successful login, push Money Hub
                }
            }
        }
        .accessibilityLabel("Open Money Hub")
        // ✅ iOS 16+ way to programmatically push a destination inside a NavigationStack
        .navigationDestination(isPresented: $goHub) {
            MoneyHubView(
                initialWhisperId: initialWhisperId,
                initialName: initialName
            )
        }
    }
}
