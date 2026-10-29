//
//  RadarPixels.swift
//  meteocool
//
//  Radar tiles from raw values to colour: core's `lib/valuePng.ts` and
//  `lib/rvp6.ts`.
//

import Foundation
import CoreGraphics

/// Reads the radar's value tiles: single-band 8-bit PNGs whose bytes are
/// reflectivity (RVP6, `byte = (dBZ + 32.5) * 2`, 0 = nothing).
///
/// The PNG is inflated and unfiltered here instead of through ImageIO: the
/// bytes are values, not colours, and a colour-managed decoder may hand back
/// some of them off by one, as WebKit did on iOS 18.4 (core's
/// `lib/valuePng.ts`). Grey and palette-free only, the format the tile
/// renderer writes.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum GreyPNG {
    struct Image: Sendable {
        let width: Int
        let height: Int
        /// One byte per pixel, row major.
        let pixels: [UInt8]
    }

    static func decode(_ data: Data) -> Image? {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count > 8, Array(bytes[0 ..< 8]) == signature else { return nil }
        var width = 0, height = 0
        var idat = Data()
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = Int(UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                             | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3]))
            let type = String(decoding: bytes[offset + 4 ..< offset + 8], as: UTF8.self)
            let start = offset + 8
            guard start + length + 4 <= bytes.count else { return nil }
            switch type {
            case "IHDR":
                guard length == 13 else { return nil }
                func be32(_ at: Int) -> Int {
                    Int(UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3]))
                }
                width = be32(start)
                height = be32(start + 4)
                // 8-bit, greyscale, deflate, adaptive filtering, not interlaced.
                guard bytes[start + 8] == 8, bytes[start + 9] == 0, bytes[start + 10] == 0,
                      bytes[start + 11] == 0, bytes[start + 12] == 0 else { return nil }
            case "IDAT":
                idat.append(contentsOf: bytes[start ..< start + length])
            case "IEND":
                offset = bytes.count
                continue
            default:
                break
            }
            offset = start + length + 4
        }
        guard width > 0, height > 0, width <= 4096, height <= 4096, idat.count > 2 else { return nil }
        // A zlib stream: two header bytes, then raw deflate, which is what
        // Foundation's `.zlib` inflates.
        guard let inflated = try? (idat.dropFirst(2) as NSData).decompressed(using: .zlib) as Data else { return nil }
        let stride = width + 1
        guard inflated.count >= stride * height else { return nil }
        return unfilter([UInt8](inflated), width: width, height: height).map { Image(width: width, height: height, pixels: $0) }
    }

    /// Undoes the PNG row filters for one byte per pixel.
    private static func unfilter(_ raw: [UInt8], width: Int, height: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: width * height)
        let stride = width + 1
        for row in 0 ..< height {
            let filter = raw[row * stride]
            let src = row * stride + 1
            let dst = row * width
            for x in 0 ..< width {
                let value = raw[src + x]
                let a = x > 0 ? Int(out[dst + x - 1]) : 0
                let b = row > 0 ? Int(out[dst - width + x]) : 0
                let c = x > 0 && row > 0 ? Int(out[dst - width + x - 1]) : 0
                let predictor: Int
                switch filter {
                case 0: predictor = 0
                case 1: predictor = a
                case 2: predictor = b
                case 3: predictor = (a + b) / 2
                case 4:
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    predictor = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
                default: return nil
                }
                out[dst + x] = UInt8(truncatingIfNeeded: Int(value) + predictor)
            }
        }
        return out
    }
}

/// A palette as a 256-entry lookup from a tile's byte to a premultiplied
/// RGBA pixel (core's `cmap_utils.ts`): 0 and everything below the table's
/// `leftPad` transparent, everything past its end the last colour.
struct RadarLUT: Sendable, Equatable {
    /// What the composites are drawn in under an open radar's own sweep
    /// (core's `Ink`): grey, so their colours do not mix with the sweep's.
    /// Black ink on a light map, white on a dark one.
    enum Ink: String, Sendable {
        case black, white
    }

    let name: String
    let ink: Ink?
    /// R, G, B, A in memory order (little-endian `UInt32`).
    let entries: [UInt32]

    /// The palette and its ink, as caches key it.
    var id: String { ink.map { "\(name)~\($0.rawValue)" } ?? name }

    /// The dBZ the grey runs between, from its faintest to full ink (`GREY_FROM_DBZ`, `GREY_TO_DBZ`).
    static let greyFromDbz = 5.0
    static let greyToDbz = 50.0

    init(palette: String, ink: Ink? = nil) {
        let table = ColormapTables.tables[palette] ?? ColormapTables.tables["classic"]!
        name = ColormapTables.tables[palette] == nil ? "classic" : palette
        self.ink = ink
        var entries = [UInt32](repeating: 0, count: 256)
        for value in 1 ..< 256 where value >= table.leftPad && !table.rgba.isEmpty {
            let packed = table.rgba[min(value - table.leftPad, table.rgba.count - 1)]
            let a = packed & 0xFF
            var r = packed >> 24, g = (packed >> 16) & 0xFF, b = (packed >> 8) & 0xFF
            if let ink {
                // Grey running with dBZ, each class's alpha kept (core's `greyTable`).
                let t = min(1, max(0, (Double(value) / 2 - 32.5 - Self.greyFromDbz) / (Self.greyToDbz - Self.greyFromDbz)))
                let (faint, full) = ink == .black ? (160.0, 0.0) : (120.0, 255.0)
                let grey = UInt32((faint + (full - faint) * t).rounded())
                (r, g, b) = (grey, grey, grey)
            }
            entries[value] = r * a / 255 | (g * a / 255) << 8 | (b * a / 255) << 16 | a << 24
        }
        self.entries = entries
    }

    /// The tile in colour, nil for one with nothing to draw.
    func colour(_ image: GreyPNG.Image) -> CGImage? {
        guard image.pixels.contains(where: { $0 != 0 }) else { return nil }
        var rgba = [UInt32](repeating: 0, count: image.pixels.count)
        entries.withUnsafeBufferPointer { lut in
            image.pixels.withUnsafeBufferPointer { src in
                rgba.withUnsafeMutableBufferPointer { dst in
                    for i in 0 ..< src.count { dst[i] = lut[Int(src[i])] }
                }
            }
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
