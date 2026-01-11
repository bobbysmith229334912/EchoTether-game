import Foundation
import RevenueCat

@MainActor
final class SubscriptionManager: ObservableObject {
    @Published var isPro: Bool = false

    // 🔑 Replace with the exact entitlement identifier from your RC dashboard
    private let entitlementID = "com.hardcoreamature.echotether.prograde"

    init() {
        Task { await checkSubscriptionStatus() }
    }

    // MARK: - Status Check
    func checkSubscriptionStatus() async {
        do {
            let info = try await Purchases.shared.customerInfo()

            // 🔎 Debug: log all entitlements so you can confirm the right key
            print("📋 All entitlements: \(info.entitlements.all.keys)")
            print("✅ Active entitlements: \(info.entitlements.active.keys)")

            self.isPro = info.entitlements[entitlementID]?.isActive == true
            print("🔐 isPro = \(self.isPro)")
        } catch {
            print("❌ Failed to fetch subscription info: \(error.localizedDescription)")
        }
    }

    // MARK: - Purchase
    func purchasePro() {
        Task {
            do {
                let offerings = try await Purchases.shared.offerings()
                let targetProductID = "com.hardcoreamature.echotether.prograde"

                let package = offerings.current?.availablePackages.first(where: {
                    $0.storeProduct.productIdentifier == targetProductID
                }) ?? offerings.current?.availablePackages.first(where: {
                    $0.packageType == .monthly
                })

                guard let package else {
                    print("⚠️ No matching package found. Current offering: \(String(describing: offerings.current?.identifier))")
                    return
                }

                print("ℹ️ Purchasing product id: \(package.storeProduct.productIdentifier) price: \(package.storeProduct.price)")
                let result = try await Purchases.shared.purchase(package: package)
                let info = result.customerInfo

                // 🔎 Debug entitlement keys again after purchase
                print("📋 All entitlements after purchase: \(info.entitlements.all.keys)")
                print("✅ Active entitlements after purchase: \(info.entitlements.active.keys)")

                self.isPro = info.entitlements[entitlementID]?.isActive == true
                print("✅ Purchase completed. isPro = \(self.isPro)")
            } catch {
                print("❌ Purchase failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Manual Update (from delegate/callbacks)
    func updateSubscriptionStatus(from customerInfo: CustomerInfo) {
        self.isPro = customerInfo.entitlements[entitlementID]?.isActive == true
        print("🔄 Subscription status updated. isPro = \(self.isPro)")
    }
}
