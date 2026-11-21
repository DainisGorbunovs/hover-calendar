import CoreGraphics
import Foundation
import ImageIO

@MainActor
final class EarthMapRenderer {
    private let day: [UInt8]
    private let night: [UInt8]
    private let width: Int
    private let height: Int
    private let latitudes: [SIMD2<Float>]
    private let longitudes: [SIMD2<Float>]
    private var lastFrame: (date: Date, image: CGImage)?

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let layout = CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )

    init?(dayURL: URL, nightURL: URL) {
        guard let dayImage = Self.loadImage(at: dayURL), let nightImage = Self.loadImage(at: nightURL),
              dayImage.width == dayImage.height * 2,
              nightImage.width == nightImage.height * 2 else { return nil }

        let columns = min(dayImage.width, nightImage.width, 720)
        let rows = columns / 2
        guard let day = Self.pixels(in: dayImage, width: columns, height: rows),
              let night = Self.pixels(in: nightImage, width: columns, height: rows) else { return nil }
        self.day = day
        self.night = night
        width = columns
        height = rows
        latitudes = (0..<rows).map { row in
            let radians = Float.pi * (0.5 - (Float(row) + 0.5) / Float(rows))
            return SIMD2(cos(radians), sin(radians))
        }
        longitudes = (0..<columns).map { column in
            let radians = 2 * Float.pi * ((Float(column) + 0.5) / Float(columns) - 0.5)
            return SIMD2(cos(radians), sin(radians))
        }
    }

    func image(at date: Date, sun: SolarPosition) -> CGImage? {
        if let lastFrame, lastFrame.date == date { return lastFrame.image }

        let latitude = Float(sun.latitude) * .pi / 180
        let longitude = Float(sun.longitude) * .pi / 180
        let sunX = cos(latitude) * cos(longitude)
        let sunY = cos(latitude) * sin(longitude)
        let sunZ = sin(latitude)
        let skyGlow: [Float] = [3, 13, 38]
        let twilightGlow: [Float] = [20, 14, 10]
        var pixels = [UInt8](repeating: 255, count: width * height * 4)

        for (row, latitude) in latitudes.enumerated() {
            let north = latitude.y * sunZ
            for (column, longitude) in longitudes.enumerated() {
                let incidence = latitude.x * (longitude.x * sunX + longitude.y * sunY) + north
                // Blend satellite layers across civil twilight, retaining night lights beyond it.
                let progress = min(max((incidence + 0.105) / 0.17, 0), 1)
                let daylight = progress * progress * (3 - 2 * progress)
                let twilight = 4 * daylight * (1 - daylight)
                let brightness = 0.70 + 0.30 * sqrt(max(0, incidence))
                let index = (row * width + column) * 4

                for channel in 0..<3 {
                    let dayPixel = Float(day[index + channel])
                    let nightPixel = Float(night[index + channel])
                    let lit = dayPixel * brightness + skyGlow[channel] * brightness
                    let dark = nightPixel * 1.10 + dayPixel * 0.07
                    let value = daylight * lit + (1 - daylight) * dark + twilight * twilightGlow[channel]
                    pixels[index + channel] = UInt8(min(value.rounded(), 255))
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: Self.colorSpace, bitmapInfo: Self.layout,
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }

        lastFrame = (date, image)
        return image
    }

    private static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func pixels(in image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let didDraw = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: colorSpace, bitmapInfo: layout.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return didDraw ? pixels : nil
    }
}
