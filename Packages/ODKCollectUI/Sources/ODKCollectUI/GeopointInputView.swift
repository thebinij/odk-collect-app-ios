import SwiftUI

/// Captures a single `geopoint` value (`"lat lon alt acc"`) via the device's current
/// location, with a manual lat/long fallback for indoor use or the simulator.
struct GeopointInputView: View {
    @Binding var value: String
    @StateObject private var service = LocationCaptureService()
    @State private var showsManualEntry = false
    @State private var manualLatitude = ""
    @State private var manualLongitude = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if value.isEmpty {
                Text("No location captured yet.")
                    .foregroundStyle(.secondary)
            } else {
                Text(value)
                    .font(.system(.footnote, design: .monospaced))
            }

            Button {
                service.requestLocation()
            } label: {
                Label("Use Current Location", systemImage: "location.fill")
            }
            .buttonStyle(.bordered)

            if let error = service.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            DisclosureGroup("Enter coordinates manually", isExpanded: $showsManualEntry) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Latitude", text: $manualLatitude)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.roundedBorder)
                    TextField("Longitude", text: $manualLongitude)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.roundedBorder)
                    Button("Use These Coordinates") {
                        guard let lat = Double(manualLatitude), let lon = Double(manualLongitude) else { return }
                        value = CapturedLocation(latitude: lat, longitude: lon, altitude: 0, accuracy: 0).modelValue
                    }
                    .buttonStyle(.bordered)
                    .disabled(Double(manualLatitude) == nil || Double(manualLongitude) == nil)
                }
                .padding(.top, 8)
            }
        }
        .onChange(of: service.lastCapture) { capture in
            guard let capture else { return }
            value = capture.modelValue
        }
    }
}
