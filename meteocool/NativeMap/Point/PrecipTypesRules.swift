//
//  PrecipTypesRules.swift
//  meteocool
//
//  The precipitation-types map's rules: DWD's HG classes as bytes and
//  colours, its legend, and how fresh its picture is (core's
//  `caps/PrecipitationTypesCapability.ts`, `lib/hgClasses.ts`,
//  `components/LastUpdated.svelte`).
//
//  No app dependencies here: `scripts/check.sh` compiles this file alone.
//

import CoreGraphics
import Foundation

enum PrecipTypes {
    /// `values.encoding` of a frame whose tiles hold class bytes.
    static let encoding = "hg-class-u8"
    /// The class layer's opacity (core's `NOWCAST_OPACITY`).
    static let opacity = 0.75
    /// Its tiles' zooms; drawn larger past the last.
    static let minZoom = 3
    static let maxZoom = 8

    /// Each class's colour by its byte (core's `HG_CLASS_COLOURS`), RGB;
    /// 0 and every byte past 7 draw nothing.
    static let classColors: [UInt32] = [
        0x000000, // 0 nothing (transparent)
        0x787878, // 1 not classifiable
        0x87CFEB, // 2 drizzle
        0x0000FF, // 3 rain
        0xFFFF00, // 4 snow
        0x00FF00, // 5 sleet
        0xFF9900, // 6 graupel
        0xFF0000, // 7 hail
    ]

    /// A tile's byte to a premultiplied RGBA pixel (R, G, B, A in memory
    /// order), opaque for every class and clear for anything else.
    static let lut: [UInt32] = (0 ..< 256).map { byte in
        guard byte >= 1, byte < classColors.count else { return 0 }
        let rgb = classColors[byte]
        return (rgb >> 16) & 0xFF | ((rgb >> 8) & 0xFF) << 8 | (rgb & 0xFF) << 16 | 0xFF << 24
    }

    /// A class tile in colour, nil for one with nothing in it; unsmoothed.
    static func colour(width: Int, height: Int, pixels: [UInt8]) -> CGImage? {
        guard pixels.count == width * height, pixels.contains(where: { $0 != 0 && Int($0) < classColors.count }) else { return nil }
        var rgba = [UInt32](repeating: 0, count: pixels.count)
        lut.withUnsafeBufferPointer { table in
            pixels.withUnsafeBufferPointer { src in
                rgba.withUnsafeMutableBufferPointer { dst in
                    for i in 0 ..< src.count { dst[i] = table[Int(src[i])] }
                }
            }
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// The legend, left to right: core's key (also its label's key) and
    /// colour (`colormaps.ts` `precipTypeNames`).
    static let legend: [(key: String, rgb: UInt32)] = [
        ("hail", 0xFF0000), ("graupel", 0xFF9900), ("sleet", 0x00FF00), ("snow", 0xFFFF00),
        ("rain", 0x0000FF), ("drizzle", 0x87CFEB), ("n/a", 0x787878),
    ]

    /// Segment `k` of `count` hard stops, in percent (`StepScaleLine.svelte`).
    static func segment(_ k: Int, of count: Int) -> ClosedRange<Double> {
        (Double(k) * 100 / Double(count)).rounded() ... (Double(k + 1) * 100 / Double(count)).rounded()
    }

    /// `GET /v3/radar/classification` (404: nothing rendered yet).
    struct Frame: Decodable, Equatable, Sendable {
        struct Values: Decodable, Equatable, Sendable {
            let tileId: String
            let encoding: String?
        }
        let tileId: String
        let upstreamTime: Int?
        let processedTime: Int
        let values: Values?

        /// The tiles' id: the value tiles' where there are any.
        var tilesId: String { values?.tileId ?? tileId }
        /// Whether its tiles hold class bytes, rather than legacy colours.
        var classBytes: Bool { values?.encoding == PrecipTypes.encoding || (values != nil && values?.encoding == nil) }

        static func decode(_ data: Data) -> Frame? {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try? decoder.decode(Frame.self, from: data)
        }
    }

    /// `{tiles}/meteoradar/{id}/{z}/{x}/{-y}.png`: TMS rows.
    static func tilePath(_ tilesId: String, z: Int, x: Int, y: Int) -> String {
        "meteoradar/\(tilesId)/\(z)/\(x)/\((1 << z) - 1 - y).png"
    }

    /// The "last updated" ring, full when fresh and empty after five minutes.
    static func freshness(age: TimeInterval) -> Double {
        100 - min(abs(age) / 300 * 100, 100)
    }

    /// "Last updated " before the age when it is short enough to carry it.
    static func lastUpdated(_ relative: String, prefix: String) -> String {
        relative.count < 22 ? "\(prefix) \(relative)" : relative
    }
}
