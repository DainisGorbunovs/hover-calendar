import CoreGraphics
import Foundation

struct GlobeCamera {
    var latitude: Double
    var longitude: Double
    var zoom: Double

    static let minimumZoom = 0.78
    static let maximumZoom = 4.80
    static let overviewZoom = 1.24
    static let cityZoom = 2.18

    static func overview(sun: SolarPosition) -> Self {
        Self(latitude: 19, longitude: sun.longitude - 68, zoom: overviewZoom)
    }

    func focused(on location: WorldClockLocation) -> Self {
        nearestEquivalent(of: Self(latitude: location.latitude, longitude: location.longitude, zoom: Self.cityZoom))
    }

    func nearestEquivalent(of destination: Self) -> Self {
        let delta = (destination.longitude - longitude) * .pi / 180
        var camera = destination
        camera.longitude = longitude + atan2(sin(delta), cos(delta)) * 180 / .pi
        return camera
    }

    func interpolated(to destination: Self, progress: Double) -> Self {
        Self(latitude: latitude + (destination.latitude - latitude) * progress,
             longitude: longitude + (destination.longitude - longitude) * progress,
             zoom: zoom + (destination.zoom - zoom) * progress)
    }

    func orbit(horizontal: Double, vertical: Double) -> Self {
        let sensitivity = 0.72 / zoom
        return Self(latitude: min(82, max(-82, latitude + vertical * sensitivity)),
                    longitude: longitude - horizontal * sensitivity, zoom: zoom)
    }

    func magnified(by factor: Double, around point: CGPoint? = nil, in size: CGSize = .zero,
                   elastic: Bool = false) -> Self {
        let requested = zoom * factor
        let bounded = min(Self.maximumZoom, max(Self.minimumZoom, requested))
        let overflow = requested - bounded
        let target = bounded + (elastic ? 0.14 * overflow / (0.14 + abs(overflow)) : 0)
        let centered = Self(latitude: latitude, longitude: longitude, zoom: target)
        guard let point, size.width > 0, size.height > 0 else { return centered }

        let radius = Self.radius(in: size, zoom: zoom)
        let targetRadius = Self.radius(in: size, zoom: target)
        let offset = CGPoint(x: point.x - size.width / 2, y: size.height / 2 - point.y)
        let x = Double(offset.x / radius)
        let y = Double(offset.y / radius)
        let targetX = Double(offset.x / targetRadius)
        let targetY = Double(offset.y / targetRadius)
        guard x * x + y * y < 0.99, targetX * targetX + targetY * targetY < 0.99 else { return centered }

        // Find the surface point beneath the pinch, then solve for the camera that keeps it there.
        let radians = Double.pi / 180
        let tilt = latitude * radians
        let depth = sqrt(1 - x * x - y * y)
        let meridian = cos(tilt) * depth - sin(tilt) * y
        let north = sin(tilt) * depth + cos(tilt) * y
        let horizontal = hypot(meridian, x)
        guard horizontal > abs(targetX) else { return centered }

        let principal = asin(targetX / horizontal)
        let other = principal >= 0 ? .pi - principal : -.pi - principal
        let original = atan2(x, meridian)
        let relative = cos(principal - original) >= cos(other - original) ? principal : other
        let targetDepth = sqrt(1 - targetX * targetX - targetY * targetY)
        let targetTilt = atan2(north, horizontal * cos(relative)) - atan2(targetY, targetDepth)
        let degrees = targetTilt / radians
        guard (-82...82).contains(degrees) else { return centered }

        return Self(latitude: degrees, longitude: longitude + (original - relative) / radians, zoom: target)
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
