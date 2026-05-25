//
//  EchoTetherMimojiConnectionPlan.swift
//  EchoTether-game
//
//  Safe additive connection plan.
//  This file intentionally avoids Firebase imports so it can be added safely.
//

import Foundation

public enum EchoTetherMimojiSource: String, CaseIterable, Codable, Identifiable {
    case userEchoActive = "users/{uid}/echoMimojis/active"
    case userActiveCurrent = "users/{uid}/activeMimoji/current"
    case userMimojisNewest = "users/{uid}/mimojis newest"
    case echoTetherOwned = "echoTetherMimojis ownerUid == uid"
    case echoTetherPublic = "echoTetherMimojis public"

    public var id: String { rawValue }
}

public struct EchoTetherMimojiConnectionPlan: Codable, Equatable {
    public var prioritySources: [EchoTetherMimojiSource]
    public var allowSignedOutFallback: Bool
    public var allowPublicFallback: Bool
    public var allowEmailFallback: Bool
    public var notes: [String]

    public static let safeDefault = EchoTetherMimojiConnectionPlan(
        prioritySources: [
            .userEchoActive,
            .userActiveCurrent,
            .userMimojisNewest,
            .echoTetherOwned,
            .echoTetherPublic
        ],
        allowSignedOutFallback: true,
        allowPublicFallback: true,
        allowEmailFallback: false,
        notes: [
            "Use signed-in UID first.",
            "Do not hardcode one user.",
            "Do not use email as the source of truth.",
            "If no Mimoji is found, keep EchoTether usable."
        ]
    )
}
