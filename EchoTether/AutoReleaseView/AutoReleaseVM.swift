//
//  AutoReleaseVM.swift
//  EchoTether
//
//  Created by Bobby Smith on 10/15/25.
//

import Foundation
import SwiftUI

// MARK: - Lightweight models used by the builder screen

struct UserLite: Identifiable, Codable, Equatable {
    let id: String                  // Firebase auth UID
    let handle: String              // "@handle" style or plain "handle"
    let displayName: String?        // Optional friendly display

    // Convenience: presentable text
    var title: String {
        if let dn = displayName, !dn.isEmpty { return dn }
        return handle.isEmpty ? "@user" : handle
    }
}

struct GroupLite: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let members: [String]           // user IDs (UIDs)
}

struct GeoPlace: Equatable {
    var name: String
    var lat: Double
    var lng: Double
}

enum ClaimPolicy: String, Codable { case first = "FIRST"; case each = "EACH" }

// MARK: - ViewModel

final class AutoReleaseVM: ObservableObject {
    enum Mode { case person, group, trustedAny }

    // Recipient
    @Published var mode: Mode = .person
    @Published var selectedUser: UserLite?          // for .person
    @Published var selectedGroup: GroupLite?        // for .group
    @Published var policy: ClaimPolicy = .first     // for group/trusted
    @Published var perUserCap: Int = 1              // only used when policy = .each

    // Trigger
    @Published var place: GeoPlace?
    @Published var radiusM: Double = 75
    @Published var notBefore: Date?

    // Payment
    @Published var amountCents: Int = 0
    @Published var message: String = ""

    // UI state
    @Published var creating: Bool = false
    @Published var lastError: String?

    // Basic validity for the Create button
    var isValid: Bool {
        guard amountCents > 0, place != nil else { return false }
        switch mode {
        case .person:   return selectedUser != nil
        case .group:    return selectedGroup != nil
        case .trustedAny: return true
        }
    }

    // Optional: light reset helpers
    func resetRecipient() {
        selectedUser = nil
        selectedGroup = nil
        policy = .first
        perUserCap = 1
        lastError = nil
    }

    func resetAll() {
        mode = .person
        resetRecipient()
        place = nil
        radiusM = 75
        notBefore = nil
        amountCents = 0
        message = ""
        creating = false
    }
}

// MARK: - Username/people helpers for the builder (uses UserDirectoryService)

extension AutoReleaseVM {
    /// Resolve `@handle` (or plain "handle") → set `selectedUser`
    @MainActor
    func setRecipientByHandle(_ handle: String) async {
        // Guard against empty inputs
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        do {
            if let prof = try await UserDirectoryService.shared.fetchProfile(handle: trimmed) {
                self.selectedUser = UserLite(
                    id: prof.id,
                    handle: prof.handle ?? (trimmed.hasPrefix("@") ? trimmed : "@\(trimmed)"),
                    displayName: prof.displayName
                )
            } else {
                self.lastError = "Handle not found."
            }
        } catch {
            self.lastError = error.localizedDescription
            print("handle resolve error:", error.localizedDescription)
        }
    }

    /// Type-ahead user search by handle prefix, returns light user rows
    @MainActor
    func searchPeople(prefix: String, limit: Int = 10) async -> [UserLite] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            let hits = try await UserDirectoryService.shared.searchUsers(prefix: trimmed, limit: limit)
            return hits.map {
                UserLite(
                    id: $0.id,
                    handle: $0.handle ?? "@\($0.id.prefix(6))",
                    displayName: $0.displayName
                )
            }
        } catch {
            self.lastError = error.localizedDescription
            print("search error:", error.localizedDescription)
            return []
        }
    }
}
