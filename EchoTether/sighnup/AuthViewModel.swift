//
//  AuthViewModel.swift
//  EchoTether
//
//  Created by Bobby Smith on 10/11/25.
//

import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import AuthenticationServices
import CryptoKit

@MainActor
final class AuthViewModel: NSObject, ObservableObject {
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var user: User?

    // Nonce for Sign in with Apple
    private var currentNonce: String?

    override init() {
        super.init()
        self.user = Auth.auth().currentUser

        // Keep local state in sync with Firebase Auth
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.user = user
                // Best-effort ensure user doc exists when the user becomes available
                if let user { await self?.ensureUserDoc(uid: user.uid, email: user.email) }
            }
        }
    }

    // MARK: - Email & Password
    func signUp(email: String, password: String) async {
        isLoading = true; errorMessage = nil
        do {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            self.user = result.user
            await ensureUserDoc(uid: result.user.uid, email: result.user.email)
        } catch {
            self.errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func signIn(email: String, password: String) async {
        isLoading = true; errorMessage = nil
        do {
            let result = try await Auth.auth().signIn(withEmail: email, password: password)
            self.user = result.user
            await ensureUserDoc(uid: result.user.uid, email: result.user.email)
        } catch {
            self.errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func signOut() {
        do {
            try Auth.auth().signOut()
            self.user = nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Sign in with Apple
    func startSignInWithApple() {
        let nonce = randomNonceString()
        currentNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    // MARK: - Firestore: ensure users/{uid} exists
    private func ensureUserDoc(uid: String, email: String?) async {
        let db = Firestore.firestore()
        let ref = db.collection("users").document(uid)
        do {
            try await ref.setData([
                "email": email ?? "",
                "updatedAt": FieldValue.serverTimestamp(),
                "createdAt": FieldValue.serverTimestamp()
            ], merge: true)
        } catch {
            // Non-fatal; keep going but log for diagnostics
            print("⚠️ ensureUserDoc error:", error.localizedDescription)
        }
    }

    // MARK: - Utilities
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let err = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            if err != errSecSuccess { fatalError("Unable to generate nonce.") }

            randoms.forEach { random in
                if remainingLength == 0 { return }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }
}

// MARK: - ASAuthorizationControllerDelegate
extension AuthViewModel: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController,
                                 didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            self.errorMessage = "AppleID credential missing."
            return
        }
        guard let nonce = currentNonce else {
            self.errorMessage = "Invalid state: no active login request."
            return
        }
        guard let appleIDToken = appleIDCredential.identityToken,
              let idTokenString = String(data: appleIDToken, encoding: .utf8) else {
            self.errorMessage = "Unable to fetch identity token."
            return
        }

        isLoading = true; errorMessage = nil
        let credential = OAuthProvider.credential(withProviderID: "apple.com",
                                                  idToken: idTokenString,
                                                  rawNonce: nonce)
        Task {
            do {
                let result = try await Auth.auth().signIn(with: credential)
                self.user = result.user

                // Persist user doc; include Apple-provided fields when available (first-time only)
                await ensureUserDoc(uid: result.user.uid, email: result.user.email)

                // Optionally store name if provided this time (Apple only provides it the first time)
                if let fullName = appleIDCredential.fullName,
                   (fullName.givenName?.isEmpty == false || fullName.familyName?.isEmpty == false) {
                    let displayName = [fullName.givenName, fullName.familyName].compactMap { $0 }.joined(separator: " ")
                    let db = Firestore.firestore()
                    try? await db.collection("users").document(result.user.uid)
                        .setData([
                            "displayName": displayName,
                            "updatedAt": FieldValue.serverTimestamp()
                        ], merge: true)
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        self.errorMessage = error.localizedDescription
    }
}

// MARK: - ASAuthorizationControllerPresentationContextProviding
extension AuthViewModel: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Best effort to get a window
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow ?? UIWindow()
    }
}
