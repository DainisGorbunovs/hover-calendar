import MetalKit
import SwiftUI

struct GlobeMetalView: NSViewRepresentable {
    let camera: GlobeCamera
    let sun: SolarPosition
    let resources: GlobeMetalRenderer.Resources
    let layer: GlobeLayer
    let weather: AppleWeatherField?
    let instant: Date

    func makeCoordinator() -> GlobeMetalRenderer {
        GlobeMetalRenderer(resources: resources)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: resources.device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0.003, green: 0.005, blue: 0.012, alpha: 1)
        view.preferredFramesPerSecond = 30
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.camera = camera
        context.coordinator.sun = sun
        context.coordinator.setWeather(weather, at: instant, layer: layer)
        let animated = layer == .wind && weather != nil && !context.environment.accessibilityReduceMotion
        context.coordinator.animateWind = animated
        if view.isPaused == animated { view.isPaused = !animated }
        view.needsDisplay = true
    }
}

final class GlobeMetalRenderer: NSObject, MTKViewDelegate {
    // The immutable pipeline and textures are shared by load-once and draw contexts.
    struct Resources: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        let day: MTLTexture
        let night: MTLTexture
        let clouds: MTLTexture
        let emptyWeather: MTLTexture
        let colorRamps: MTLTexture
        /// Fades the previous wind trails, then draws particles' moves on top.
        let trailFadePipeline: MTLRenderPipelineState
        let particlePipeline: MTLRenderPipelineState
        /// Stands in for the trails when no wind is drawn.
        let emptyTrail: MTLTexture

