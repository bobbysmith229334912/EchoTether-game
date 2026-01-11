//  Whisper.swift
//  EchoTether
//
//  Strong model for list/map screens, parsing Firestore /whispers docs.

import Foundation
import CoreLocation
import FirebaseFirestore

struct Whisper: Identifiable {
    // Identity
    let id: String

    // Core media + timing
    let audioURL: URL
    let timestamp: Date
    let unlockAt: Date

    // Geo
    let latitude: Double
    let longitude: Double
    let radiusMeters: Double

    // Ownership / security
    let ownerId: String?
    let passwordHash: String?
    let isDeleted: Bool

    // Display
    let name: String?          // optional label for easier finding

    // Wallet
    let balance: Double?       // may be nil on older docs

    // MARK: - Init from Firestore dictionary
    init?(id: String, data: [String: Any]) {
        // audio URL
        guard let audioURLString = data["audioURL"] as? String,
              let audioURL = URL(string: audioURLString)
        else { return nil }

        // coordinates
        guard let lat = (data["latitude"] as? NSNumber)?.doubleValue ?? data["latitude"] as? Double,
              let lon = (data["longitude"] as? NSNumber)?.doubleValue ?? data["longitude"] as? Double
        else { return nil }

        // unlockAt
        guard let unlockTs = data["unlockAt"] as? Timestamp else { return nil }

        // radius (tolerate missing on old docs)
        let radius = (data["radiusMeters"] as? NSNumber)?.doubleValue
            ?? data["radiusMeters"] as? Double
            ?? 50.0

        // timestamp (fallbacks for older docs)
        let ts: Date = {
            if let t = data["timestamp"] as? Timestamp { return t.dateValue() }
            if let t = data["createdAt"] as? Timestamp { return t.dateValue() }
            return unlockTs.dateValue()
        }()

        self.id = id
        self.audioURL = audioURL
        self.latitude = lat
        self.longitude = lon
        self.unlockAt = unlockTs.dateValue()
        self.radiusMeters = radius
        self.timestamp = ts

        // optional / tolerant fields
        self.ownerId = data["ownerId"] as? String
        self.passwordHash = data["passwordHash"] as? String
        self.isDeleted = (data["deleted"] as? Bool) ?? false
        self.name = data["name"] as? String

        if let b = data["balance"] as? NSNumber {
            self.balance = b.doubleValue
        } else if let b = data["balance"] as? Double {
            self.balance = b
        } else if let s = data["balance"] as? String, let d = Double(s) {
            self.balance = d
        } else {
            self.balance = nil
        }
    }

    // MARK: - Helpers

    func isUnlocked(for userLocation: CLLocation?) -> Bool {
        guard let userLocation else { return false }
        guard Date() >= unlockAt else { return false }
        let drop = CLLocation(latitude: latitude, longitude: longitude)
        return userLocation.distance(from: drop) <= radiusMeters
    }

    func canBeDeleted(by currentUserId: String?) -> Bool {
        guard let currentUserId, let ownerId else { return false }
        return currentUserId == ownerId
    }

    var requiresPassword: Bool { passwordHash != nil }
}
