import SwiftUI
import RevenueCat

struct PaywallView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager

    var body: some View {
        VStack(spacing: 24) {
            Text("🔓 Unlock Echo Premium")
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)

            Text("• Unlimited Whisper Uploads\n• Early Access to Drops\n• Exclusive Audio Tools")
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)

            // ✅ Apple-required trial & billing info
            Text("Start your 3-day free trial, then $1.99/month.\nRenews automatically unless canceled at least 24 hours before the end of the period. Cancel anytime in Settings.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(action: {
                subscriptionManager.purchasePro()
            }) {
                Text("Start Free Trial")
                    .font(.title2)
                    .bold()
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }

            Button("Restore Purchases") {
                restorePurchases()
            }
            .foregroundColor(.blue)
            .padding(.top)

            Spacer()
        }
        .padding()
    }

    func restorePurchases() {
        Task {
            do {
                let info = try await Purchases.shared.restorePurchases()
                subscriptionManager.isPro = info.entitlements["com.hardcoreamature.echotether.prograde"]?.isActive == true
                print("✅ Purchases restored")
            } catch {
                print("❌ Restore failed: \(error.localizedDescription)")
            }
        }
    }
}