        init?(dayURL: URL, nightURL: URL, cloudURL: URL) {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue(),
                  let emptyWeather = device.makeTexture(descriptor: .texture2DDescriptor(
                    pixelFormat: .rgba16Unorm, width: 1, height: 1, mipmapped: false)),
                  let emptyTrail = device.makeTexture(descriptor: .texture2DDescriptor(
                    pixelFormat: .r16Float, width: 1, height: 1, mipmapped: false)),
                  let colorRamps = Self.makeColorRamps(device: device)
            else { return nil }
            self.emptyWeather = emptyWeather
            self.emptyTrail = emptyTrail
            self.colorRamps = colorRamps
            var zero = SIMD4<UInt16>.zero
            emptyWeather.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                                 withBytes: &zero, bytesPerRow: MemoryLayout<SIMD4<UInt16>>.stride)
            var noTrail: UInt16 = 0
            emptyTrail.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                               withBytes: &noTrail, bytesPerRow: MemoryLayout<UInt16>.stride)
            do {
                let library = try device.makeLibrary(source: GlobeMetalRenderer.shader, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "globeVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "globeFragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

                let fade = MTLRenderPipelineDescriptor()
                fade.vertexFunction = library.makeFunction(name: "trailFadeVertex")
                fade.fragmentFunction = library.makeFunction(name: "trailFadeFragment")
                fade.colorAttachments[0].pixelFormat = .r16Float
                let particles = MTLRenderPipelineDescriptor()
                particles.vertexFunction = library.makeFunction(name: "particleVertex")
                particles.fragmentFunction = library.makeFunction(name: "particleFragment")
                particles.colorAttachments[0].pixelFormat = .r16Float

                let loader = MTKTextureLoader(device: device)
                let options: [MTKTextureLoader.Option: Any] = [
                    .origin: MTKTextureLoader.Origin.topLeft, .SRGB: true, .generateMipmaps: true
                ]
                self.device = device
                self.queue = queue
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                trailFadePipeline = try device.makeRenderPipelineState(descriptor: fade)
                particlePipeline = try device.makeRenderPipelineState(descriptor: particles)
                day = try loader.newTexture(URL: dayURL, options: options)
                night = try loader.newTexture(URL: nightURL, options: options)
                clouds = try loader.newTexture(URL: cloudURL, options: [
                    .origin: MTKTextureLoader.Origin.topLeft, .SRGB: false, .generateMipmaps: true
                ])
            } catch {
                NSLog("Menu Calendar globe: %@", String(describing: error))
                return nil
            }
        }

        /// One row of colour per weather layer, indexed by `GlobeLayer.rawValue`.
        ///
        /// Each row resamples that layer's ramp across the same value range the
        /// sample texture encodes, so the shader can turn an encoded reading
        /// straight into a colour with a single lookup.
        private static func makeColorRamps(device: MTLDevice) -> MTLTexture? {
            let width = 256
            let rows = GlobeLayer.allCases.count
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm_srgb, width: width, height: rows, mipmapped: false)
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

            var pixels = [UInt8](repeating: 0, count: width * rows * 4)
            for layer in GlobeLayer.allCases {
                guard let stops = layer.colorStops else { continue }
                for column in 0..<width {
                    let position = Double(column) / Double(width - 1)
                    let color = WeatherColorScale.color(in: stops, at: layer.value(at: position))
                    let offset = (layer.rawValue * width + column) * 4
                    pixels[offset] = UInt8((color.r * 255).rounded())
                    pixels[offset + 1] = UInt8((color.g * 255).rounded())
                    pixels[offset + 2] = UInt8((color.b * 255).rounded())
                    pixels[offset + 3] = UInt8((color.a * 255).rounded())
                }
            }
            pixels.withUnsafeBytes { bytes in
                if let address = bytes.baseAddress {
                    texture.replace(region: MTLRegionMake2D(0, 0, width, rows), mipmapLevel: 0,
                                    withBytes: address, bytesPerRow: width * 4)
                }
            }
            return texture
        }
    }

    var camera: GlobeCamera?
    var sun: SolarPosition?
    var animateWind = false
    private let resources: Resources
    private var weatherLayer = GlobeLayer.daylight
    private var weatherRegion: WeatherRegion?
    private var weatherCoverage = AppleWeatherField.Coverage.grid
    /// One uploaded grid per forecast hour, kept while the region holds still.
    private var frameTextures: [Date: MTLTexture] = [:]
    /// The two hours the globe is drawing between, and how far across it sits.
    private var blend: (earlier: MTLTexture, later: MTLTexture, progress: Float)?

    /// Made the first time the wind layer is shown.
    private lazy var particles: WindParticles? = WindParticles(resources: resources)
    private var windField: WindField?
    /// The field the particles were last scattered for. Their trails are
    /// rebuilt when it changes, and carried on smoothly when only the hour does.
    private var particleField: (region: WeatherRegion, coverage: AppleWeatherField.Coverage)?
    private var lastParticleStep: TimeInterval?

    private struct Uniforms {
        var front: SIMD4<Float>
        var east: SIMD4<Float>
        var north: SIMD4<Float>
        var sun: SIMD4<Float>
        var viewport: SIMD4<Float>
        var weatherRegion: SIMD4<Float>
        var weatherState: SIMD4<Float>
        var weatherScale: SIMD4<Float>
    }

    init(resources: Resources) {
        self.resources = resources
    }

    func setWeather(_ field: AppleWeatherField?, at instant: Date, layer: GlobeLayer) {
        weatherLayer = layer
        guard let field, layer != .daylight, let bracket = field.bracket(at: instant) else {
            blend = nil
            frameTextures.removeAll()
            weatherRegion = nil
            windField = nil
            particleField = nil
            return
        }
        if weatherRegion != field.region || weatherCoverage != field.coverage {
            frameTextures.removeAll()
            weatherRegion = field.region
            weatherCoverage = field.coverage
        }
        guard let earlier = texture(for: bracket.earlier),
              let later = texture(for: bracket.later) else {
            blend = nil
            return
        }
        blend = (earlier, later, Float(bracket.progress))

        guard layer == .wind,
              let wind = WindField(region: field.region, earlier: bracket.earlier,
                                   later: bracket.later, progress: bracket.progress)
        else {
            windField = nil
            particleField = nil
            return
        }
        windField = wind
        if particleField?.region != field.region || particleField?.coverage != field.coverage {
            particles?.warmUp(through: wind)
            particleField = (field.region, field.coverage)
            lastParticleStep = nil
        }
    }

    /// Uploads one forecast hour, reusing the grid if it is already on the GPU.
    private func texture(for frame: WeatherFrame) -> MTLTexture? {
        if let existing = frameTextures[frame.date] { return existing }
        let side = WeatherRegion.side
        guard frame.samples.count == side * side,
              let texture = resources.device.makeTexture(descriptor: .texture2DDescriptor(
                pixelFormat: .rgba16Unorm, width: side, height: side, mipmapped: false))
        else { return nil }

        let values = frame.samples.flatMap(\.textureChannels)
        values.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress {
                texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0,
                                withBytes: address, bytesPerRow: side * 4 * MemoryLayout<UInt16>.stride)
            }
        }
        frameTextures[frame.date] = texture
        return texture
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let camera, let sun, let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let buffer = resources.queue.makeCommandBuffer() else { return }

        let drawnLayer = blend == nil ? GlobeLayer.daylight : weatherLayer

        // Move the wind particles on before the globe samples their trails.
        // With motion reduced they hold still, showing the trails they were
        // warmed up with.
        var trail = resources.emptyTrail
        if drawnLayer == .wind, let windField, let particles {
            if animateWind {
                let now = ProcessInfo.processInfo.systemUptime
                let seconds = lastParticleStep.map { Float(now - $0) } ?? 1 / 30
                lastParticleStep = now
                particles.step(through: windField, seconds: seconds, into: buffer)
            }
            trail = particles.trail
        }
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            // Still commit, so the particles' hold on their segment buffer is released.
            buffer.commit()
            return
        }

        let lat = Float(camera.latitude) * .pi / 180
        let lon = Float(camera.longitude) * .pi / 180
        let solarLat = Float(sun.latitude) * .pi / 180
        let solarLon = Float(sun.longitude) * .pi / 180
        let diameter = Float(2 * GlobeCamera.radius(in: view.drawableSize, zoom: camera.zoom))
        let weatherBounds = (blend == nil ? nil : weatherRegion).map {
            SIMD4(Float($0.north), Float($0.west), Float($0.latitudeSpan), Float($0.longitudeSpan))
        } ?? .zero
        var uniforms = Uniforms(
            front: [cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat), 0],
            east: [-sin(lon), cos(lon), 0, 0],
            north: [-sin(lat) * cos(lon), -sin(lat) * sin(lon), cos(lat), 0],
            sun: [cos(solarLat) * cos(solarLon), cos(solarLat) * sin(solarLon), sin(solarLat), 0],
            viewport: [Float(view.drawableSize.width) / diameter, Float(view.drawableSize.height) / diameter, .pi * diameter, 0],
            weatherRegion: weatherBounds,
            weatherState: [Float(drawnLayer.rawValue), 0,
                           Float(drawnLayer.overlayOpacity), Float(GlobeLayer.allCases.count)],
            weatherScale: [Float(GlobeLayer.wind.domain.upperBound),
                           Float(WeatherSample.windComponentLimit), blend?.progress ?? 0,
                           weatherCoverage == .point ? 1 : 0]
        )

        encoder.setRenderPipelineState(resources.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(resources.day, index: 0)
        encoder.setFragmentTexture(resources.night, index: 1)
        encoder.setFragmentTexture(resources.clouds, index: 2)
        encoder.setFragmentTexture(blend?.earlier ?? resources.emptyWeather, index: 3)
        encoder.setFragmentTexture(resources.colorRamps, index: 4)
        encoder.setFragmentTexture(blend?.later ?? resources.emptyWeather, index: 5)
        encoder.setFragmentTexture(trail, index: 6)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vertex {
        float4 position [[position]];
        float2 screen;
    };

    struct Uniforms {
        float4 front, east, north, sun, viewport, weatherRegion, weatherState, weatherScale;
    };

    vertex Vertex globeVertex(uint index [[vertex_id]]) {
        const float2 triangle[] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        return { float4(triangle[index], 0, 1), triangle[index] };
    }

    // Wind trails live in the weather region's coordinates: x runs east and
    // y runs south across the region, both from 0 to 1, matching the readings.
    struct TrailVertex {
        float4 position [[position]];
        float2 uv;
    };

    vertex TrailVertex trailFadeVertex(uint index [[vertex_id]]) {
        const float2 triangle[] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        float2 corner = triangle[index];
        return { float4(corner, 0, 1), float2(corner.x * 0.5 + 0.5, 0.5 - corner.y * 0.5) };
    }

    // Each step starts from the previous trails, dimmed, so older moves fade.
    fragment float4 trailFadeFragment(TrailVertex input [[stage_in]],
                                      texture2d<float> previous [[texture(0)]],
                                      constant float& survival [[buffer(0)]]) {
        constexpr sampler exact(address::clamp_to_edge, filter::nearest);
        return float4(previous.sample(exact, input.uv).r * survival, 0, 0, 1);
    }

    struct ParticleVertex {
        float4 position [[position]];
    };

    // Each particle's latest move, as a line from where it was to where it is.
    vertex ParticleVertex particleVertex(uint index [[vertex_id]],
                                         const device float2* points [[buffer(0)]]) {
        float2 point = points[index];
        return { float4(point.x * 2.0 - 1.0, 1.0 - point.y * 2.0, 0, 1) };
    }

    fragment float4 particleFragment(ParticleVertex input [[stage_in]]) {
        return float4(1, 0, 0, 1);
    }

    float2 earthUV(float3 normal) {
        const float pi = 3.14159265359;
        return float2(0.5 + atan2(normal.y, normal.x) / (2.0 * pi),
                      0.5 - asin(clamp(normal.z, -1.0, 1.0)) / pi);
    }

    float4 weatherColor(float2 earth, constant Uniforms& globe, texture2d<float> weather,
                        texture2d<float> ramps, texture2d<float> weatherLater,
                        texture2d<float> trails) {
        float latitude = 90.0 - earth.y * 180.0;
        float longitude = earth.x * 360.0 - 180.0;
        float offset = fmod(longitude - globe.weatherRegion.y + 360.0, 360.0);
        float2 uv = float2(offset / globe.weatherRegion.w, (globe.weatherRegion.x - latitude) / globe.weatherRegion.z);
        if (any(uv < 0.0) || any(uv > 1.0)) { return float4(0.0); }

        // Map the grid boundary to the centers of its first and last samples.
        constexpr sampler field(address::clamp_to_edge, filter::linear);
        float2 size = float2(weather.get_width(), weather.get_height());
        float2 grid = (uv * (size - 1.0) + 0.5) / size;
        // Blend the two forecast hours in stored units, before any colour is
        // chosen, the way Apple's own tweening pass does.
        float4 reading = mix(weather.sample(field, grid),
                             weatherLater.sample(field, grid),
                             globe.weatherScale.z);
        float coverage = smoothstep(0.0, 0.06, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
        // One place's forecast is drawn as a halo around it, fading well
        // before the region's edge, rather than as though it held across the
        // whole region. The region is close to square on the ground, so a
        // circle in its coordinates is close to a circle on the globe.
        if (globe.weatherScale.w > 0.5) {
            float reach = length((uv - 0.5) * 2.0);
            coverage *= 1.0 - smoothstep(0.3, 0.95, reach);
        }

        // One row of the ramp texture per layer; sRGB sampling returns linear colour.
        constexpr sampler ramp(address::clamp_to_edge, filter::linear);
        float layer = globe.weatherState.x;
        float row = (layer + 0.5) / max(globe.weatherState.w, 1.0);

        float position;
        float streak = 0.0;
        if (layer == 3.0) {
            float limit = max(globe.weatherScale.y, 1.0);
            float ceiling = max(globe.weatherScale.x, 1.0);
            float2 velocity = reading.ba * (2.0 * limit) - limit;
            float speed = length(velocity);
            position = min(speed / ceiling, 1.0);

            // The particles' trails, kept in the same region coordinates.
            constexpr sampler trailSampler(address::clamp_to_edge, filter::linear);
            streak = smoothstep(0.04, 0.85, trails.sample(trailSampler, uv).r);
        } else {
            position = layer == 1.0 ? reading.r : reading.g;
        }

        float4 swatch = ramps.sample(ramp, float2(position, row));
        float3 color = mix(swatch.rgb, float3(0.63, 0.91, 1.0), streak);
        float opacity = min(1.0, swatch.a * globe.weatherState.z * (1.0 + 0.5 * streak));
        return float4(color, opacity * coverage);
    }

    fragment float4 globeFragment(Vertex input [[stage_in]],
                                  constant Uniforms& globe [[buffer(0)]],
                                  texture2d<float> day [[texture(0)]],
                                  texture2d<float> night [[texture(1)]],
                                  texture2d<float> clouds [[texture(2)]],
                                  texture2d<float> weather [[texture(3)]],
                                  texture2d<float> ramps [[texture(4)]],
                                  texture2d<float> weatherLater [[texture(5)]],
                                  texture2d<float> trails [[texture(6)]]) {
        constexpr sampler imagery(s_address::repeat, t_address::clamp_to_edge,
                                   min_filter::linear, mag_filter::linear, mip_filter::linear);
        const float cloudRadius = 1.009;
        const float3 sky = float3(0.003, 0.005, 0.013);
        float2 disk = input.screen * globe.viewport.xy;
        float distance = length(disk);
        float edgeWidth = max(fwidth(distance), 0.001);
        float3 rimDirection = normalize(globe.east.xyz * disk.x + globe.north.xyz * disk.y
                                        + globe.front.xyz * 0.002);
        float rimSunlight = smoothstep(-0.26, 0.68, dot(rimDirection, globe.sun.xyz));
        float halo = exp(-max(distance - 1.0, 0.0) * 52.0);
        float3 space = sky + halo * mix(float3(0.006, 0.016, 0.041),
                                       float3(0.032, 0.11, 0.24), rimSunlight);
        if (distance > cloudRadius + edgeWidth) {
            return float4(space, 1.0);
        }

        float depth = sqrt(max(0.0001, 1.0 - dot(disk, disk)));
        float3 normal = normalize(globe.front.xyz * depth + globe.east.xyz * disk.x + globe.north.xyz * disk.y);
        float2 uv = earthUV(normal);
        float incidence = dot(normal, globe.sun.xyz);
        // Set the mip level explicitly so the date-line wrap does not create a false seam.
        float footprint = 1.0 / max(globe.viewport.z * max(depth, 0.24), 1.0);
        float terrainLevel = max(0.0, log2(float(day.get_width()) * footprint));
        float lightLevel = max(0.0, log2(float(night.get_width()) * footprint));
        float cloudLevel = max(0.0, log2(float(clouds.get_width()) * footprint));
        float3 terrain = day.sample(imagery, uv, level(terrainLevel)).rgb;
        float3 lights = night.sample(imagery, uv, level(lightLevel)).rgb;
        float daylight = smoothstep(-0.105, 0.055, incidence);
        float twilight = 4.0 * daylight * (1.0 - daylight);
        float irradiance = 0.25 + 0.75 * sqrt(saturate(incidence));

        // Follow the actual light ray up to the cloud shell to cast a separate shadow on the terrain.
        float lightDistance = sqrt(incidence * incidence + cloudRadius * cloudRadius - 1.0) - incidence;
        float3 shadowDirection = normalize(normal + globe.sun.xyz * lightDistance);
        float shadowCover = smoothstep(0.26, 0.90, clouds.sample(imagery, earthUV(shadowDirection), level(cloudLevel)).r);
        float cloudShadow = shadowCover * smoothstep(0.0, 0.20, incidence) * 0.33;
        float3 sunlit = (terrain * irradiance + float3(0.002, 0.010, 0.034) * irradiance) * (1.0 - cloudShadow);

        // Water picks up a tight reflection where the viewing and lighting angles meet.
        float3 halfway = normalize(globe.sun.xyz + globe.front.xyz + float3(0.00001));
        float ocean = smoothstep(0.009, 0.035, terrain.b - terrain.g)
            * (1.0 - smoothstep(0.025, 0.1, terrain.g));
        float glint = pow(saturate(dot(normal, halfway)), 64.0) * ocean * daylight * (1.0 - shadowCover);
        sunlit += float3(0.14, 0.23, 0.28) * glint;

        float3 shadow = lights * 1.55 + terrain * 0.035 + float3(0.002, 0.003, 0.008);
        float3 surface = mix(shadow, sunlit, daylight) + twilight * float3(0.025, 0.011, 0.017);
        float air = pow(1.0 - saturate(depth), 3.0);
        surface += air * mix(float3(0.010, 0.023, 0.055), float3(0.05, 0.16, 0.38), rimSunlight);
        float silhouette = 1.0 - smoothstep(1.0 - edgeWidth, 1.0 + edgeWidth, distance);
        float3 scene = mix(space, surface, silhouette);

        float cloudDepth = sqrt(max(0.0001, cloudRadius * cloudRadius - dot(disk, disk)));
        float3 cloudNormal = normalize(globe.front.xyz * cloudDepth + globe.east.xyz * disk.x + globe.north.xyz * disk.y);
        float cloudSun = dot(cloudNormal, globe.sun.xyz);
        float cloudLight = smoothstep(-0.115, 0.10, cloudSun);
        float mask = clouds.sample(imagery, earthUV(cloudNormal), level(cloudLevel)).r;
        float coverage = smoothstep(0.22, 0.88, mask) * (0.64 + air * 0.13);
        float3 cloudColor = mix(float3(0.013, 0.022, 0.046),
                                float3(0.88, 0.94, 1.04) * (0.33 + 0.67 * sqrt(saturate(cloudSun))),
                                cloudLight);
        float edge = 1.0 - smoothstep(cloudRadius - edgeWidth, cloudRadius + edgeWidth, distance);
        scene = mix(scene, cloudColor, coverage * edge);
        if (globe.weatherState.x > 0.0 && distance < 1.0) {
            float4 weatherLayer = weatherColor(uv, globe, weather, ramps, weatherLater, trails);
            scene = mix(scene, weatherLayer.rgb, weatherLayer.a * silhouette);
        }
        return float4(scene, 1.0);
    }
    """
}
