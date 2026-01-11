import Foundation
import CoreLocation
import UserNotifications

/// Monitors up to 20 nearby whispers and posts a local notification
/// ONLY when the user enters a region for a whisper they have NOT found yet,
/// and only if it passes the cooldown check in FoundAndNotifyStore.
final class GeoWhisperManager: NSObject, CLLocationManagerDelegate {
    static let shared = GeoWhisperManager()

    private let lm = CLLocationManager()
    private let workQueue = DispatchQueue(label: "com.echotether.geo")
    private let maxRegions = 20
    private var monitoredIds = Set<String>()   // keep track of what we’re monitoring

    private override init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyHundredMeters
        lm.distanceFilter = 50
    }

    /// Call once (e.g., app launch) to request permissions used for local notifications.
    func configure() {
        // Location permissions (When In Use is enough to start; Always recommended for full background geofencing)
        lm.requestWhenInUseAuthorization()

        // Local notifications permission
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Optional: call later (after explaining to the user) to improve background behavior.
    func requestAlwaysIfNeeded() {
        if lm.authorizationStatus == .authorizedWhenInUse {
            lm.requestAlwaysAuthorization()
        }
    }


    /// Monitor up to 20 closest (UNFOUND) whispers to the given user location.
    /// Call this whenever you refresh whispers or the user’s location meaningfully changes.
    func monitorNearest(whispers: [Whisper], userLocation: CLLocation) {
        workQueue.async {
            // Filter to unfound whispers only
            let unfound = whispers.filter { !FoundAndNotifyStore.isFound($0.id) }

            // Sort by distance, take closest <= 20
            let nearest = unfound.sorted {
                let a = CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                let b = CLLocation(latitude: $1.latitude, longitude: $1.longitude)
                return userLocation.distance(from: a) < userLocation.distance(from: b)
            }.prefix(self.maxRegions)

            // Stop monitoring anything not in the nearest set anymore
            for region in self.lm.monitoredRegions {
                if nearest.contains(where: { $0.id == region.identifier }) == false {
                    self.lm.stopMonitoring(for: region)
                    self.monitoredIds.remove(region.identifier)
                }
            }

            // Start monitoring any new nearest regions
            for w in nearest {
                if self.monitoredIds.contains(w.id) { continue }
                let center = CLLocationCoordinate2D(latitude: w.latitude, longitude: w.longitude)
                // Keep a practical radius for iOS geofencing
                let radius = max(50.0, min(w.radiusMeters, 200.0))
                let region = CLCircularRegion(center: center, radius: radius, identifier: w.id)
                region.notifyOnEntry = true
                region.notifyOnExit = false
                self.lm.startMonitoring(for: region)
                self.monitoredIds.insert(w.id)
            }
        }
    }

    /// Stop monitoring a specific whisper id (call after it’s found/played).
    func stopMonitoring(id: String) {
        workQueue.async {
            for region in self.lm.monitoredRegions where region.identifier == id {
                self.lm.stopMonitoring(for: region)
                self.monitoredIds.remove(id)
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let id = region.identifier

        // Only notify if the whisper is not found yet AND passes cooldown
        guard !FoundAndNotifyStore.isFound(id),
              FoundAndNotifyStore.shouldNotify(id) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Whisper nearby"
        content.body = "A new whisper just unlocked near you."
        content.sound = .default

        let req = UNNotificationRequest(identifier: "whisper-\(id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
