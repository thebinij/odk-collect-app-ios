import CoreLocation

/// A single location fix, formatted the way `Geopoint`/`Geotrace`/`Geoshape` questions
/// store it in the model: `"lat lon alt acc"`.
struct CapturedLocation: Equatable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let accuracy: Double

    var modelValue: String {
        "\(latitude) \(longitude) \(altitude) \(accuracy)"
    }
}

/// Thin `CLLocationManager` wrapper for "use current location" capture — used by both
/// `GeopointInputView` (one fix) and `GeoTraceInputView` (one fix per tap).
final class LocationCaptureService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var lastCapture: CapturedLocation?
    @Published var errorMessage: String?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestLocation() {
        errorMessage = nil
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastCapture = CapturedLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            accuracy: location.horizontalAccuracy
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorMessage = error.localizedDescription
    }
}
