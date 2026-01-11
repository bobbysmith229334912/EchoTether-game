//
//  ClaimButton.swift
//  EchoTether
//
//  Created by Bobby Smith on 10/15/25.
//

import SwiftUI
import CoreLocation

struct ClaimButton: View {
    @ObservedObject var locationManager: LocationManager
    let dropId: String
    var minAccuracyMeters: CLLocationAccuracy = 50
    var timeout: TimeInterval = 8
    var maxAge: TimeInterval = 10
    var title: String = "Claim Auto Release"

    @State private var claiming = false
    @State private var showAlert = false
    @State private var alertText = ""

    var body: some View {
        Button {
            claim()
        } label: {
            if claiming {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text(title).frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(claiming || dropId.isEmpty)
        .alert("Claim", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertText)
        }
        .onAppear {
            // keep streaming so we likely have a warm fix
            locationManager.start()
        }
    }

    private func claim() {
        claiming = true
        alertText = ""
        locationManager.getFreshCoordinate(
            minAccuracyMeters: minAccuracyMeters,
            timeout: timeout,
            maxAge: maxAge
        ) { result in
            switch result {
            case .success(let coord):
                Task {
                    do {
                        let (_, msg) = try await AutoReleaseService.claim(dropId: dropId, at: coord)
                        alertText = msg
                    } catch {
                        alertText = error.localizedDescription
                    }
                    claiming = false
                    showAlert = true
                }
            case .failure(let err):
                alertText = err.localizedDescription
                claiming = false
                showAlert = true
            }
        }
    }
}
