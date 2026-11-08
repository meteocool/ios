import Foundation

/// Lossless CDN optimization may store grayscale values through a PNG palette.
@main struct RadarPixelsCheck {
    static func main() throws {
        let file = "tests/fixtures/radar/polished-grey.png"
        let png = try Data(contentsOf: URL(fileURLWithPath: file))
        guard let image = GreyPNG.decode(png) else { fatalError("Lossless grayscale palette PNG must decode") }
        precondition(image.width == 512 && image.height == 512)
        precondition(image.pixels.max() == 139)
        precondition(Set(image.pixels).count == 83)
        // The optimized PNG's first palette index is 0, but its value is 138.
        // Check against the exact bytes before Cloudflare's lossless transform.
        let original = try Data(contentsOf: URL(fileURLWithPath: "tests/fixtures/radar/original-grey.png"))
        precondition(GreyPNG.decode(original)?.pixels == image.pixels, "Palette indices must expand to raw RVP6 values")
        let packed = try Data(contentsOf: URL(fileURLWithPath: "tests/fixtures/radar/polished-grey-4.png"))
        let packedOriginal = try Data(contentsOf: URL(fileURLWithPath: "tests/fixtures/radar/original-grey-4.png"))
        guard let packedImage = GreyPNG.decode(packed) else { fatalError("4-bit grayscale palette PNG must decode") }
        precondition(packedImage.pixels == GreyPNG.decode(packedOriginal)?.pixels, "Packed grayscale values must stay exact")
        for depth in [1, 2, 4, 8] {
            let mask = (1 << depth) - 1
            let palette = (0...mask).map { UInt8($0) }
            let indices = [mask, 0, 1, 0, 1, mask]
            let gray = Self.png(depth: depth, palette: [], indices: indices, color: 0)
            precondition(GreyPNG.decode(gray)?.pixels == indices.map { UInt8($0 * 255 / mask) }, "Packed grayscale samples must preserve byte values")
            let sample = Self.png(depth: depth, palette: palette, indices: indices)
            precondition(GreyPNG.decode(sample)?.pixels == indices.map { palette[$0] }, "Packed pixels and row padding must decode at depth \(depth)")
        }
        var colored = png
        let palette = png.range(of: Data("PLTE".utf8))!.upperBound
        colored[palette + 1] ^= 1
        precondition(GreyPNG.decode(colored) == nil, "Colored palettes are not radar value PNGs")
        var missing = png
        missing[palette - 4] = UInt8(ascii: "x")
        precondition(GreyPNG.decode(missing) == nil, "Indexed pixels need their palette")
        print("RadarPixelsCheck: grayscale CDN palette preserves all raw values")
    }
    private static func png(depth: Int, palette: [UInt8], indices: [Int], color: UInt8 = 3) -> Data {
        let width = 3, height = 2, rowBytes = (width * depth + 7) / 8
        var raw = [UInt8](repeating: 0, count: (rowBytes + 1) * height)
        for y in 0..<height { for x in 0..<width {
            raw[y * (rowBytes + 1) + 1 + x * depth / 8] |= UInt8(indices[y * width + x] << (8 - depth - x * depth % 8))
        }}
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let n = body.count
            return [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)]
                + Array(type.utf8) + body + [0, 0, 0, 0]
        }
        let compressed = try! (Data(raw) as NSData).compressed(using: .zlib) as Data
        var png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        png += chunk("IHDR", [0, 0, 0, 3, 0, 0, 0, 2, UInt8(depth), color, 0, 0, 0])
        if color == 3 { png += chunk("PLTE", palette.flatMap { [$0, $0, $0] }) }
        png += chunk("IDAT", [0x78, 0x9C] + compressed + [0, 0, 0, 0])
        png += chunk("IEND", [])
        return Data(png)
    }

}
