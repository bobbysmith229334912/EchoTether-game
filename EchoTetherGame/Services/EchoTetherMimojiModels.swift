//
//  EchoTetherMimojiModels.swift
//  EchoTether-game
//
//  Safe additive models for the Mimoji connection layer.
//

import Foundation

public struct EchoTetherMimojiModel: Identifiable, Codable, Equatable {
    public var id: String
    public var ownerUid: String
    public var displayName: String
    public var usdzURL: String?
    public var avatarUSDZURL: String?
    public var previewImageURL: String?
    public var isPublicForEchoTether: Bool
    public var createdAt: Date?
    public var updatedAt: Date?

    public var resolvedModelURL: String? {
        let primary = usdzURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondary = avatarUSDZURL?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let primary, !primary.isEmpty {
            return primary
        }

        if let secondary, !secondary.isEmpty {
            return secondary
        }

        return nil
    }

    public init(
        id: String,
        ownerUid: String,
        displayName: String,
        usdzURL: String? = nil,
        avatarUSDZURL: String? = nil,
        previewImageURL: String? = nil,
        isPublicForEchoTether: Bool = false,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.ownerUid = ownerUid
        self.displayName = displayName
        self.usdzURL = usdzURL
        self.avatarUSDZURL = avatarUSDZURL
        self.previewImageURL = previewImageURL
        self.isPublicForEchoTether = isPublicForEchoTether
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct EchoTetherMimojiDiagnostics: Codable, Equatable {
    public var isSignedIn: Bool
    public var currentUid: String?
    public var activeMimojiFound: Bool
    public var resolvedModelURLFound: Bool
    public var checkedSources: [String]
    public var message: String

    public init(
        isSignedIn: Bool = false,
        currentUid: String? = nil,
        activeMimojiFound: Bool = false,
        resolvedModelURLFound: Bool = false,
        checkedSources: [String] = [],
        message: String = "Not checked yet."
    ) {
        self.isSignedIn = isSignedIn
        self.currentUid = currentUid
        self.activeMimojiFound = activeMimojiFound
        self.resolvedModelURLFound = resolvedModelURLFound
        self.checkedSources = checkedSources
        self.message = message
    }
}
