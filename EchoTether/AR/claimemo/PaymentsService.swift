import Foundation
import FirebaseFunctions
import FirebaseFirestore

struct AddFundsResult {
    let success: Bool
    let message: String
    /// Optional: new balance in dollars after we re-read the doc
    let newBalance: Double?
}

final class PaymentsService {
    private let functions = Functions.functions(region: "us-central1")
    private let db = Firestore.firestore()

    /// amount is in DOLLARS, e.g. 10.00
    func addFunds(whisperId: String, amount dollars: Decimal, note: String? = nil) async throws -> AddFundsResult {
        // 1) Convert to integer cents safely
        // Example: 10.00 → 1000
        let cents = try Self.decimalToCents(dollars)
        guard cents > 0 else {
            return AddFundsResult(success: false, message: "Amount must be greater than $0.00", newBalance: nil)
        }

        // 2) Your callable requires an idempotency key
        let idempotencyKey = UUID().uuidString

        // 3) Call the Cloud Function
        let payload: [String: Any] = [
            "whisperId": whisperId,
            "cents": cents,
            "idempotencyKey": idempotencyKey
        ]

        let callResult = try await functions.httpsCallable("addFundsToWhisper").call(payload)
        let dict = callResult.data as? [String: Any] ?? [:]
        let success = (dict["success"] as? Bool) ?? false
        let message = (dict["message"] as? String) ?? (success ? "Funds added." : "Add funds failed.")

        // 4) Read the updated whisper to grab the latest balanceCents (if present)
        //    This keeps the UI consistent with your ledger.
        var newBalanceDollars: Double? = nil
        do {
            let snap = try await db.collection("whispers").document(whisperId).getDocument()
            if let data = snap.data() {
                if let bc = data["balanceCents"] as? Int {
                    newBalanceDollars = Double(bc) / 100.0
                } else if let bc = data["balanceCents"] as? NSNumber {
                    newBalanceDollars = bc.doubleValue / 100.0
                }
            }
        } catch {
            // non-fatal — we still return the callable’s message
        }

        return AddFundsResult(success: success, message: message, newBalance: newBalanceDollars)
    }

    // MARK: - Helpers

    private static func decimalToCents(_ amount: Decimal) throws -> Int {
        // Normalize to 2 decimal places and convert to cents
        var amt = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &amt, 2, .plain)

        // (rounded * 100) as NSDecimalNumber → Int
        let centsNumber = (rounded as NSDecimalNumber).multiplying(by: 100)
        let centsDouble = centsNumber.doubleValue

        guard centsDouble.isFinite else { throw NSError(domain: "PaymentsService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid amount"]) }

        // Avoid floating rounding issues by adding a tiny epsilon before floor
        let centsInt = Int((centsDouble + 0.0000001).rounded(.down))
        return centsInt
    }
}
