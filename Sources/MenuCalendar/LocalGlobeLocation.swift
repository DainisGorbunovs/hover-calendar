import Combine
import CoreLocation
import Foundation

@MainActor
final class LocalGlobeLocation: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    struct Coordinate: Equatable {
        let latitude: Double
        let longitude: Double
    }

    @Published private(set) var coordinate: Coordinate?

    private let manager = CLLocationManager()
    private var waitingForPermission = false
    private var inFlight = false
    private var lastAttempt: Date?
    private var lastFix: Date?

    override init() {
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.delegate = self
    }

    var authorization: CLAuthorizationStatus { manager.authorizationStatus }

    var updatesAllowed: Bool {
        // macOS reports the shared authorization level as authorizedAlways.
        authorization == .authorizedAlways
    }

    var place: WorldClockLocation? {
        coordinate.map {
            WorldClockLocation(name: "My Location", timeZone: .autoupdatingCurrent, flag: "",
                               latitude: $0.latitude, longitude: $0.longitude, id: "current-device-location")
        }
    }

    func requestAccess() {
        switch authorization {
        case .notDetermined:
            guard !waitingForPermission else { return }
            waitingForPermission = true
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways:
            refresh(force: true)
        default:
            break
        }
    }

    func refresh(force: Bool = false) {
        guard updatesAllowed, !inFlight else { return }
        let now = Date.now
        if !force {
            if let lastFix, now.timeIntervalSince(lastFix) < 15 * 60 { return }
            if let lastAttempt, now.timeIntervalSince(lastAttempt) < 45 { return }
        }
        lastAttempt = now
        inFlight = true
        manager.requestLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let requested = waitingForPermission
        if authorization != .notDetermined { waitingForPermission = false }
        if updatesAllowed {
            if requested { refresh(force: true) }
        } else {
            coordinate = nil
            lastFix = nil
            lastAttempt = nil
            inFlight = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        inFlight = false
        let now = Date.now
        guard updatesAllowed,
              let fix = locations.last(where: {
                  CLLocationCoordinate2DIsValid($0.coordinate) && $0.horizontalAccuracy >= 0
                      && abs(now.timeIntervalSince($0.timestamp)) < 15 * 60
              })
        else { return }

        lastFix = fix.timestamp
        let next = Coordinate(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        if coordinate != next { coordinate = next }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        inFlight = false
    }
}
