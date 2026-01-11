// LocationManager.swift

import Foundation
import CoreLocation
import Combine

/// One manager for everything:
/// - Publishes authorization + last location for UI
/// - Provides a one-shot "fresh" coordinate with accuracy + timeout (completion-based to avoid Swift 6 Sendable warnings)
final class LocationManager: NSObject, ObservableObject {

    // MARK: Published state
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var lastError: Error?

    // MARK: Internals
    private let manager = CLLocationManager()

    // One-shot bookkeeping (completion style to avoid @Sendable capture warnings)
    private var freshCompletion: ((Result<CLLocationCoordinate2D, Error>) -> Void)?
    private var freshDeadlineTimer: Timer?
    private var accuracyThreshold: CLLocationAccuracy = 50      // meters
    private var recencyThreshold: TimeInterval = 10             // seconds

    // MARK: Init
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = false
    }

    // MARK: Streaming lifecycle
    func start() {
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    /// Ask Core Location for a single sample (does not affect streaming).
    func requestLocationOnce() { manager.requestLocation() }

    // MARK: One-shot fresh coordinate (completion-based)
    func getFreshCoordinate(
        minAccuracyMeters: CLLocationAccuracy = 50,
        timeout: TimeInterval = 8,
        maxAge: TimeInterval = 10,
        completion: @escaping (Result<CLLocationCoordinate2D, Error>) -> Void
    ) {
        // Permission gate
        let status = manager.authorizationStatus
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.getFreshCoordinate(minAccuracyMeters: minAccuracyMeters, timeout: timeout, maxAge: maxAge, completion: completion)
            }
            return
        case .denied, .restricted:
            completion(.failure(LocationError.permissionDenied))
            return
        default:
            break
        }

        // If we already have a good fix, return it
        if let loc = lastLocation,
           Date().timeIntervalSince(loc.timestamp) <= maxAge,
           loc.horizontalAccuracy > 0,
           loc.horizontalAccuracy <= minAccuracyMeters
        {
            completion(.success(loc.coordinate))
            return
        }

        // Prepare one-shot configuration
        accuracyThreshold = minAccuracyMeters
        recencyThreshold = maxAge

        // Start one-shot
        freshCompletion = completion
        manager.desiredAccuracy = (minAccuracyMeters <= 10) ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyBest
        manager.requestLocation()

        // Timeout
        freshDeadlineTimer?.invalidate()
        freshDeadlineTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.finishOneShot(.failure(LocationError.timeout))
        }
        RunLoop.main.add(freshDeadlineTimer!, forMode: .common)
    }

    // MARK: Helpers
    private func finishOneShot(_ result: Result<CLLocationCoordinate2D, Error>) {
        freshDeadlineTimer?.invalidate()
        freshDeadlineTimer = nil
        if let cb = freshCompletion {
            freshCompletion = nil
            cb(result)
        }
    }
}

// MARK: - CLLocationManagerDelegate
extension LocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .denied || authorization == .restricted {
            lastError = LocationError.permissionDenied
            finishOneShot(.failure(LocationError.permissionDenied))
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastError = error
        finishOneShot(.failure(error))
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let newest = locations.last else { return }
        lastLocation = newest

        // If a one-shot is waiting, validate recency + accuracy
        if freshCompletion != nil {
            let age = Date().timeIntervalSince(newest.timestamp)
            if newest.horizontalAccuracy > 0,
               newest.horizontalAccuracy <= accuracyThreshold,
               age <= recencyThreshold
            {
                finishOneShot(.success(newest.coordinate))
            }
        }
    }
}

// MARK: - Errors
enum LocationError: LocalizedError {
    case permissionDenied
    case timeout

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Location permission is required to verify you’re at the unlock place."
        case .timeout:          return "Couldn’t get an accurate location in time. Try again."
        }
    }
}
