import AppKit
import Combine
import SwiftUI

struct GlobeFocusRequest {
    let city: WorldClockLocation
    let tactile: Bool
}

struct DaylightMapView: View {
    let palette: CalendarPalette
    @Binding var selected: WorldClockLocation?
    let swipes: AnyPublisher<TrackpadMotion, Never>
    let input: PopupInput
    @ObservedObject var location: LocalGlobeLocation

    let focusRequests: AnyPublisher<GlobeFocusRequest, Never>
    let showOptions: (GlobeMenu) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera: GlobeCamera
    @State private var dragStart: GlobeCamera?
    @State private var trackpadStart: GlobeCamera?
    @State private var pinchStart: GlobeCamera?
    @State private var dragSample: (translation: CGSize, date: Date)?
    @State private var dragVelocity: CGSize = .zero
    @State private var acceptsMomentum = false
    @State private var cameraTask: Task<Void, Never>?
    @State private var metal: GlobeMetalRenderer.Resources?
    @State private var preparing = true
    @State private var followsHome = true
    @AppStorage("GlobeLayer") private var layer = GlobeLayer.daylight
    @State private var weather: AppleWeatherField?
    @State private var weatherFailed = false

    private struct WeatherLoadKey: Hashable {
        let region: WeatherRegion
        let quarterHour: Int
    }

    private var hasWeatherView: Bool { layer != .daylight && AppleWeatherService.entitled }
    private var zoomLimit: Double { hasWeatherView ? WeatherRegion.mapZoom : GlobeCamera.maximumZoom }

    private struct Textures {
        let day: URL
        let night: URL
        let cloud: URL
    }

    private static let textures: Textures? = {
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        guard let day = bundle.url(forResource: "EarthDay", withExtension: "jpg", subdirectory: "EarthTextures"),
              let night = bundle.url(forResource: "EarthNight", withExtension: "jpg", subdirectory: "EarthTextures"),
              let cloud = bundle.url(forResource: "EarthClouds", withExtension: "jpg", subdirectory: "EarthTextures")
        else { return nil }
        return Textures(day: day, night: night, cloud: cloud)
    }()

    private static let preparation = {
        let textureURLs = textures
        return Task.detached(priority: .utility) {
            textureURLs.flatMap { GlobeMetalRenderer.Resources(dayURL: $0.day, nightURL: $0.night, cloudURL: $0.cloud) }
        }
    }()

    static func prepareGlobe() {
        _ = preparation
    }
    private static let fallback = textures.flatMap { EarthMapRenderer(dayURL: $0.day, nightURL: $0.night) }

