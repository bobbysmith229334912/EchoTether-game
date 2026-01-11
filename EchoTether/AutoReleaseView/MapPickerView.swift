import SwiftUI
import MapKit

struct MapPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let initial: CLLocationCoordinate2D
    let radiusM: CLLocationDistance
    let onPick: (GeoPlace) -> Void

    @State private var position: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    @State private var placeName: String = "Chosen place"

    init(
        initial: CLLocationCoordinate2D = .init(latitude: 37.3349, longitude: -122.0090),
        radiusM: CLLocationDistance = 75,
        onPick: @escaping (GeoPlace) -> Void
    ) {
        self.initial = initial
        self.radiusM = radiusM
        self.onPick = onPick
        let region = MKCoordinateRegion(center: initial, span: .init(latitudeDelta: 0.004, longitudeDelta: 0.004))
        _position = State(initialValue: .region(region))
        _center   = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // iOS 17+ Map (no deprecations)
                Map(position: $position, interactionModes: .all) {
                    MapCircle(center: center, radius: radiusM)
                        .stroke(.blue.opacity(0.6), lineWidth: 2)
                }
                .onMapCameraChange { ctx in
                    center = ctx.region.center
                }
                .ignoresSafeArea(edges: .bottom)

                // Center reticle
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
                    .shadow(radius: 4)
            }
            .navigationTitle("Choose Place")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use This Place") {
                        onPick(GeoPlace(name: placeName, lat: center.latitude, lng: center.longitude))
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    MapPickerView { _ in }
}
