import MapKit
import SwiftUI

/// Captures a `geotrace`/`geoshape` value: a `;`-separated sequence of `"lat lon alt
/// acc"` points, built by tapping "Add Current Location" repeatedly.
struct GeoTraceInputView: View {
    @Binding var value: String
    @StateObject private var service = LocationCaptureService()
    @State private var points: [CapturedLocation] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !points.isEmpty {
                Map(coordinateRegion: .constant(region), annotationItems: annotations) { annotation in
                    MapMarker(coordinate: annotation.coordinate)
                }
                .frame(height: 200)
                .cornerRadius(8)

                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    Text("\(index + 1). \(String(format: "%.5f, %.5f", point.latitude, point.longitude))")
                        .font(.system(.footnote, design: .monospaced))
                }
            } else {
                Text("No points captured yet.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    service.requestLocation()
                } label: {
                    Label("Add Current Location", systemImage: "location.fill")
                }
                .buttonStyle(.bordered)

                if !points.isEmpty {
                    Button(role: .destructive) {
                        points.removeLast()
                        commit()
                    } label: {
                        Label("Remove Last", systemImage: "minus.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let error = service.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { points = Self.parse(value) }
        .onChange(of: service.lastCapture) { capture in
            guard let capture else { return }
            points.append(capture)
            commit()
        }
    }

    private struct Annotation: Identifiable {
        let id: Int
        let coordinate: CLLocationCoordinate2D
    }

    private var annotations: [Annotation] {
        points.enumerated().map { Annotation(id: $0.offset, coordinate: CLLocationCoordinate2D(latitude: $0.element.latitude, longitude: $0.element.longitude)) }
    }

    private var region: MKCoordinateRegion {
        guard let last = points.last else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 0, longitude: 0), span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60))
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: last.latitude, longitude: last.longitude),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    }

    private func commit() {
        value = points.map(\.modelValue).joined(separator: ";")
    }

    private static func parse(_ value: String) -> [CapturedLocation] {
        value.split(separator: ";").compactMap { chunk in
            let parts = chunk.split(separator: " ").compactMap { Double($0) }
            guard parts.count >= 2 else { return nil }
            return CapturedLocation(
                latitude: parts[0],
                longitude: parts[1],
                altitude: parts.count > 2 ? parts[2] : 0,
                accuracy: parts.count > 3 ? parts[3] : 0
            )
        }
    }
}
