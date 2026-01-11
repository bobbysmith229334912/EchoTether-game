//
//  ClaimService.swift
//  EchoTether
//
//  Ensures users can't "claim & zero out" unless payouts are ready,
//  or they explicitly choose "Claim to Wallet".
//  - Preflights Stripe Connect status
//  - Supports two paths: .directPayout (require payouts) or .walletOnly (allow without payouts)
//

import Foundation
import FirebaseFunctions
import CoreLocation
import CryptoKit
import UIKit

enum ClaimError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

enum ClaimPath {
    case directPayout        // require payouts_enabled == true (safer default)
    case walletOnly          // allow adding to in-app wallet even if payouts not ready
}

enum ClaimService {
    private static let functions = Functions.functions(region: "us-central1")

    private static func sha256Hex(_ s: String) -> String {
        let h = SHA256.hash(data: Data(s.utf8))
        return h.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Stripe Connect helpers

    /// Creates (or reuses) a Connect account. Returns its id if successful.
    @discardableResult
    static func ensureConnectAccount() async throws -> String {
        let res = try await functions.httpsCallable("connectCreateOrGetAccount").call([:])
        guard
            let dict = res.data as? [String: Any],
            (dict["success"] as? Bool) == true,
            let accountId = dict["accountId"] as? String
        else {
            throw ClaimError.message("Could not create Stripe account.")
        }
        return accountId
    }

    struct ConnectStatus {
        let success: Bool
        let accountId: String?
        let chargesEnabled: Bool
        let payoutsEnabled: Bool
        let requirements: [String: Any]?

        static func from(_ any: Any?) -> ConnectStatus {
            let d = any as? [String: Any] ?? [:]
            return .init(
                success: (d["success"] as? Bool) == true,
                accountId: d["accountId"] as? String,
                chargesEnabled: (d["chargesEnabled"] as? Bool) ?? false,
                payoutsEnabled: (d["payoutsEnabled"] as? Bool) ?? false,
                requirements: d["requirements"] as? [String: Any]
            )
        }
    }

    static func getConnectStatus() async throws -> ConnectStatus {
        let res = try await functions.httpsCallable("connectAccountStatus").call([:])
        return ConnectStatus.from(res.data)
    }

    /// Get an onboarding/update link (open in SFSafariViewController or UIApplication).
    static func getOnboardingLink(returnURL: String, refreshURL: String, mode: String = "onboarding") async throws -> URL {
        let res = try await functions.httpsCallable("connectOnboardingLink").call([
            "returnUrl": returnURL,
            "refreshUrl": refreshURL,
            "mode": mode
        ])
        guard
            let dict = res.data as? [String: Any],
            (dict["success"] as? Bool) == true,
            let urlStr = dict["url"] as? String,
            let url = URL(string: urlStr)
        else {
            throw ClaimError.message("Could not start Stripe onboarding.")
        }
        return url
    }

    // MARK: - Claim

    /// Unified claim entry point. If `.directPayout`, the backend will refuse to claim unless payouts are enabled.
    /// If `.walletOnly`, it will claim to in-app wallet even if payouts aren’t enabled.
    static func claim(
        whisperId: String,
        location: CLLocation,
        passwordPlain: String? = nil,
        path: ClaimPath = .directPayout
    ) async throws -> (receivedCents: Int, message: String) {

        // Always create/connect a Stripe account first (idempotent)
        _ = try? await ensureConnectAccount()

        // Preflight if we require payouts
        if path == .directPayout {
            let status = try await getConnectStatus()
            guard status.success, status.payoutsEnabled else {
                // Surface an actionable error
                throw ClaimError.message(
                    "You need to finish Stripe setup before claiming funds. Tap “Finish Setup” to enable payouts."
                )
            }
        }

        let deviceId = await UIDevice.current.identifierForVendor?.uuidString ?? "unknown"

        let payload: [String: Any] = [
            "whisperId": whisperId,
            "lat": location.coordinate.latitude,
            "lon": location.coordinate.longitude,
            "horizontalAccuracy": location.horizontalAccuracy,
            "locationTimestampMs": Int(location.timestamp.timeIntervalSince1970 * 1000),
            "deviceId": "device-\(deviceId)",
            "passwordHashHex": (passwordPlain?.isEmpty == false) ? sha256Hex(passwordPlain!) : "",
            // NEW: tell backend whether to allow claim without payouts enabled
            "requirePayoutReady": (path == .directPayout)
        ]

        let res = try await functions.httpsCallable("claimWhisperV2").call(payload)
        guard let dict = res.data as? [String: Any],
              let ok = dict["success"] as? Bool
        else {
            throw ClaimError.message("Malformed server response.")
        }

        let msg = (dict["message"] as? String) ?? (ok ? "Claimed." : "Claim failed.")
        let cents = (dict["receivedCents"] as? Int) ?? 0

        if ok {
            await UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            return (cents, msg)
        } else {
            await UINotificationFeedbackGenerator().notificationOccurred(.error)
            throw ClaimError.message(msg)
        }
    }
}
