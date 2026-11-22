import Foundation
import Metal
import simd

/// The wind across a weather region at one moment, for carrying particles.
struct WindField {
    /// East and north components in km/h, row by row from the north-west corner.
    let vectors: [SIMD2<Float>]
    let side: Int
    /// The region's size on the ground in km, west to east and north to south,
    /// so a particle crosses it at the same speed whichever way the wind blows.
    let extent: SIMD2<Float>

    init?(region: WeatherRegion, earlier: WeatherFrame, later: WeatherFrame, progress: Double) {
        let side = WeatherRegion.side
        guard side >= 2, earlier.samples.count == side * side, later.samples.count == side * side
        else { return nil }
        let blend = Float(progress)
        vectors = zip(earlier.samples, later.samples).map { start, end in
            let a = SIMD2(Float(start.east), Float(start.north))
            let b = SIMD2(Float(end.east), Float(end.north))
            return a + (b - a) * blend
        }
        self.side = side
        let kilometresPerDegree: Float = 111.32
        extent = SIMD2(Float(region.longitudeSpan) * kilometresPerDegree
                         * Float(cos(region.latitude * .pi / 180)),
                       Float(region.latitudeSpan) * kilometresPerDegree)
    }

    /// Bilinear across the grid, matching how the globe samples the same
    /// readings on the GPU: 0 and 1 sit on the first and last samples.
    func velocity(at position: SIMD2<Float>) -> SIMD2<Float> {
        let last = Float(side - 1)
        let x = min(max(position.x, 0), 1) * last
        let y = min(max(position.y, 0), 1) * last
        let column = min(Int(x), side - 2)
        let row = min(Int(y), side - 2)
        let across = x - Float(column)
        let down = y - Float(row)
        func at(_ c: Int, _ r: Int) -> SIMD2<Float> { vectors[r * side + c] }
        let north = at(column, row) * (1 - across) + at(column + 1, row) * across
        let south = at(column, row + 1) * (1 - across) + at(column + 1, row + 1) * across
        return north * (1 - down) + south * down
    }
}

/// Particles carried by the wind, each leaving a fading trail, the way
/// Apple's wind layer draws its flow.
///
/// Every step fades the previous trail and draws each particle's latest move
/// on top, ping-ponging between two textures. The trails live in the weather
/// region's own coordinates rather than on screen, so the globe samples them
/// just as it samples the readings, and orbiting or zooming never smears them.
final class WindParticles {
    static let count = 3200
    static let trailWidth = 640
    static let trailHeight = 512
    /// How many hours of real travel a particle covers each second. Real air is
    /// far too slow to watch; this carries a moderate breeze across the region
    /// in a few seconds while calm air still barely moves.
    static let hoursPerSecond: Float = 3.4
    /// How much of a trail survives each thirtieth of a second.
    static let survivalPerFrame: Float = 0.92
    private static let framesInFlight = 3

    private let queue: MTLCommandQueue
    private let fadePipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private var front: MTLTexture
    private var back: MTLTexture
    private let segments: [MTLBuffer]
    private var slot = 0
    private let available = DispatchSemaphore(value: framesInFlight)

    private var positions: [SIMD2<Float>]
    private var previous: [SIMD2<Float>]
    private var ages: [Float]
    private var lifetimes: [Float]

    /// The trails as of the latest step, for the globe to sample.
    var trail: MTLTexture { front }

    init?(resources: GlobeMetalRenderer.Resources) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: Self.trailWidth, height: Self.trailHeight, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let length = Self.count * 2 * MemoryLayout<SIMD2<Float>>.stride
        guard let front = resources.device.makeTexture(descriptor: descriptor),
              let back = resources.device.makeTexture(descriptor: descriptor)
        else { return nil }
        let segments = (0..<Self.framesInFlight).compactMap { _ in
            resources.device.makeBuffer(length: length, options: .storageModeShared)
        }
        guard segments.count == Self.framesInFlight else { return nil }

        queue = resources.queue
        fadePipeline = resources.trailFadePipeline
        particlePipeline = resources.particlePipeline
        self.front = front
        self.back = back
        self.segments = segments
        positions = Array(repeating: .zero, count: Self.count)
        previous = positions
        ages = Array(repeating: 0, count: Self.count)
        lifetimes = ages
        reset()
    }

    /// Clears the trails and scatters the particles afresh, with their ages
    /// staggered so they do not all expire on the same frame.
    func reset() {
        for index in 0..<Self.count {
            positions[index] = Self.randomPoint()
            previous[index] = positions[index]
            lifetimes[index] = Self.randomLifetime()
            ages[index] = Float.random(in: 0..<lifetimes[index])
        }
        guard let buffer = queue.makeCommandBuffer() else { return }
        for texture in [front, back] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        buffer.commit()
    }

    /// Starts over and runs a second and a half of steps at once, so trails
    /// are already drawn when the layer appears, and so a still picture is
    /// left behind when motion is reduced.
    func warmUp(through wind: WindField, steps: Int = 45) {
        reset()
        for _ in 0..<steps {
            guard let buffer = queue.makeCommandBuffer() else { return }
            step(through: wind, seconds: 1 / 30, into: buffer)
            buffer.commit()
        }
    }

    /// Carries every particle through the wind for `seconds`, then fades the
    /// old trails and draws each particle's latest move into `buffer`, which
    /// the caller commits.
    func step(through wind: WindField, seconds: Float, into buffer: MTLCommandBuffer) {
        let elapsed = min(max(seconds, 0), 0.1)
        let travel = Self.hoursPerSecond * elapsed
        let extent = SIMD2(max(wind.extent.x, 1), max(wind.extent.y, 1))

        for index in 0..<Self.count {
            previous[index] = positions[index]
            ages[index] += elapsed
            let velocity = wind.velocity(at: positions[index])
            // Region coordinates run south, so a northward wind moves up.
            var next = positions[index] + SIMD2(velocity.x / extent.x, -velocity.y / extent.y) * travel
            let outside = next.x < 0 || next.x > 1 || next.y < 0 || next.y > 1
            if outside || ages[index] > lifetimes[index] {
                next = Self.randomPoint()
                previous[index] = next
                ages[index] = 0
                lifetimes[index] = Self.randomLifetime()
            }
            positions[index] = next
        }

        // Never overwrite a segment buffer the GPU may still be reading.
        available.wait()
        let segmentBuffer = segments[slot]
        slot = (slot + 1) % Self.framesInFlight
        buffer.addCompletedHandler { [available] _ in available.signal() }

        let points = segmentBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: Self.count * 2)
        for index in 0..<Self.count {
            points[2 * index] = previous[index]
            points[2 * index + 1] = positions[index]
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = back
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var survival = pow(Self.survivalPerFrame, elapsed * 30)
        encoder.setRenderPipelineState(fadePipeline)
        encoder.setFragmentTexture(front, index: 0)
        encoder.setFragmentBytes(&survival, length: MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.setRenderPipelineState(particlePipeline)
        encoder.setVertexBuffer(segmentBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: Self.count * 2)
        encoder.endEncoding()
        swap(&front, &back)
    }

    private static func randomPoint() -> SIMD2<Float> {
        SIMD2(Float.random(in: 0...1), Float.random(in: 0...1))
    }

    private static func randomLifetime() -> Float {
        Float.random(in: 1.2...2.8)
    }
}
