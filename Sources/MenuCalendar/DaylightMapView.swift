import AppKit
import Combine
import SwiftUI

struct DaylightMapView: View {
    let palette: CalendarPalette
    @Binding var selected: WorldClockLocation?
    let swipes: AnyPublisher<TrackpadMotion, Never>

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera: GlobeCamera
    @State private var dragStart: GlobeCamera?
    @State private var trackpadStart: GlobeCamera?
    @State private var pinchStart: Double?
    @State private var hoverTask: Task<Void, Never>?
    @State private var metal: GlobeMetalRenderer.Resources?
    @State private var preparing = true
    @State private var isChoosingCity = false

    private let locations = WorldClockLocation.locations

    private struct Textures {
        let day: URL
        let night: URL
    }

    private static let textures: Textures? = {
        let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        guard let day = bundle.url(forResource: "EarthDay", withExtension: "jpg", subdirectory: "EarthTextures"),
              let night = bundle.url(forResource: "EarthNight", withExtension: "jpg", subdirectory: "EarthTextures")
        else { return nil }
        return Textures(day: day, night: night)
    }()

    private static let preparation = {
        let textureURLs = textures
        return Task.detached(priority: .utility) {
            textureURLs.flatMap { GlobeMetalRenderer.Resources(dayURL: $0.day, nightURL: $0.night) }
        }
    }()

    static func prepareGlobe() {
        _ = preparation
    }
    private static let fallback = textures.flatMap { EarthMapRenderer(dayURL: $0.day, nightURL: $0.night) }

    init(palette: CalendarPalette, selected: Binding<WorldClockLocation?>, swipes: AnyPublisher<TrackpadMotion, Never>) {
        self.palette = palette
        _selected = selected
        self.swipes = swipes

        let overview = GlobeCamera.overview(sun: SolarPosition(at: .now))
        _camera = State(initialValue: selected.wrappedValue.map { overview.focused(on: $0) } ?? overview)
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let sun = SolarPosition(at: context.date)
            let active = selected ?? locations.first
            scene(active: active, at: context.date, sun: sun)
                .overlay(alignment: .bottom) {
                    if let active {
                        globeBar(for: active, at: context.date, sun: sun)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if isChoosingCity {
                        cityPicker(active)
                            .padding(.leading, 6)
                            .padding(.bottom, 33)
                    }
                }
        }
        .task {
            metal = await Self.preparation.value
            preparing = false
        }
        .onReceive(swipes, perform: orbitWithTrackpad)
        .onDisappear { hoverTask?.cancel() }
    }

