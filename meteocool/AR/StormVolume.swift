//
//  StormVolume.swift
//  meteocool
//
//  One storm's radar volume, as the data service publishes it.
//

import Foundation
import simd

/// A storm's reflectivity and confidence on a regular grid around its core.
///
/// The file is an `.mcvx` volume,
/// the same bytes core raymarches on the 3D map
/// (`src/lib/cellCutaway.ts`): `MCVX`, a little-endian `u32` version (1), a
/// `u32` header length, a JSON header, then `nx * ny * nz` pairs of bytes,
/// `[dBZ, confidence]`, x fastest, then y, then z. Served gzipped with
/// `Content-Encoding: gzip`, so URLSession has usually inflated it already;
/// `decode` accepts either.
///
/// The grid is a 40 x 40 x 16 km box in the box's own azimuthal-equidistant
/// frame: x east, y north, z up from sea level, centred horizontally on the
/// core's peak. Voxel `i` along an axis has its centre at
/// `origin_m + (i + 0.5) * step_m`, so the normalised texture coordinate of a
/// point is exactly `(p - origin_m) / extent`.
struct StormVolume: Sendable {
    struct Header: Decodable, Sendable {
        let code: String
        let referenceTime: String
        /// The core's peak, and the centre of the box.
        let lon: Double
        let lat: Double
        let nx: Int
        let ny: Int
        let nz: Int
        /// Voxel size in metres, x then y then z.
        let stepM: [Double]
        /// The box's lower corner relative to its centre, in metres.
        let originM: [Double]
        /// Reflectivity is `byte / dbzScale + dbzFloor`.
        let dbzFloor: Double
        let dbzScale: Double
        let sites: [String]?
        let coverage: Double?
        let network: String?
        /// 1: drawn but not seen well enough to open; 2: openable.
        let tier: Int?
        let scannedAt: String?
        let oldestScanAt: String?

        enum CodingKeys: String, CodingKey {
            case code, lon, lat, nx, ny, nz, sites, coverage, network, tier
            case referenceTime = "reference_time"
            case stepM = "step_m"
            case originM = "origin_m"
            case dbzFloor = "dbz_floor"
            case dbzScale = "dbz_scale"
            case scannedAt = "scanned_at"
            case oldestScanAt = "oldest_scan_at"
        }
    }

    enum DecodeError: Error, Equatable {
        case notAVolume
        case unknownVersion(UInt32)
        case badHeader
        case wrongSize(got: Int, wanted: Int)
        case corruptGzip
    }

    let header: Header
    /// Interleaved `[dBZ, confidence]` bytes, ready for a `.rg8Unorm` 3D texture.
    let voxels: Data

    /// The box's size in metres.
    let extentM: SIMD3<Double>
    /// The box's lower corner relative to its centre, in metres.
    let originM: SIMD3<Double>
    /// Where the peel stops: the reflectivity only the storm's strongest
    /// voxels reach. Matches core's `coreDbz`.
    let coreDbz: Double
    /// The strongest reflectivity anywhere the radars saw well.
    let maxDbz: Double
    /// The highest voxel centre above 20 dBZ near the core, in metres above
    /// sea level; where a label sits. Nil for a box with no echo there.
    let echoTopM: Double?

    /// Reflectivity below this is drizzle or the fringe of the anvil (core's `DBZ_LOW`).
    static let dbzLow = 20.0
    /// The width of the ramp from transparent to as opaque as it gets (core's `PEEL_BAND`).
    static let peelBand = 14.0
    /// How many voxels the peel leaves standing (core's `PEEL_CORE_VOXELS`).
    static let peelCoreVoxels = 300

