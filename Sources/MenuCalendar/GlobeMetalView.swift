import MetalKit
import SwiftUI

struct GlobeMetalView: NSViewRepresentable {
    let camera: GlobeCamera
    let sun: SolarPosition
    let resources: GlobeMetalRenderer.Resources

    func makeCoordinator() -> GlobeMetalRenderer {
        GlobeMetalRenderer(resources: resources)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: resources.device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColor(red: 0.003, green: 0.005, blue: 0.012, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.camera = camera
        context.coordinator.sun = sun
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

        init?(dayURL: URL, nightURL: URL, cloudURL: URL) {
            guard let device = MTLCreateSystemDefaultDevice(),
                  let queue = device.makeCommandQueue() else { return nil }
            do {
                let library = try device.makeLibrary(source: GlobeMetalRenderer.shader, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "globeVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "globeFragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
                let loader = MTKTextureLoader(device: device)
                let options: [MTKTextureLoader.Option: Any] = [
                    .origin: MTKTextureLoader.Origin.topLeft, .SRGB: true
                ]
                self.device = device
                self.queue = queue
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
                day = try loader.newTexture(URL: dayURL, options: options)
                night = try loader.newTexture(URL: nightURL, options: options)
                clouds = try loader.newTexture(URL: cloudURL, options: [
                    .origin: MTKTextureLoader.Origin.topLeft, .SRGB: false
                ])
            } catch {
                NSLog("Menu Calendar globe: %@", String(describing: error))
                return nil
            }
        }
    }

    var camera: GlobeCamera?
    var sun: SolarPosition?
    private let resources: Resources

    private struct Uniforms {
        var front: SIMD4<Float>
        var east: SIMD4<Float>
        var north: SIMD4<Float>
        var sun: SIMD4<Float>
        var viewport: SIMD4<Float>
    }

    init(resources: Resources) {
        self.resources = resources
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let camera, let sun, let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let buffer = resources.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let lat = Float(camera.latitude) * .pi / 180
        let lon = Float(camera.longitude) * .pi / 180
        let solarLat = Float(sun.latitude) * .pi / 180
        let solarLon = Float(sun.longitude) * .pi / 180
        let diameter = Float(2 * GlobeCamera.radius(in: view.drawableSize, zoom: camera.zoom))
        var uniforms = Uniforms(
            front: [cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat), 0],
            east: [-sin(lon), cos(lon), 0, 0],
            north: [-sin(lat) * cos(lon), -sin(lat) * sin(lon), cos(lat), 0],
            sun: [cos(solarLat) * cos(solarLon), cos(solarLat) * sin(solarLon), sin(solarLat), 0],
            viewport: [Float(view.drawableSize.width) / diameter, Float(view.drawableSize.height) / diameter, 0, 0]
        )

        encoder.setRenderPipelineState(resources.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(resources.day, index: 0)
        encoder.setFragmentTexture(resources.night, index: 1)
        encoder.setFragmentTexture(resources.clouds, index: 2)
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
        float4 front, east, north, sun, viewport;
    };

    vertex Vertex globeVertex(uint index [[vertex_id]]) {
        const float2 triangle[] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        return { float4(triangle[index], 0, 1), triangle[index] };
    }

    float2 earthUV(float3 normal) {
        const float pi = 3.14159265359;
        return float2(0.5 + atan2(normal.y, normal.x) / (2.0 * pi),
                      0.5 - asin(clamp(normal.z, -1.0, 1.0)) / pi);
    }

    fragment float4 globeFragment(Vertex input [[stage_in]],
                                  constant Uniforms& globe [[buffer(0)]],
                                  texture2d<float> day [[texture(0)]],
                                  texture2d<float> night [[texture(1)]],
                                  texture2d<float> clouds [[texture(2)]]) {
        constexpr sampler imagery(s_address::repeat, t_address::clamp_to_edge,
                                   min_filter::linear, mag_filter::linear);
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
        float3 terrain = day.sample(imagery, uv, level(0)).rgb;
        float3 lights = night.sample(imagery, uv, level(0)).rgb;
        float daylight = smoothstep(-0.105, 0.055, incidence);
        float twilight = 4.0 * daylight * (1.0 - daylight);
        float irradiance = 0.25 + 0.75 * sqrt(saturate(incidence));

        // Follow the actual light ray up to the cloud shell to cast a separate shadow on the terrain.
        float lightDistance = sqrt(incidence * incidence + cloudRadius * cloudRadius - 1.0) - incidence;
        float3 shadowDirection = normalize(normal + globe.sun.xyz * lightDistance);
        float shadowCover = smoothstep(0.26, 0.90, clouds.sample(imagery, earthUV(shadowDirection), level(0)).r);
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
        float mask = clouds.sample(imagery, earthUV(cloudNormal), level(0)).r;
        float coverage = smoothstep(0.22, 0.88, mask) * (0.64 + air * 0.13);
        float3 cloudColor = mix(float3(0.013, 0.022, 0.046),
                                float3(0.88, 0.94, 1.04) * (0.33 + 0.67 * sqrt(saturate(cloudSun))),
                                cloudLight);
        float edge = 1.0 - smoothstep(cloudRadius - edgeWidth, cloudRadius + edgeWidth, distance);
        return float4(mix(scene, cloudColor, coverage * edge), 1.0);
    }
    """
}
