//
//  AuthBoot.swift
//  EchoTether
//
//  Created by Bobby Smith on 10/11/25.
//

import FirebaseAuth

enum AuthBoot {
    /// Ensures we have a Firebase user (anonymous is fine).
    static func ensure() async throws -> User {
        if let u = Auth.auth().currentUser { return u }
        let res = try await Auth.auth().signInAnonymously()
        return res.user
    }
}
