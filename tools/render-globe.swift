import AppKit
import CoreGraphics
import ImageIO
import Metal
import MetalKit
import UniformTypeIdentifiers

// Renders the globe offscreen with a made-up forecast, so the weather overlays
// can be checked without a WeatherKit entitlement. It drives the real renderer,
// not a copy of it, so what lands in the PNGs is what the popup draws.
//
// Run it with tools/render-globe.sh.

@main
enum RenderGlobe {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count > 2 else {
            FileHandle.standardError.write(Data("usage: render-globe <textures> <output>\n".utf8))
            exit(64)
        }
        let textureDirectory = URL(fileURLWithPath: arguments[1])
        let outputDirectory = URL(fileURLWithPath: arguments[2])
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        guard let resources = GlobeMetalRenderer.Resources(
            dayURL: textureDirectory.appendingPathComponent("EarthDay.jpg"),
            nightURL: textureDirectory.appendingPathComponent("EarthNight.jpg"),
            cloudURL: textureDirectory.appendingPathComponent("EarthClouds.jpg"))
        else {
            FileHandle.standardError.write(Data("could not build the renderer\n".utf8))
            exit(1)
        }

        let home = WorldClockLocation.localOrDefault ?? WorldClockLocation.locations[0]
        let region = WeatherRegion(around: home)
        let base = Date(timeIntervalSince1970: 1_800_043_200)

        /// A grid that sweeps each layer's whole range, so a ramp that is wrong in
        /// part shows it. `shift` moves the weather on by one hour.
        func forecastFrame(hour: Int, shift: Double) -> WeatherFrame {
            var samples: [WeatherSample] = []
            for row in 0..<WeatherRegion.side {
                for column in 0..<WeatherRegion.side {
                    let across = Double(column) / Double(WeatherRegion.side - 1)
                    let down = Double(row) / Double(WeatherRegion.side - 1)
                    samples.append(WeatherSample(
                        temperature: -30 + across * 75 + shift * 20,
                        precipitation: [0, 0.3, 1.2, 6, 40][column] * (0.4 + down) * (1 + shift),
                        east: (across - 0.5) * 180 + shift * 60,
                        north: (down - 0.5) * 140
                    ))
                }
            }
            return WeatherFrame(date: base.addingTimeInterval(Double(hour) * 3600), samples: samples)
        }

        let field = AppleWeatherField(region: region,
                                      frames: [forecastFrame(hour: 0, shift: 0),
                                               forecastFrame(hour: 1, shift: 1)],
                                      attribution: nil)

        let size = CGSize(width: 540, height: 442)   // the panel's globe at 2x
        let view = MTKView(frame: CGRect(origin: .zero, size: size), device: resources.device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.drawableSize = size

        let renderer = GlobeMetalRenderer(resources: resources)
        renderer.sun = SolarPosition(at: base)

        func write(_ texture: MTLTexture, named name: String) {
            var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                guard let address = bytes.baseAddress else { return }
                texture.getBytes(address, bytesPerRow: texture.width * 4,
                                 from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            }
            // The drawable is BGRA, so label it that way rather than swizzling.
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)
            let url = outputDirectory.appendingPathComponent(name)
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let image = CGImage(width: texture.width, height: texture.height, bitsPerComponent: 8,
                                      bitsPerPixel: 32, bytesPerRow: texture.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: info, provider: provider, decode: nil,
                                      shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else {
                FileHandle.standardError.write(Data("could not write \(name)\n".utf8))
                return
            }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            print(url.path)
        }

        func render(_ name: String, camera: GlobeCamera, layer: GlobeLayer, at instant: Date,
                    from source: AppleWeatherField? = nil) {
            renderer.camera = camera
            renderer.sun = SolarPosition(at: instant)
            renderer.animateWind = layer == .wind
            renderer.setWeather(layer == .daylight ? nil : source ?? field, at: instant, layer: layer)
            guard let drawable = view.currentDrawable else {
                FileHandle.standardError.write(Data("no drawable offscreen\n".utf8))
                exit(2)
            }
            renderer.draw(in: view)
            resources.queue.makeCommandBuffer().map { $0.commit(); $0.waitUntilCompleted() }
            write(drawable.texture, named: name)
        }

        // The opening view, and a city in focus.
        render("globe-default.png",
               camera: GlobeCamera.overview(sun: SolarPosition(at: base), home: home),
               layer: .daylight, at: base)
        render("globe-city.png",
               camera: GlobeCamera.overview(sun: SolarPosition(at: base), home: home).focused(on: home),
               layer: .daylight, at: base)

        // Each weather layer over its region, and the blend across one hour.
        let weatherCamera = GlobeCamera(latitude: region.latitude, longitude: region.longitude,
                                        zoom: WeatherRegion.mapZoom)
        for layer in [GlobeLayer.temperature, .precipitation, .wind] {
            let name = layer.title.replacingOccurrences(of: " ", with: "")
            for percent in [0, 50, 100] {
                render("weather-\(name)-\(percent).png", camera: weatherCamera, layer: layer,
                       at: base.addingTimeInterval(Double(percent) / 100 * 3600))
            }
        }

        // The same layers from Apple's live forecast, for the first world-clock
        // city Weather tracks on this Mac, drawn the way the popup draws it.
        let now = Date.now
        let tracked = ([home] + WorldClockLocation.locations).lazy.compactMap { city in
            (try? AppleWeatherService.storedField(for: WeatherRegion(around: city))).map { (city, $0) }
        }.first
        guard let (city, live) = tracked else {
            print("no world-clock city is tracked by Weather; skipping the live renders")
            return
        }
        let liveCamera = GlobeCamera(latitude: live.region.latitude, longitude: live.region.longitude,
                                     zoom: WeatherRegion.mapZoom)
        for layer in [GlobeLayer.temperature, .precipitation, .wind] {
            let name = layer.title.replacingOccurrences(of: " ", with: "")
            render("live-\(name).png", camera: liveCamera, layer: layer, at: now, from: live)
        }
        if let reading = live.center(at: now) {
            print(String(format: "live: %@ %.1f °C, %.2f mm/h, wind %.0f km/h", city.name,
                         reading.temperature, reading.precipitation, hypot(reading.east, reading.north)))
        }

        // And the full grid for the same region, through the user's shortcut,
        // if it has been added.
        do {
            let frames = AppleWeatherService.frames(from: try await ShortcutWeather.forecasts(for: live.region))
            let grid = AppleWeatherField(region: live.region, frames: frames, attribution: nil)
            for layer in [GlobeLayer.temperature, .precipitation, .wind] {
                let name = layer.title.replacingOccurrences(of: " ", with: "")
                render("live-grid-\(name).png", camera: liveCamera, layer: layer, at: now, from: grid)
            }
            if let first = frames.first {
                let temperatures = first.samples.map(\.temperature)
                print(String(format: "live grid: %d hours, %.1f…%.1f °C across the region",
                             frames.count, temperatures.min() ?? .nan, temperatures.max() ?? .nan))
            }
        } catch {
            print("no live grid (\(error)); add the Menu Calendar Weather shortcut to draw one")
        }
    }
}
