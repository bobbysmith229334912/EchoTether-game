//
//  WalletService.swift
//  EchoTether
//
//  Created by Bobby Smith on 10/21/25.
//

import Foundation
import FirebaseFunctions

enum PayoutStatus: Equatable {
    case unknown
    case notCreated          // no Stripe account yet
    case created(chargesEnabled: Bool, payoutsEnabled: Bool, accountId: String)
}

struct WalletStatus: Equatable {
    var availableCents: Int
    var pendingWithdrawalCents: Int
    var payout: PayoutStatus
}

final class WalletService {

    static let shared = WalletService()
    private init() {}

    private var functions: Functions { Functions.functions() }

    // Get Stripe account status (or not created yet)
    func fetchPayoutStatus() async throws -> PayoutStatus {
        do {
            let result = try await functions.httpsCallable("connectAccountStatus").call([:])
            guard let dict = result.data as? [String: Any] else { return .unknown }
            guard let success = dict["success"] as? Bool, success == true else {
                // No account yet
                return .notCreated
            }
            let accountId = dict["accountId"] as? String ?? ""
            let charges = dict["chargesEnabled"] as? Bool ?? false
            let payouts = dict["payoutsEnabled"] as? Bool ?? false
            return .created(chargesEnabled: charges, payoutsEnabled: payouts, accountId: accountId)
        } catch {
            // If function says "No account yet."
            return .notCreated
        }
    }

    // Creates (if needed) and opens the Stripe Express onboarding/update link.
    // Provide custom deep links for refresh/return if you have them.
    @discardableResult
    func openOnboarding(refreshURL: String, returnURL: String, mode: String = "onboarding") async throws -> URL {
        // ensure account exists
        _ = try await functions.httpsCallable("connectCreateOrGetAccount").call([:])

        // create link
        let payload: [String: Any] = [
            "refreshUrl": refreshURL,
            "returnUrl": returnURL,
            "mode": mode
        ]
        let res = try await functions.httpsCallable("connectOnboardingLink").call(payload)
        guard
            let dict = res.data as? [String: Any],
            let success = dict["success"] as? Bool, success == true,
            let urlStr = dict["url"] as? String,
            let url = URL(string: urlStr)
        else {
            throw NSError(domain: "WalletService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create onboarding link"])
        }
        return url
    }

    // Cash out either the full amount (if cents == nil) or a specific amount in cents.
    func cashOut(cents: Int?) async throws {
        var payload: [String: Any] = [:]
        if let cents = cents { payload["cents"] = cents }
        let res = try await functions.httpsCallable("cashOutAvailable").call(payload)
        guard let dict = res.data as? [String: Any], let success = dict["success"] as? Bool, success == true else {
            let msg = (res.data as? [String: Any])?["message"] as? String ?? "Cash out failed."
            throw NSError(domain: "WalletService", code: -2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}