    private func scene(active: WorldClockLocation?, at date: Date, sun: SolarPosition) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)

        return ZStack(alignment: .topTrailing) {
            if let metal {
                GlobeScene(camera: camera, sun: sun, resources: metal, selectedID: active?.id) { location in
                    isChoosingCity = false
                    if let location { focus(on: location, withFeedback: true) }
                }
                .simultaneousGesture(orbitGesture)
                .simultaneousGesture(pinchGesture)

                VStack(spacing: 2) {
                    globeControl("arrow.counterclockwise", label: "Reset globe view") {
                        hoverTask?.cancel()
                        transition(to: .overview(sun: sun))
                        feedback(.alignment)
                    }
                    globeControl("plus", label: "Zoom in") { zoom(by: 1.18) }
                    globeControl("minus", label: "Zoom out") { zoom(by: 1 / 1.18) }
                }
                .padding(6)
                .zIndex(1)
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
                        ForEach(locations) { location in
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
        .clipShape(shape)
        .overlay { shape.strokeBorder(palette.outline).allowsHitTesting(false) }
    }

    private func globeControl(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(width: 23, height: 21)
                .background(Color(white: 0.16).opacity(0.88), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func cityPicker(_ active: WorldClockLocation?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(locations) { location in
                let isSelected = location.id == active?.id
                Button {
                    focus(on: location, withFeedback: true)
                    isChoosingCity = false
                } label: {
                    HStack(spacing: 6) {
                        Text(location.flag)
                            .font(.system(size: 12))
                            .accessibilityHidden(true)
                        Text(location.name)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                        Spacer(minLength: 4)
                    }
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 6)
                    .frame(width: 115, height: 19)
                    .background(
                        isSelected ? palette.activeTab : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                }
                .buttonStyle(CalendarButtonStyle(palette: palette))
                .onHover { entered in preview(location, hovering: entered) }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityHint("Focuses the globe on this city")
            }
        }
        .padding(4)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(palette.outline)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.32), radius: 8, y: 3)
    }

    private func globeBar(for location: WorldClockLocation, at date: Date, sun: SolarPosition) -> some View {
        let reading = location.reading(at: date)
        let elevation = sun.elevation(at: location)
        let light: (label: String, symbol: String)
        if elevation >= -0.833 {
            light = ("Daylight", "sun.max.fill")
        } else if elevation >= -6 {
            light = ("Twilight", "sun.horizon.fill")
        } else {
            light = ("Night", "moon.stars.fill")
        }

        return HStack(spacing: 5) {
            Button {
                isChoosingCity.toggle()
                if !isChoosingCity { hoverTask?.cancel() }
            } label: {
                HStack(spacing: 4) {
                    Text(location.name).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7)
                .frame(height: 23)
                .background(Color(white: 0.17).opacity(0.88), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose a city, currently \(location.name)")
            .help("Choose a city")

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Image(systemName: light.symbol)
                    .help(light.label)
                Text(reading.zone)
                    .lineLimit(1)
                Text(reading.time)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6)
            .frame(height: 23)
            .background(Color(white: 0.15).opacity(0.88), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(location.name), \(light.label), \(reading.zone), \(reading.time)")
        }
        .foregroundStyle(.white)
    }

    private var orbitGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { drag in
                if dragStart == nil {
                    hoverTask?.cancel()
                    dragStart = camera
                }
                guard let dragStart else { return }
                let position = dragStart.orbit(horizontal: drag.translation.width, vertical: drag.translation.height)
                camera.latitude = position.latitude
                camera.longitude = position.longitude
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { factor in
                if pinchStart == nil {
                    hoverTask?.cancel()
                    pinchStart = camera.zoom
                }
                guard let pinchStart else { return }
                let start = GlobeCamera(latitude: camera.latitude, longitude: camera.longitude, zoom: pinchStart)
                camera = start.magnified(by: factor)
            }
            .onEnded { _ in
                pinchStart = nil
                if abs(camera.zoom - 1) < 0.05 {
                    transition(to: camera.magnified(by: 1 / camera.zoom))
                    feedback(.levelChange)
                } else if camera.zoom == GlobeCamera.minimumZoom || camera.zoom == GlobeCamera.maximumZoom {
                    feedback(.levelChange)
                }
            }
    }

    private func orbitWithTrackpad(_ motion: TrackpadMotion) {
        guard metal != nil, !isChoosingCity else { return }
        if motion.started {
            hoverTask?.cancel()
            trackpadStart = camera
        }
        guard let trackpadStart else { return }

        if motion.cancelled {
            transition(to: trackpadStart)
        } else {
            camera = trackpadStart.orbit(horizontal: -motion.travel.width, vertical: -motion.travel.height)
        }
        if motion.finished || motion.cancelled { self.trackpadStart = nil }
    }

    private func preview(_ location: WorldClockLocation, hovering: Bool) {
        hoverTask?.cancel()
        guard hovering else { return }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled else { return }
            focus(on: location, withFeedback: false)
        }
    }

    private func focus(on location: WorldClockLocation, withFeedback: Bool) {
        hoverTask?.cancel()
        selected = location
        if metal != nil { transition(to: camera.focused(on: location)) }
        if withFeedback { feedback(.alignment) }
    }

    private func transition(to destination: GlobeCamera) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.40)) {
            camera = destination
        }
    }

    private func zoom(by factor: Double) {
        hoverTask?.cancel()
        let destination = camera.magnified(by: factor)
        guard camera.zoom != destination.zoom else { return }
        transition(to: destination)
        feedback(.levelChange)
    }

    private func feedback(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

private struct GlobeScene: View, Animatable {
    var camera: GlobeCamera
    let sun: SolarPosition
    let resources: GlobeMetalRenderer.Resources
    let selectedID: String?
    let select: (WorldClockLocation?) -> Void

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(camera.latitude, AnimatablePair(camera.longitude, camera.zoom)) }
        set {
            camera.latitude = newValue.first
            camera.longitude = newValue.second.first
            camera.zoom = newValue.second.second
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let pins = WorldClockLocation.locations.compactMap { location in
                camera.project(location, in: geometry.size).map { Pin(location: location, point: $0) }
            }
            ZStack {
                GlobeMetalView(camera: camera, sun: sun, resources: resources)
                    .allowsHitTesting(false)

                ForEach(pins) { pin in
                    GlobePin(selected: pin.id == selectedID)
                        .position(pin.point)
                        .zIndex(pin.id == selectedID ? 1 : 0)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap in
                func distance(_ pin: Pin) -> CGFloat {
                    hypot(pin.point.x - tap.location.x, pin.point.y - tap.location.y)
                }
                if let pin = pins.min(by: { distance($0) < distance($1) }), distance(pin) <= 11 {
                    select(pin.location)
                } else {
                    select(nil)
                }
            })
            .accessibilityLabel("Interactive Earth globe with the current day and night boundary")
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

    var body: some View {
        let gold = Color(red: 1, green: 0.74, blue: 0.35)
        ZStack {
            if selected {
                Circle().fill(gold.opacity(0.26)).frame(width: 15, height: 15)
            }
            Circle()
                .fill(selected ? gold : Color.white.opacity(0.95))
                .overlay { Circle().strokeBorder(.black.opacity(0.55), lineWidth: 0.65) }
                .frame(width: selected ? 7 : 5, height: selected ? 7 : 5)
        }
        .accessibilityHidden(true)
    }
}
