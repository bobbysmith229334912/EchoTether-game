import Foundation
import FirebaseFunctions
import CoreLocation

@MainActor
enum AutoReleaseService {
    private static let functions = Functions.functions(region: "us-central1")

    struct ClaimResult: Codable {
        let success: Bool
        let message: String
        let receivedCents: Int?
    }

    static func claim(dropId: String, at location: CLLocationCoordinate2D) async throws -> (Bool, String) {
        let data: [String: Any] = [
            "dropId": dropId,
            "lat": location.latitude,
            "lon": location.longitude
        ]

        let result = try await functions.httpsCallable("claimAutoRelease").call(data)
        if let dict = result.data as? [String: Any],
           let success = dict["success"] as? Bool,
           let message = dict["message"] as? String {
            return (success, message)
        } else {
            throw NSError(domain: "AutoReleaseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response from server"])
        }
    }
}
