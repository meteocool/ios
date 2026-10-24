//
//  VectorTile.swift
//  meteocool
//
//  Mapbox vector tiles (MVT 2.1), as core's snow overlay and lightning map
//  serve them.
//

import Foundation
import CoreGraphics

/// A decoded Mapbox vector tile: layers of features with their geometry in
/// tile coordinates (0…extent, y down) and their properties.
///
/// Only what the map draws: no encoder, no validation beyond what decoding
/// needs. No app dependencies here: `scripts/check.sh` compiles this file alone.
struct VectorTile {
    enum Value: Equatable, Sendable {
        case string(String)
        case double(Double)
        case int(Int64)
        case bool(Bool)

        var number: Double? {
            switch self {
            case .double(let v): return v
            case .int(let v): return Double(v)
            case .bool(let v): return v ? 1 : 0
            case .string(let v): return Double(v)
            }
        }
    }

    enum GeometryType: Int, Sendable {
        case unknown = 0, point, lineString, polygon
    }

    struct Feature: Sendable {
        var id: UInt64?
        var type: GeometryType = .unknown
        var properties: [String: Value] = [:]
        /// Points: one part per point group; lines: one part per line;
        /// polygons: one part per ring.
        var parts: [[CGPoint]] = []
    }

    struct Layer: Sendable {
        var name = ""
        var extent = 4096
        var features: [Feature] = []
    }

    enum DecodeError: Error { case truncated, malformed }

    let layers: [Layer]

    func layer(_ name: String) -> Layer? { layers.first { $0.name == name } }

    init(data: Data) throws {
        var reader = Reader(buffer: [UInt8](data))
        var layers: [Layer] = []
        while !reader.atEnd {
            let (field, wire) = try reader.key()
            if field == 3, wire == 2 {
                layers.append(try Self.layer(try reader.delimited()))
            } else {
                try reader.skip(wire)
            }
        }
        self.layers = layers
    }

    private static func layer(_ bytes: ArraySlice<UInt8>) throws -> Layer {
        var reader = Reader(buffer: Array(bytes))
        var layer = Layer()
        var keys: [String] = []
        var values: [Value] = []
        var rawFeatures: [ArraySlice<UInt8>] = []
        while !reader.atEnd {
            let (field, wire) = try reader.key()
            switch (field, wire) {
            case (1, 2): layer.name = String(decoding: try reader.delimited(), as: UTF8.self)
            case (2, 2): rawFeatures.append(try reader.delimited())
            case (3, 2): keys.append(String(decoding: try reader.delimited(), as: UTF8.self))
            case (4, 2): values.append(try value(try reader.delimited()))
            case (5, 0): layer.extent = Int(try reader.varint())
            default: try reader.skip(wire)
            }
        }
        layer.features = try rawFeatures.map { try feature($0, keys: keys, values: values) }
        return layer
    }

    private static func value(_ bytes: ArraySlice<UInt8>) throws -> Value {
        var reader = Reader(buffer: Array(bytes))
        var value = Value.int(0)
        while !reader.atEnd {
            let (field, wire) = try reader.key()
            switch (field, wire) {
            case (1, 2): value = .string(String(decoding: try reader.delimited(), as: UTF8.self))
            case (2, 5): value = .double(Double(Float(bitPattern: try reader.fixed32())))
            case (3, 1): value = .double(Double(bitPattern: try reader.fixed64()))
            case (4, 0): value = .int(Int64(bitPattern: try reader.varint()))
            case (5, 0): value = .int(Int64(bitPattern: try reader.varint()))
            case (6, 0): value = .int(Reader.zigzag(try reader.varint()))
            case (7, 0): value = .bool(try reader.varint() != 0)
            default: try reader.skip(wire)
            }
        }
        return value
    }

