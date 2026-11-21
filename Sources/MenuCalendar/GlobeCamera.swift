import CoreGraphics
import Foundation

struct GlobeCamera {
    var latitude: Double
    var longitude: Double
    var zoom: Double

    static let minimumZoom = 0.78
    static let maximumZoom = 1.85

    static func overview(sun: SolarPosition) -> Self {
        Self(latitude: 19, longitude: sun.longitude - 68, zoom: 1)
    }

    func focused(on location: WorldClockLocation) -> Self {
        let delta = (location.longitude - longitude) * .pi / 180
        return Self(latitude: location.latitude, longitude: longitude + atan2(sin(delta), cos(delta)) * 180 / .pi,
                    zoom: 1.48)
    }

    func orbit(horizontal: Double, vertical: Double) -> Self {
        let sensitivity = 0.72 / zoom
        return Self(latitude: min(82, max(-82, latitude + vertical * sensitivity)),
                    longitude: longitude - horizontal * sensitivity, zoom: zoom)
    }

    func magnified(by factor: Double) -> Self {
        Self(latitude: latitude, longitude: longitude,
             zoom: min(Self.maximumZoom, max(Self.minimumZoom, zoom * factor)))
    }

    static func radius(in size: CGSize, zoom: Double) -> CGFloat {
        min(size.width, size.height) * 0.46 * zoom
    }

    func project(_ location: WorldClockLocation, in size: CGSize) -> CGPoint? {
        let radians = Double.pi / 180
        let latitude = location.latitude * radians
        let centralLatitude = self.latitude * radians
        let longitude = (location.longitude - self.longitude) * radians

        let alongMeridian = cos(latitude) * cos(longitude)
        let depth = sin(centralLatitude) * sin(latitude) + cos(centralLatitude) * alongMeridian
        guard depth > 0.07 else { return nil }

        let east = cos(latitude) * sin(longitude)
        let north = cos(centralLatitude) * sin(latitude) - sin(centralLatitude) * alongMeridian
        let radius = Self.radius(in: size, zoom: zoom)
        let point = CGPoint(x: size.width / 2 + radius * east, y: size.height / 2 - radius * north)
        return CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3).contains(point) ? point : nil
    }
}
