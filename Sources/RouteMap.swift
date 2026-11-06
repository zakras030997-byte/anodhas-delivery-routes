import SwiftUI
import MapKit

struct FreightRouteMap: NSViewRepresentable {
    var route: PlannedRoute
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(); map.delegate = context.coordinator
        map.showsScale = true; map.showsZoomControls = true; map.isRotateEnabled = false
        map.pointOfInterestFilter = .excludingAll
        return map
    }
    func updateNSView(_ map: MKMapView, context: Context) {
        let key = route.id.uuidString + ":" + String(route.polyline.count) + ":" + String(route.meters)
        guard context.coordinator.routeKey != key else { return }
        context.coordinator.routeKey = key
        map.removeOverlays(map.overlays); map.removeAnnotations(map.annotations)
        let annotations: [MKPointAnnotation] = route.steps.enumerated().compactMap { index, step in
            guard let c = step.coordinate else { return nil }
            let pin = MKPointAnnotation(); pin.coordinate = CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
            pin.title = "\(index + 1). \(step.title)"; pin.subtitle = step.address
            return pin
        }
        map.addAnnotations(annotations)
        if route.polyline.count >= 2 {
            var coordinates = route.polyline.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let line = MKPolyline(coordinates: &coordinates, count: coordinates.count)
            map.addOverlay(line)
            map.setVisibleMapRect(line.boundingMapRect, edgePadding: NSEdgeInsets(top: 24, left: 30, bottom: 24, right: 30), animated: false)
        } else if !annotations.isEmpty {
            map.showAnnotations(annotations, animated: false)
        }
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var routeKey = ""
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line); renderer.strokeColor = .systemOrange
                renderer.lineWidth = 4; renderer.lineCap = .round; renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "stop") as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "stop")
            view.annotation = annotation; view.markerTintColor = .systemOrange; view.canShowCallout = true
            return view
        }
    }
}