    private static func feature(_ bytes: ArraySlice<UInt8>, keys: [String], values: [Value]) throws -> Feature {
        var reader = Reader(buffer: Array(bytes))
        var feature = Feature()
        var geometry: [UInt32] = []
        while !reader.atEnd {
            let (field, wire) = try reader.key()
            switch (field, wire) {
            case (1, 0): feature.id = try reader.varint()
            case (2, 2):
                let tags = try reader.packed()
                var i = 0
                while i + 1 < tags.count {
                    let k = Int(tags[i]), v = Int(tags[i + 1])
                    if k < keys.count, v < values.count { feature.properties[keys[k]] = values[v] }
                    i += 2
                }
            case (3, 0): feature.type = GeometryType(rawValue: Int(try reader.varint())) ?? .unknown
            case (4, 2): geometry = try reader.packed()
            default: try reader.skip(wire)
            }
        }
        feature.parts = try parts(geometry, type: feature.type)
        return feature
    }

    /// MoveTo / LineTo / ClosePath commands with zigzag deltas.
    private static func parts(_ commands: [UInt32], type: GeometryType) throws -> [[CGPoint]] {
        var parts: [[CGPoint]] = []
        var current: [CGPoint] = []
        var x: Int64 = 0, y: Int64 = 0
        var i = 0
        while i < commands.count {
            let command = commands[i] & 0x7
            let count = Int(commands[i] >> 3)
            i += 1
            switch command {
            case 1, 2:
                guard i + count * 2 <= commands.count else { throw DecodeError.truncated }
                if command == 1, !current.isEmpty, type != .point {
                    parts.append(current)
                    current = []
                }
                for _ in 0 ..< count {
                    x += Reader.zigzag(UInt64(commands[i]))
                    y += Reader.zigzag(UInt64(commands[i + 1]))
                    i += 2
                    current.append(CGPoint(x: Double(x), y: Double(y)))
                }
            case 7:
                if !current.isEmpty {
                    parts.append(current)
                    current = []
                }
            default:
                throw DecodeError.malformed
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Protocol buffer wire format, the four types MVT uses.
    private struct Reader {
        let buffer: [UInt8]
        var at = 0

        var atEnd: Bool { at >= buffer.count }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard at < buffer.count, shift < 64 else { throw DecodeError.truncated }
                let byte = buffer[at]
                at += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }

        mutating func key() throws -> (Int, Int) {
            let key = try varint()
            return (Int(key >> 3), Int(key & 7))
        }

        mutating func delimited() throws -> ArraySlice<UInt8> {
            let length = Int(try varint())
            guard length >= 0, at + length <= buffer.count else { throw DecodeError.truncated }
            defer { at += length }
            return buffer[at ..< at + length]
        }

        mutating func packed() throws -> [UInt32] {
            var inner = Reader(buffer: Array(try delimited()))
            var out: [UInt32] = []
            while !inner.atEnd { out.append(UInt32(truncatingIfNeeded: try inner.varint())) }
            return out
        }

        mutating func fixed32() throws -> UInt32 {
            guard at + 4 <= buffer.count else { throw DecodeError.truncated }
            defer { at += 4 }
            return UInt32(buffer[at]) | UInt32(buffer[at + 1]) << 8 | UInt32(buffer[at + 2]) << 16 | UInt32(buffer[at + 3]) << 24
        }

        mutating func fixed64() throws -> UInt64 {
            UInt64(try fixed32()) | UInt64(try fixed32()) << 32
        }

        mutating func skip(_ wire: Int) throws {
            switch wire {
            case 0: _ = try varint()
            case 1: guard at + 8 <= buffer.count else { throw DecodeError.truncated }; at += 8
            case 2: _ = try delimited()
            case 5: guard at + 4 <= buffer.count else { throw DecodeError.truncated }; at += 4
            default: throw DecodeError.malformed
            }
        }

        static func zigzag(_ n: UInt64) -> Int64 {
            Int64(bitPattern: n >> 1) ^ -Int64(bitPattern: n & 1)
        }
    }
}
