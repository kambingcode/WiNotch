import CoreGraphics

/// Picks the colours for the glow behind the album cover.
enum ArtworkPalette {
    struct Color: Equatable, Sendable {
        var red: CGFloat
        var green: CGFloat
        var blue: CGFloat

        static let white = Color(red: 1, green: 1, blue: 1)
    }

    private static let sampleSize = 32
    private static let hueBins = 24
    private static let maximumColors = 3
    /// Hues closer than this look like one colour in a glow.
    private static let minimumBinGap = 2
    /// Below this share of coloured pixels the cover counts as black and white.
    private static let minimumColoredShare = 0.08
    /// The strongest colour must reach this saturation, or it looks dull.
    private static let minimumLivelySaturation: CGFloat = 0.3
    /// A small accent of an opposite hue turns the blended glow muddy, so a
    /// colour must carry this share of the strongest one's weight.
    private static let minimumShareOfStrongest: CGFloat = 0.4
    private static let neighbourHueShift: CGFloat = 0.07

    /// The cover's liveliest colours, strongest first. A cover without any
    /// gets white, which glows quietly instead of tinting it wrongly.
    static func colors(from image: CGImage) -> [Color] {
        guard let pixels = samplePixels(of: image) else { return [.white] }
        return colors(fromPixels: pixels)
    }

    /// One colour alone is a plain glow, so it gains two close neighbours to
    /// make a gradient. They stay near its hue, which keeps the blend clean.
    static func glowColors(from colors: [Color]) -> [Color] {
        guard colors.count == 1, let base = colors.first, base != .white else { return colors }
        let (hue, saturation, brightness) = hsb(base.red, base.green, base.blue)
        func neighbour(_ shift: CGFloat) -> Color {
            let shifted = (hue + shift + 1).truncatingRemainder(dividingBy: 1)
            return color(hue: shifted, saturation: saturation, brightness: brightness)
        }
        return [base, neighbour(neighbourHueShift), neighbour(-neighbourHueShift)]
    }

    private struct Bin {
        var weight: CGFloat = 0
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
    }

    static func colors(fromPixels pixels: [(red: CGFloat, green: CGFloat, blue: CGFloat)]) -> [Color] {
        var bins = [Bin](repeating: Bin(), count: hueBins)
        var colored = 0
        for pixel in pixels {
            let (hue, saturation, brightness) = hsb(pixel.red, pixel.green, pixel.blue)
            guard saturation >= 0.25, brightness >= 0.2 else { continue }
            colored += 1
            let weight = saturation * brightness * skinPenalty(hue: hue, saturation: saturation)
            let index = min(hueBins - 1, Int(hue * CGFloat(hueBins)))
            bins[index].weight += weight
            bins[index].hue += hue * weight
            bins[index].saturation += saturation * weight
            bins[index].brightness += brightness * weight
        }
        guard !pixels.isEmpty, Double(colored) / Double(pixels.count) >= minimumColoredShare else { return [.white] }

        var chosen: [Int] = []
        for index in bins.indices.sorted(by: { bins[$0].weight > bins[$1].weight }) {
            guard bins[index].weight > 0, chosen.count < maximumColors else { break }
            let isLively = bins[index].saturation / bins[index].weight >= minimumLivelySaturation
            let isDistinct = chosen.allSatisfy { circularDistance($0, index) >= minimumBinGap }
            let isStrong = chosen.first.map { bins[index].weight >= bins[$0].weight * minimumShareOfStrongest } ?? true
            if isLively, isDistinct, isStrong { chosen.append(index) }
        }
        guard !chosen.isEmpty else { return [.white] }
        return chosen.map { index in
            let bin = bins[index]
            return color(
                hue: bin.hue / bin.weight,
                saturation: min(max(bin.saturation / bin.weight, 0.5), 0.85),
                brightness: max(bin.brightness / bin.weight, 0.75)
            )
        }
    }

    /// Faces fill many photo covers and turn into a dull salmon.
    private static func skinPenalty(hue: CGFloat, saturation: CGFloat) -> CGFloat {
        (0.02...0.12).contains(hue) && saturation < 0.6 ? 0.2 : 1
    }

    private static func circularDistance(_ first: Int, _ second: Int) -> Int {
        let distance = abs(first - second)
        return min(distance, hueBins - distance)
    }

    private static func samplePixels(of image: CGImage) -> [(red: CGFloat, green: CGFloat, blue: CGFloat)]? {
        let size = sampleSize
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }
        var pixels: [(red: CGFloat, green: CGFloat, blue: CGFloat)] = []
        pixels.reserveCapacity(size * size)
        for start in stride(from: 0, to: bytes.count, by: 4) {
            let red = CGFloat(bytes[start]) / 255
            let green = CGFloat(bytes[start + 1]) / 255
            let blue = CGFloat(bytes[start + 2]) / 255
            pixels.append((red, green, blue))
        }
        return pixels
    }

    private static func hsb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let highest = max(red, green, blue)
        let spread = highest - min(red, green, blue)
        guard highest > 0, spread > 0 else { return (0, 0, highest) }
        var hue: CGFloat
        if highest == red {
            hue = (green - blue) / spread
        } else if highest == green {
            hue = 2 + (blue - red) / spread
        } else {
            hue = 4 + (red - green) / spread
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, spread / highest, highest)
    }

    private static func color(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) -> Color {
        let sector = hue * 6
        let whole = Int(sector) % 6
        let fraction = sector - CGFloat(Int(sector))
        let low = brightness * (1 - saturation)
        let falling = brightness * (1 - saturation * fraction)
        let rising = brightness * (1 - saturation * (1 - fraction))
        switch whole {
        case 0: return Color(red: brightness, green: rising, blue: low)
        case 1: return Color(red: falling, green: brightness, blue: low)
        case 2: return Color(red: low, green: brightness, blue: rising)
        case 3: return Color(red: low, green: falling, blue: brightness)
        case 4: return Color(red: rising, green: low, blue: brightness)
        default: return Color(red: brightness, green: low, blue: falling)
        }
    }
}