    static func decode(_ input: Data) throws -> StormVolume {
        let data = try isGzip(input) ? gunzip(input) : input
        guard data.count >= 12, data.prefix(4) == Data("MCVX".utf8) else { throw DecodeError.notAVolume }
        let version = data.littleEndianUInt32(at: 4)
        guard version == 1 else { throw DecodeError.unknownVersion(version) }
        let headerLength = Int(data.littleEndianUInt32(at: 8))
        guard data.count >= 12 + headerLength else { throw DecodeError.badHeader }
        let headerBytes = data.subdata(in: data.startIndex + 12 ..< data.startIndex + 12 + headerLength)
        guard let header = try? JSONDecoder().decode(Header.self, from: headerBytes),
              header.stepM.count == 3, header.originM.count == 3,
              header.nx > 0, header.ny > 0, header.nz > 0, header.dbzScale > 0 else {
            throw DecodeError.badHeader
        }
        let voxels = data.subdata(in: data.startIndex + 12 + headerLength ..< data.endIndex)
        let wanted = header.nx * header.ny * header.nz * 2
        guard voxels.count == wanted else { throw DecodeError.wrongSize(got: voxels.count, wanted: wanted) }
        return StormVolume(header: header, voxels: voxels)
    }

    private init(header: Header, voxels: Data) {
        self.header = header
        self.voxels = voxels
        extentM = SIMD3(Double(header.nx) * header.stepM[0],
                        Double(header.ny) * header.stepM[1],
                        Double(header.nz) * header.stepM[2])
        originM = SIMD3(header.originM[0], header.originM[1], header.originM[2])

        // One pass for the histogram (core's `coreDbz`), the strongest echo,
        // and the echo top near the centre.
        var counts = [Int](repeating: 0, count: 256)
        var strongest: UInt8 = 0
        var topLevel = -1
        let lowByte = UInt8(clamping: Int(((Self.dbzLow - header.dbzFloor) * header.dbzScale).rounded(.up)))
        // Within 4 km of the core: the box holds its neighbours too, and their
        // tops are not this storm's.
        let radiusX = 4000.0 / header.stepM[0], radiusY = 4000.0 / header.stepM[1]
        let cx = Double(header.nx) / 2, cy = Double(header.ny) / 2
        voxels.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let nx = header.nx, ny = header.ny, nz = header.nz
            for z in 0 ..< nz {
                for y in 0 ..< ny {
                    let dy = (Double(y) + 0.5 - cy) / radiusY
                    let row = (z * ny + y) * nx
                    for x in 0 ..< nx {
                        let i = (row + x) * 2
                        let dbz = bytes[i], confidence = bytes[i + 1]
                        guard confidence >= 128 else { continue }
                        counts[Int(dbz)] += 1
                        if dbz > strongest { strongest = dbz }
                        if dbz >= lowByte, z > topLevel {
                            let dx = (Double(x) + 0.5 - cx) / radiusX
                            if dx * dx + dy * dy <= 1 { topLevel = z }
                        }
                    }
                }
            }
        }
        var remaining = Self.peelCoreVoxels
        var byte = 255
        while byte > 0 {
            remaining -= counts[byte]
            if remaining <= 0 { break }
            byte -= 1
        }
        coreDbz = max(Self.dbzLow, Double(byte) / header.dbzScale + header.dbzFloor - Self.peelBand)
        maxDbz = Double(strongest) / header.dbzScale + header.dbzFloor
        echoTopM = topLevel >= 0 ? header.originM[2] + (Double(topLevel) + 1) * header.stepM[2] : nil
    }

    /// Reflectivity and confidence of the voxel containing a normalised point,
    /// or nil outside the box.
    func sample(_ p: SIMD3<Float>) -> (dbz: Float, confidence: Float)? {
        guard all(p .>= SIMD3<Float>(repeating: 0)), all(p .< SIMD3<Float>(repeating: 1)) else { return nil }
        let x = Int(p.x * Float(header.nx)), y = Int(p.y * Float(header.ny)), z = Int(p.z * Float(header.nz))
        let i = ((z * header.ny + y) * header.nx + x) * 2
        let dbz = voxels[voxels.startIndex + i], confidence = voxels[voxels.startIndex + i + 1]
        return (Float(dbz) / Float(header.dbzScale) + Float(header.dbzFloor), Float(confidence) / 255)
    }

    /// The ray parameter of the first point that the shader would draw as
    /// storm, or nil.
    ///
    /// The ray is in normalised box coordinates, `origin + t * direction`. The
    /// threshold is the same smooth step the shader uses, at a density where
    /// the cloud is plainly visible, so a tap lands on what the reader sees.
    func firstHit(origin: SIMD3<Float>, direction: SIMD3<Float>, low: Float, within limit: Float = .infinity) -> Float? {
        guard let (near, far) = Self.intersectUnitCube(origin: origin, direction: direction) else { return nil }
        let end = min(far, limit)
        guard end > near else { return nil }
        // Half a voxel along the finest axis, in this ray's own parameter.
        let voxel = SIMD3<Float>(1 / Float(header.nx), 1 / Float(header.ny), 1 / Float(header.nz))
        let perStep = length(direction / voxel)
        let dt = perStep > 0 ? 0.5 / perStep : (end - near)
        var t = near
        while t < end {
            if let (dbz, confidence) = sample(origin + direction * t),
               confidence > 0.3, dbz >= low + Float(Self.peelBand) * 0.35 {
                return t
            }
            t += dt
        }
        return nil
    }

    /// Where a ray enters and leaves the unit cube, entry clamped to zero.
    static func intersectUnitCube(origin: SIMD3<Float>, direction: SIMD3<Float>) -> (Float, Float)? {
        let inverse = SIMD3<Float>(1, 1, 1) / direction
        let a = (SIMD3<Float>(0, 0, 0) - origin) * inverse
        let b = (SIMD3<Float>(1, 1, 1) - origin) * inverse
        let low = simd_min(a, b), high = simd_max(a, b)
        let near = max(max(low.x, low.y), max(low.z, 0))
        let far = min(min(high.x, high.y), high.z)
        return far > near ? (near, far) : nil
    }

    // MARK: Gzip

    private static func isGzip(_ data: Data) -> Bool {
        data.count > 18 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// Inflates a gzip member (RFC 1952) with the system's raw DEFLATE decoder.
    ///
    /// URLSession inflates `Content-Encoding: gzip` itself; this is for a
    /// fixture on disk or a proxy that strips the header but not the encoding.
    private static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes[2] == 8 else { throw DecodeError.corruptGzip }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { throw DecodeError.corruptGzip }
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        if flags & 0x08 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x10 != 0 { while index < bytes.count, bytes[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x02 != 0 { index += 2 }
        guard index < bytes.count - 8 else { throw DecodeError.corruptGzip }
        let deflated = Data(bytes[index ..< bytes.count - 8])
        guard let inflated = try? (deflated as NSData).decompressed(using: .zlib) as Data else {
            throw DecodeError.corruptGzip
        }
        return inflated
    }
}

private extension Data {
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}

/// The radar map's palettes, looked up the way core's `dbz2color` does.
enum Colormaps {
    /// The palettes the settings offer, plus viridis, which core still has.
    static let names = ["classic", "nws", "viridis", "pyart_stepseq", "homeyer", "lang"]

    /// RGB, 0-255, of a reflectivity in a palette; black below the palette's
    /// first entry (core paints those transparent; a volume never draws them,
    /// because its density is zero there). Unknown names fall back to classic,
    /// as core's `cmapFromString` does.
    static func colour(dbz: Double, palette: String) -> SIMD3<UInt8> {
        let table = ColormapTables.tables[palette] ?? ColormapTables.tables["classic"]!
        let index = Int(((dbz + 32.5) * 2).rounded(.toNearestOrAwayFromZero))
        guard index >= table.leftPad else { return SIMD3(0, 0, 0) }
        let packed = table.rgba[min(index - table.leftPad, table.rgba.count - 1)]
        return SIMD3(UInt8(packed >> 24), UInt8((packed >> 16) & 0xFF), UInt8((packed >> 8) & 0xFF))
    }

    /// The 256-entry ramp the shader samples: -32 to +64 dBZ, the range the
    /// stored byte covers, as core's `rampTexture` builds it. RGBA8, opaque.
    static func ramp(palette: String) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: 256 * 4)
        for i in 0 ..< 256 {
            let rgb = colour(dbz: -32 + Double(i) / 255 * 96, palette: palette)
            pixels[i * 4] = rgb.x
            pixels[i * 4 + 1] = rgb.y
            pixels[i * 4 + 2] = rgb.z
        }
        return pixels
    }
}
