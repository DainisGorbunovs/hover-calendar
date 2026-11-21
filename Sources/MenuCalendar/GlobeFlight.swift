import Foundation
import simd

struct GlobeFlight {
    let duration: TimeInterval
    private let departure: GlobeCamera
    private let arrival: GlobeCamera
    private let startDirection: SIMD3<Double>
    private let endDirection: SIMD3<Double>
    private let angle: Double
    private let pullback: Double

    init(from departure: GlobeCamera, to arrival: GlobeCamera) {
        self.departure = departure
        self.arrival = departure.nearestEquivalent(of: arrival)
        startDirection = Self.direction(of: departure)
        endDirection = Self.direction(of: arrival)
        angle = acos(min(1, max(-1, simd_dot(startDirection, endDirection))))
        duration = 0.44 + 0.45 * angle / .pi

        let turn = min(1, max(0, (angle * 180 / .pi - 25) / 120))
        let closerEndpoint = min(departure.zoom, arrival.zoom)
        pullback = max(GlobeCamera.minimumZoom, closerEndpoint - turn * max(0, closerEndpoint - 0.90))
    }

    func frame(at elapsed: TimeInterval) -> GlobeCamera {
        let t = min(1, max(0, elapsed / duration))
        guard t > 0 else { return departure }
        guard t < 1 else { return arrival }

        let fraction = t * t * t * (t * (6 * t - 15) + 10)
        var camera = departure.interpolated(to: arrival, progress: fraction)
        let separation = sin(angle)
        if separation > 0.0001 {
            // Interpolate on the sphere so long jumps follow a great circle.
            let direction = (startDirection * sin((1 - fraction) * angle) + endDirection * sin(fraction * angle))
                / separation
            let latitude = asin(min(1, max(-1, direction.z))) * 180 / .pi
            camera.latitude = min(82, max(-82, latitude))
            camera.longitude = atan2(direction.y, direction.x) * 180 / .pi
            camera = departure.nearestEquivalent(of: camera)
        }

        // Pull back during a long turn, then ease in on the destination.
        if pullback < min(departure.zoom, arrival.zoom) {
            let midpoint = 0.44
            if t <= midpoint {
                camera.zoom = Self.ease(from: departure.zoom, to: pullback, at: t / midpoint)
            } else {
                camera.zoom = Self.ease(from: pullback, to: arrival.zoom, at: (t - midpoint) / (1 - midpoint))
            }
        }
        return camera
    }

    private static func ease(from start: Double, to end: Double, at t: Double) -> Double {
        start + (end - start) * t * t * (3 - 2 * t)
    }

    private static func direction(of camera: GlobeCamera) -> SIMD3<Double> {
        let latitude = camera.latitude * .pi / 180
        let longitude = camera.longitude * .pi / 180
        return SIMD3(cos(latitude) * cos(longitude), cos(latitude) * sin(longitude), sin(latitude))
    }
}