    init(palette: CalendarPalette, selected: Binding<WorldClockLocation?>,
         swipes: AnyPublisher<TrackpadMotion, Never>, input: PopupInput, location: LocalGlobeLocation,
         focusRequests: AnyPublisher<GlobeFocusRequest, Never>, showOptions: @escaping (GlobeMenu) -> Void) {
        self.palette = palette
        _selected = selected
        self.swipes = swipes
        self.input = input
        self.location = location
        self.focusRequests = focusRequests
        self.showOptions = showOptions

        let overview = GlobeCamera.overview(sun: SolarPosition(at: .now), home: location.place ?? WorldClockLocation.localOrDefault)
        var start = selected.wrappedValue.map { overview.focused(on: $0) } ?? overview
        let savedLayer = GlobeLayer(rawValue: UserDefaults.standard.integer(forKey: "GlobeLayer")) ?? .daylight
        if savedLayer != .daylight, AppleWeatherService.entitled {
            start.zoom = WeatherRegion.mapZoom
        }
        _camera = State(initialValue: start)
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let sun = SolarPosition(at: context.date)
            let city = selected ?? location.place ?? WorldClockLocation.localOrDefault
            let region = city.map(WeatherRegion.init(around:))
            let field = weather?.region == region ? weather : nil
            let request = hasWeatherView ? region.map {
                WeatherLoadKey(region: $0, quarterHour: Int(context.date.timeIntervalSince1970 / 900))
            } : nil
            scene(active: city, at: context.date, sun: sun, field: field)
                .overlay(alignment: .bottomLeading) {
                    if let city {
                        if layer == .daylight {
                            GlobeSolarBadge(city: city, instant: context.date).equatable()
                                .padding(5)
                                .id(city.id)
                                .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 3)))
                                .allowsHitTesting(false)
                        } else {
                            GlobeWeatherBadge(layer: layer, city: city.name, field: field,
                                              instant: context.date,
                                              enabled: AppleWeatherService.entitled, failed: weatherFailed)
                                .padding(5)
                        }
                    }
                }
                .task(id: request) {
                    if let request { await loadWeather(request.region) }
                }
        }
        .task {
            metal = await Self.preparation.value
            preparing = false
            if metal != nil, let selected {
                camera = focusedCamera(on: selected)
            }
        }
        .onReceive(swipes, perform: orbitWithTrackpad)
        .onReceive(input.globePinches, perform: pinch)
        .onChange(of: location.coordinate) { _ in
            guard followsHome else { return }
            transition(to: overview(sun: SolarPosition(at: .now)))
        }
        .onReceive(focusRequests) { focusRequest in
            guard focusRequest.tactile || (dragStart == nil && pinchStart == nil) else { return }
            focus(on: focusRequest.city, withFeedback: focusRequest.tactile)
        }
        .onDisappear { stopCameraMotion() }
    }

    private func loadWeather(_ region: WeatherRegion) async {
        weatherFailed = false
        do {
            let loaded = try await AppleWeatherService.shared.field(for: region)
            if !Task.isCancelled { weather = loaded }
        } catch {
            if !Task.isCancelled { weatherFailed = true }
        }
    }

    private func scene(active: WorldClockLocation?, at date: Date, sun: SolarPosition,
                       field: AppleWeatherField?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7)

        return ZStack(alignment: .topTrailing) {
            if let metal {
                GlobeScene(
                    camera: camera, sun: sun, resources: metal, layer: layer, weather: field,
                    instant: date, selectedID: active?.id,
                    select: { location in focus(on: location, withFeedback: true) },
                    input: input, devicePlace: location.place,
                    zoomIn: { point, size in zoom(by: 1.52, around: point, in: size) }
                )
                .simultaneousGesture(orbitGesture)
            } else if preparing {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading globe")
            } else if let image = Self.fallback?.image(at: date, sun: sun) {
                GeometryReader { geometry in
                    let mapHeight = geometry.size.width / 2
                    ZStack {
                        Image(decorative: image, scale: 2).resizable()
                        ForEach(WorldClockLocation.locations + [location.place].compactMap { $0 }) { location in
                            GlobePin(selected: location.id == active?.id)
                                .position(x: (location.longitude + 180) / 360 * geometry.size.width,
                                          y: (90 - location.latitude) / 180 * mapHeight)
                        }
                    }
                    .frame(width: geometry.size.width, height: mapHeight)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                .accessibilityLabel("Daylight map")
            } else {
                Text("Earth imagery is unavailable")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 221)
        .background(palette.track, in: shape)
        .overlay(alignment: .topTrailing) {
            globeControl("ellipsis", label: "Options") {
                showOptions(GlobeMenu(
                    reset: metal == nil ? nil : {
                        selected = nil
                        followsHome = true
                        transition(to: overview(sun: sun))
                        feedback(.alignment)
                    },
                    layer: layer,
                    selectLayer: metal == nil ? nil : { choice in
                        selectLayer(choice, for: active, sun: sun)
                    }
                ))
            }
            .padding(5)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(palette.outline, lineWidth: 0.75).allowsHitTesting(false) }
    }

    private func globeControl(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(width: 22, height: 19)
                .background(Color(white: 0.16).opacity(0.88), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private var orbitGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { drag in
                guard pinchStart == nil else { return }
                if dragStart == nil {
                    followsHome = false
                    stopCameraMotion()
                    dragStart = camera
                }
                if let sample = dragSample {
                    let interval = drag.time.timeIntervalSince(sample.date)
                    if interval > 0.002, interval < 0.14 {
                        let x = (drag.translation.width - sample.translation.width) / interval
                        let y = (drag.translation.height - sample.translation.height) / interval
                        dragVelocity = CGSize(width: 0.24 * dragVelocity.width + 0.76 * x,
                                              height: 0.24 * dragVelocity.height + 0.76 * y)
                    } else {
                        dragVelocity = .zero
                    }
                }
                dragSample = (drag.translation, drag.time)
                if let dragStart {
                    camera = dragStart.orbit(horizontal: drag.translation.width, vertical: drag.translation.height)
                }
            }
            .onEnded { drag in
                if dragStart != nil, let sample = dragSample, drag.time.timeIntervalSince(sample.date) < 0.11 {
                    coast(with: dragVelocity)
                }
                dragStart = nil
                dragSample = nil
                dragVelocity = .zero
            }
    }

    private func pinch(_ event: PopupPinch) {
        if event.phase.contains(.cancelled) {
            if let pinchStart { transition(to: pinchStart) }
            pinchStart = nil
            return
        }
        if event.phase.contains(.began) { pinchStart = nil }
        magnify(event.scale, around: event.anchor, in: event.size)
        if event.phase.contains(.ended) {
            endMagnification(around: event.anchor, in: event.size)
        }
    }

    private func magnify(_ factor: CGFloat, around point: CGPoint, in size: CGSize) {
        if pinchStart == nil {
            followsHome = false
            stopCameraMotion()
            dragStart = nil
            dragSample = nil
            trackpadStart = nil
            pinchStart = camera
        }
        if let pinchStart {
            camera = pinchStart.magnified(by: factor, around: point, in: size, elastic: !reduceMotion, maximumZoom: zoomLimit)
        }
    }

    private func endMagnification(around point: CGPoint, in size: CGSize) {
        guard pinchStart != nil else { return }
        pinchStart = nil

        let zoom = camera.zoom
        let overview = hasWeatherView ? WeatherRegion.mapZoom : GlobeCamera.overviewZoom
        let target = abs(zoom - overview) < 0.045
            ? overview : min(zoomLimit, max(GlobeCamera.minimumZoom, zoom))
        if abs(zoom - target) > 0.001 {
            transition(to: camera.magnified(by: target / zoom, around: point, in: size, maximumZoom: zoomLimit))
            feedback(.levelChange)
        }
    }

    private func orbitWithTrackpad(_ motion: TrackpadMotion) {
        guard metal != nil, pinchStart == nil else { return }

        if motion.isMomentum {
            guard acceptsMomentum, !reduceMotion else { return }
            camera = camera.orbit(horizontal: -motion.travel.width, vertical: -motion.travel.height)
            if motion.finished || motion.cancelled { acceptsMomentum = false }
            return
        }

        if motion.started {
            followsHome = false
            stopCameraMotion()
            trackpadStart = camera
        }
        guard let trackpadStart else { return }

        if motion.cancelled {
            transition(to: trackpadStart)
        } else {
            camera = trackpadStart.orbit(horizontal: -motion.travel.width, vertical: -motion.travel.height)
        }
        if motion.finished || motion.cancelled {
            self.trackpadStart = nil
            acceptsMomentum = motion.finished && !motion.cancelled && hypot(motion.travel.width, motion.travel.height) > 8
        }
    }

    private func focus(on location: WorldClockLocation, withFeedback: Bool) {
        followsHome = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
            selected = location
        }
        if metal != nil {
            let target = focusedCamera(on: location)
            if reduceMotion {
                stopCameraMotion()
                camera = target
            } else {
                let flight = GlobeFlight(from: camera, to: target)
                animate(for: flight.duration) { time in camera = flight.frame(at: time) }
            }
        }
        if withFeedback { feedback(.alignment) }
    }

    private func stopCameraMotion() {
        cameraTask?.cancel()
        cameraTask = nil
        acceptsMomentum = false
    }

    private func transition(to destination: GlobeCamera) {
        stopCameraMotion()
        let start = camera
        let landing = camera.nearestEquivalent(of: destination)
        guard !reduceMotion else {
            camera = landing
            return
        }
        animate(for: 0.54) { time in
            let spring = 12 * time
            let progress = time >= 0.54 ? 1 : 1 - (1 + spring) * exp(-spring)
            camera = start.interpolated(to: landing, progress: progress)
        }
    }

    private func coast(with velocity: CGSize) {
        guard !reduceMotion else { return }
        let speed = hypot(velocity.width, velocity.height)
        guard speed > 50 else { return }
        let scale = min(1, 820 / speed)
        let start = camera
        animate(for: 0.90) { time in
            let distance = scale * (1 - exp(-5.5 * time)) / 5.5
            camera = start.orbit(horizontal: velocity.width * distance, vertical: velocity.height * distance)
        }
    }

    private func animate(for duration: TimeInterval, frame: @escaping (TimeInterval) -> Void) {
        stopCameraMotion()
        cameraTask = Task { @MainActor in
            let start = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                let elapsed = min(duration, ProcessInfo.processInfo.systemUptime - start)
                frame(elapsed)
                if elapsed >= duration { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func zoom(by factor: Double, around point: CGPoint? = nil, in size: CGSize = .zero) {
        let destination = camera.magnified(by: factor, around: point, in: size, maximumZoom: zoomLimit)
        guard camera.zoom != destination.zoom else { return }
        followsHome = false
        transition(to: destination)
        feedback(.levelChange)
    }

    private func selectLayer(_ choice: GlobeLayer, for city: WorldClockLocation?, sun: SolarPosition) {
        let wasWeather = hasWeatherView
        layer = choice
        if choice == .daylight, wasWeather {
            transition(to: selected.map { camera.focused(on: $0) } ?? overview(sun: sun))
        } else if hasWeatherView, !wasWeather, let city {
            transition(to: focusedCamera(on: city))
        }
    }

    private func focusedCamera(on city: WorldClockLocation) -> GlobeCamera {
        var target = camera.focused(on: city)
        if hasWeatherView { target.zoom = WeatherRegion.mapZoom }
        return target
    }

    private func overview(sun: SolarPosition) -> GlobeCamera {
        var target = GlobeCamera.overview(sun: sun, home: location.place ?? WorldClockLocation.localOrDefault)
        if hasWeatherView { target.zoom = WeatherRegion.mapZoom }
        return target
    }

    private func feedback(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

private struct GlobeScene: View {
    let camera: GlobeCamera
    let sun: SolarPosition
    let resources: GlobeMetalRenderer.Resources
    let layer: GlobeLayer
    let weather: AppleWeatherField?
    let instant: Date
    let selectedID: String?
    let select: (WorldClockLocation) -> Void

    let input: PopupInput
    let devicePlace: WorldClockLocation?
    let zoomIn: (CGPoint, CGSize) -> Void

    var body: some View {
        GeometryReader { geometry in
            let pins = (WorldClockLocation.locations + [devicePlace].compactMap { $0 }).compactMap { location in
                camera.project(location, in: geometry.size).map { Pin(location: location, point: $0) }
            }
            ZStack {
                GlobeMetalView(camera: camera, sun: sun, resources: resources, layer: layer,
                               weather: weather, instant: instant)
                    .allowsHitTesting(false)

                ForEach(pins) { pin in
                    GlobePin(selected: pin.id == selectedID)
                        .position(pin.point)
                        .zIndex(pin.id == selectedID ? 1 : 0)
                }
            }
            .background {
                PopupSurface(input: input, kind: .globe)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(taps(pins: pins, size: geometry.size))
            .accessibilityLabel("Interactive Earth globe with the current day and night boundary")
        }
    }

    private func taps(pins: [Pin], size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .exclusively(before: SpatialTapGesture())
            .onEnded { tap in
                switch tap {
                case let .first(double):
                    zoomIn(double.location, size)
                case let .second(single):
                    func distance(_ pin: Pin) -> CGFloat {
                        hypot(pin.point.x - single.location.x, pin.point.y - single.location.y)
                    }
                    if let pin = pins.min(by: { distance($0) < distance($1) }), distance(pin) <= 11 {
                        select(pin.location)
                    }
                }
            }
    }

    private struct Pin: Identifiable {
        let location: WorldClockLocation
        let point: CGPoint
        var id: String { location.id }
    }
}

private struct GlobePin: View {
    let selected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ripple = 1.0

    var body: some View {
        let gold = Color(red: 1, green: 0.74, blue: 0.35)
        ZStack {
            if selected {
                Circle().fill(gold.opacity(0.24)).frame(width: 15, height: 15)
                Circle()
                    .strokeBorder(gold.opacity(0.58 * (1 - ripple)), lineWidth: 1)
                    .frame(width: 16, height: 16)
                    .scaleEffect(1 + ripple * 0.75)
            }
            Circle()
                .fill(selected ? gold : Color.white.opacity(0.95))
                .overlay { Circle().strokeBorder(.black.opacity(0.55), lineWidth: 0.65) }
                .frame(width: selected ? 7 : 5, height: selected ? 7 : 5)
        }
        .onAppear { pulse() }
        .onChange(of: selected) { _ in pulse() }
        .accessibilityHidden(true)
    }

    private func pulse() {
        guard selected, !reduceMotion else { return }
        ripple = 0
        withAnimation(.easeOut(duration: 0.85)) { ripple = 1 }
    }
}
