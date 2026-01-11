import Foundation
import RevenueCat

final class EchoTetherAccess: ObservableObject {
    static let shared = EchoTetherAccess()
    private init() { refreshProStatus() }

    @Published private(set) var isPro: Bool = false
    private let usedKey = "et_reports_submitted_count"
    private let limit = 100

    var usedCount: Int {
        UserDefaults.standard.integer(forKey: usedKey)
    }

    var remainingFree: Int {
        max(0, limit - usedCount)
    }

    func incrementUse() {
        let next = usedCount + 1
        UserDefaults.standard.set(next, forKey: usedKey)
        objectWillChange.send()
    }

    func resetForTesting() {  // remove before release if you want
        UserDefaults.standard.removeObject(forKey: usedKey)
        objectWillChange.send()
    }

    func refreshProStatus() {
        Purchases.shared.getCustomerInfo { [weak self] info, _ in
            guard let self = self else { return }
            // If you use entitlements, replace "pro" with your entitlement identifier
            let active = info?.entitlements.active["pro"] != nil
            DispatchQueue.main.async { self.isPro = active }
        }
    }
}
