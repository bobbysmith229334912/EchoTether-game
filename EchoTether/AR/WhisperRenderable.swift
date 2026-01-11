// WhisperRenderable.swift

import Foundation
import CoreLocation
import FirebaseFirestore

struct WhisperRenderable: Identifiable, Hashable {
    let id: String

    // core
    let audioURL: URL?
    let ownerId: String?
    let timestamp: Date
    let unlockAt: Date
    let deleted: Bool

    // geo
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double

    // access control
    let passwordHash: String?

    // wallet
    let balance: Double?        // dollars (legacy)
    let balanceCents: Int?      // cents (preferred)

    init(id: String, dict: [String: Any]) {
        self.id = id

        if let s = dict["audioURL"] as? String {
            self.audioURL = URL(string: s)
        } else {
            self.audioURL = nil
        }

        self.ownerId = dict["ownerId"] as? String

        if let ts = dict["timestamp"] as? Timestamp {
            self.timestamp = ts.dateValue()
        } else if let d = dict["timestamp"] as? Date {
            self.timestamp = d
        } else {
            self.timestamp = Date(timeIntervalSince1970: 0)
        }

        if let ts = dict["unlockAt"] as? Timestamp {
            self.unlockAt = ts.dateValue()
        } else if let d = dict["unlockAt"] as? Date {
            self.unlockAt = d
        } else {
            self.unlockAt = Date()
        }

        self.deleted = (dict["deleted"] as? Bool) ?? false

        self.latitude  = (dict["latitude"]  as? NSNumber)?.doubleValue ?? dict["latitude"]  as? Double ?? 0.0
        self.longitude = (dict["longitude"] as? NSNumber)?.doubleValue ?? dict["longitude"] as? Double ?? 0.0
        self.radiusMeters = (dict["radiusMeters"] as? NSNumber)?.doubleValue ?? dict["radiusMeters"] as? Double ?? 50.0

        self.passwordHash = dict["passwordHash"] as? String

        // legacy dollars
        if let b = dict["balance"] as? NSNumber {
            self.balance = b.doubleValue
        } else if let b = dict["balance"] as? Double {
            self.balance = b
        } else if let s = dict["balance"] as? String, let d = Double(s) {
            self.balance = d
        } else {
            self.balance = nil
        }

        // preferred cents (top-level or nested)
        if let c = dict["balanceCents"] as? NSNumber {
            self.balanceCents = c.intValue
        } else if let wallet = dict["wallet"] as? [String: Any],
                  let c = wallet["balanceCents"] as? NSNumber {
            self.balanceCents = c.intValue
        } else if let c = dict["balanceCents"] as? Int {
            self.balanceCents = c
        } else {
            self.balanceCents = nil
        }
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    /// Geo/time lock check (password handled separately)
    func isUnlocked(for user: CLLocation?) -> Bool {
        guard Date() >= unlockAt else { return false }
        guard let user else { return false }
        let drop = CLLocation(latitude: latitude, longitude: longitude)
        let dist = user.distance(from: drop)
        guard dist.isFinite else { return false }
        return dist <= radiusMeters
    }
}
