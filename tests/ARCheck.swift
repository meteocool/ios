import Foundation
import Metal
import simd

/// Checks for the AR storm view's logic that runs without a device: the
/// volume decoder, the geodesy, the sun, the compass, the palettes, the map
/// link, the placement and picking of a storm, and the shaders, which are
/// compiled here with the Mac's own Metal and their uniform structs compared
/// against the Swift mirrors byte for byte.
///
/// `MC_AR_FIXTURE=/path/to/storm.mcvx` also decodes a real volume.
@main
enum ARCheck {
    @MainActor
    static func main() throws {
        try volumes()
        geodesy()
        sun()
        compass()
        palettes()
        links()
        try placementAndPicking()
        try shaders()
        print("AR checks passed")
    }

    // MARK: Volume

    /// A box with one storm in it: a column of 50 dBZ, 6 km across, from the
    /// floor to 9 km, in clear but well-seen air; no beam above 14 km.
    static func syntheticVolume(nx: Int = 40, ny: Int = 40, nz: Int = 32) -> Data {
        let header: [String: Any] = [
            "code": "G4800011580", "reference_time": "2026-10-04T02:05:00+00:00",
            "lon": 11.58, "lat": 48.0, "nx": nx, "ny": ny, "nz": nz,
            "step_m": [1000.0, 1000.0, 500.0], "origin_m": [-20000.0, -20000.0, 0.0],
            "dbz_floor": -32.0, "dbz_scale": 2.0, "sites": ["deisn"], "coverage": 1.0,
            "network": "de", "tier": 2, "scanned_at": "2026-10-04T02:09:00+00:00",
        ]
        let json = try! JSONSerialization.data(withJSONObject: header)
        var data = Data("MCVX".utf8)
        for value in [UInt32(1), UInt32(json.count)] { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(json)
        var voxels = [UInt8](repeating: 0, count: nx * ny * nz * 2)
        for z in 0 ..< nz {
            for y in 0 ..< ny {
                for x in 0 ..< nx {
                    let i = ((z * ny + y) * nx + x) * 2
                    let dx = Double(x) + 0.5 - Double(nx) / 2, dy = Double(y) + 0.5 - Double(ny) / 2
                    let inside = dx * dx + dy * dy <= 9 && Double(z) * 0.5 < 9
                    let dbz = inside ? 50.0 : -10.0
                    voxels[i] = UInt8((dbz + 32) * 2)
                    voxels[i + 1] = Double(z) * 0.5 < 14 ? 255 : 0
                }
            }
        }
        data.append(contentsOf: voxels)
        return data
    }

    static func volumes() throws {
        let raw = syntheticVolume()
        let volume = try StormVolume.decode(raw)
        precondition(volume.header.nx == 40 && volume.header.nz == 32)
        precondition(volume.extentM == SIMD3(40_000, 40_000, 16_000))
        precondition(volume.originM == SIMD3(-20_000, -20_000, 0))
        precondition(abs(volume.maxDbz - 50) < 0.01, "max \(volume.maxDbz)")
        // 300 voxels of 50 dBZ remain, so the peel stops 14 dBZ below them.
        precondition(abs(volume.coreDbz - 36) < 0.01, "core \(volume.coreDbz)")
        precondition(volume.echoTopM == 9_000, "top \(String(describing: volume.echoTopM))")
        let centre = volume.sample(SIMD3(0.5, 0.5, 0.1))!
        precondition(abs(centre.dbz - 50) < 0.01 && centre.confidence == 1)
        precondition(volume.sample(SIMD3(0.5, 0.5, 0.95))!.confidence == 0)
        precondition(volume.sample(SIMD3(1.2, 0.5, 0.5)) == nil)

        // A ray along x at a quarter of the box's height meets the column at
        // the voxel its edge falls in, 3 km from the centre: x = 0.425.
        let hit = volume.firstHit(origin: SIMD3(-0.5, 0.5, 0.25), direction: SIMD3(1, 0, 0), low: 20)
        precondition(hit.map { abs($0 - 0.925) < 0.015 } == true, "hit \(String(describing: hit))")
        precondition(volume.firstHit(origin: SIMD3(-0.5, 0.1, 0.25), direction: SIMD3(1, 0, 0), low: 20) == nil)

        // The same bytes gzipped, as a fixture on disk would be.
        let deflated = try (raw as NSData).compressed(using: .zlib) as Data
        var gzip = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        gzip.append(deflated)
        gzip.append(Data(count: 8))
        let inflated = try StormVolume.decode(gzip)
        precondition(inflated.header.code == "G4800011580")

        var wrong = raw
        wrong.removeLast(2)
        do { _ = try StormVolume.decode(wrong); preconditionFailure("short volume accepted") }
        catch StormVolume.DecodeError.wrongSize {} catch { preconditionFailure("wrong error \(error)") }
        do { _ = try StormVolume.decode(Data("NOPE".utf8) + raw.dropFirst(4)); preconditionFailure("bad magic accepted") }
        catch StormVolume.DecodeError.notAVolume {} catch { preconditionFailure("wrong error \(error)") }

        if let path = ProcessInfo.processInfo.environment["MC_AR_FIXTURE"] {
            let real = try StormVolume.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            print(String(format: "fixture %@: %dx%dx%d, max %.1f dBZ, core %.1f dBZ, top %.0f m",
                         real.header.code, real.header.nx, real.header.ny, real.header.nz,
                         real.maxDbz, real.coreDbz, real.echoTopM ?? -1))
        }
    }

    // MARK: Geodesy

    static func geodesy() {
        let viewer = GeoFrame(latitude: 48.0, longitude: 11.0, altitude: 0)
        // A point on the ellipsoid 60 km north drops about d^2 / 2R below the
        // viewer's horizontal plane: 282 m.
        let north60 = Geo.destination(lat: 48.0, lon: 11.0, bearing: 0, metres: 60_000)
        let p = viewer.enu(latitude: north60.lat, longitude: north60.lon, altitude: 0)
        precondition(abs(p.y - 60_000) < 200, "north \(p.y)")
        precondition(p.z < -275 && p.z > -290, "drop at 60 km \(p.z)")
        let east100 = Geo.destination(lat: 48.0, lon: 11.0, bearing: 90, metres: 100_000)
        let q = viewer.enu(latitude: east100.lat, longitude: east100.lon, altitude: 0)
        precondition(q.z < -770 && q.z > -800, "drop at 100 km \(q.z)")

        let (metres, bearing) = Geo.distanceBearing(fromLat: 48, lon: 11, toLat: north60.lat, lon: north60.lon)
        precondition(abs(metres - 60_000) < 1 && abs(bearing) < 0.01)
        let r = 6_378_137.0, lat = 48.1351, lon = 11.581
        let back = Geo.lonLat(mercatorX: lon * .pi / 180 * r, y: r * log(tan(.pi / 4 + lat * .pi / 360)))
        precondition(abs(back.lon - lon) < 1e-9 && abs(back.lat - lat) < 1e-9, "mercator \(back)")
        precondition(Geo.compassPoint(247, german: false) == "WSW" && Geo.compassPoint(80, german: true) == "O")
        precondition(abs(Geo.angleDifference(10, 350) - 20) < 1e-9 && abs(Geo.angleDifference(350, 10) + 20) < 1e-9)
        precondition(abs(GeoFrame.horizonDip(eyeAboveGround: 100) - 0.321) < 0.005)

        let moved = DeadReckoning.advance(lat: 48, lon: 11, headingDeg: 90, speedKmh: 60, minutes: 10)
        let (km10, east) = Geo.distanceBearing(fromLat: 48, lon: 11, toLat: moved.lat, lon: moved.lon)
        precondition(abs(km10 - 10_000) < 1 && abs(east - 90) < 0.1)
    }

    static func sun() {
        // Munich on the June solstice: the sun culminates at 90 - 48.14 + 23.44
        // degrees, due south, around 11:15 UTC.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 6, day: 21))!
        var best = (elevation: -90.0, azimuth: 0.0, minute: 0)
        for minute in stride(from: 0, to: 1_440, by: 1) {
            let position = SunPosition.at(day.addingTimeInterval(Double(minute) * 60), latitude: 48.14, longitude: 11.58)
            if position.elevation > best.elevation { best = (position.elevation, position.azimuth, minute) }
        }
        precondition(abs(best.elevation - 65.3) < 0.1, "culmination \(best.elevation)")
        precondition(abs(best.azimuth - 180) < 1.5, "culmination azimuth \(best.azimuth)")
        precondition(abs(best.minute - 676) < 4, "culmination at minute \(best.minute)")
        let morning = SunPosition.at(day.addingTimeInterval(4 * 3600), latitude: 48.14, longitude: 11.58)
        precondition(morning.azimuth > 60 && morning.azimuth < 80 && morning.elevation > 5, "morning \(morning)")
        let night = SunPosition.at(day.addingTimeInterval(23 * 3600), latitude: 48.14, longitude: 11.58)
        precondition(night.elevation < -10)
    }

    static func compass() {
        // Upright in portrait: gravity down the screen. The field points north
        // and down. Device axes: x right, y up, z out of the screen.
        let gravity = SIMD3<Double>(0, -1, 0)
        let facingNorth = SIMD3<Double>(0, -40, -20)   // north is out of the back
        let facingEast = SIMD3<Double>(-20, -40, 0)    // north is to the left
        let facingSouthWest = SIMD3<Double>(20 / 2.squareRoot(), -40, 20 / 2.squareRoot())
        precondition(abs(Compass.cameraAzimuth(gravity: gravity, magneticField: facingNorth)!) < 1e-6)
        precondition(abs(Compass.cameraAzimuth(gravity: gravity, magneticField: facingEast)! - 90) < 1e-6)
        precondition(abs(Compass.cameraAzimuth(gravity: gravity, magneticField: facingSouthWest)! - 225) < 1e-6)
        // Lying flat, face up: the camera looks at the ground; no heading.
        precondition(Compass.cameraAzimuth(gravity: SIMD3(0, 0, -1), magneticField: SIMD3(0, 20, -40)) == nil)
    }

    static func palettes() {
        // classic: index (45 + 32.5) * 2 = 155, the table starting at 57.
        let packed = ColormapTables.tables["classic"]!.rgba[155 - 57]
        let rgb = Colormaps.colour(dbz: 45, palette: "classic")
        precondition(rgb == SIMD3(UInt8(packed >> 24), UInt8((packed >> 16) & 0xFF), UInt8((packed >> 8) & 0xFF)))
        precondition(Colormaps.colour(dbz: -20, palette: "classic") == SIMD3(0, 0, 0))
        precondition(Colormaps.colour(dbz: 45, palette: "no such palette") == rgb)
        for name in Colormaps.names { precondition(ColormapTables.tables[name] != nil, name) }
        precondition(Colormaps.ramp(palette: "homeyer").count == 1024)
    }

    static func links() {
        let path = "meteoradar/volumes/20261004T020500/de-G1374918628.mcvx"
        precondition(MapLink.cloudLink(path) == "20261004T020500/de-G1374918628")
        precondition(MapLink.cloudLink("meteoradar/volumes/20261004T020500/../../x.mcvx") == nil)
        precondition(MapLink.isCellCode("2026100402050000012345") && !MapLink.isCellCode("20261004020500000123"))
        let entry = try! JSONDecoder.snake.decode(StormEntry.self, from: Data("""
            {"code":"G1374918628","network":"de","lon":6.28,"lat":47.49,"path":"\(path)","tier":2}
            """.utf8))
        precondition(MapLink.search(for: entry, cell: nil) == "?layer=cells3d&cloud=20261004T020500/de-G1374918628")
        let script = MapLink.openScript(search: "?a=\"</script>")!
        precondition(script.contains(#"["?a=\"<\/script>"][0]"#) || script.contains(#"["?a=\"</script>"][0]"#), script)
    }

    // MARK: Scene

    @MainActor
    static func placementAndPicking() throws {
        let volume = try StormVolume.decode(syntheticVolume())
        // The storm 30 km due north of the viewer.
        let at = Geo.destination(lat: 48, lon: 11, bearing: 0, metres: 30_000)
        let entry = try JSONDecoder.snake.decode(StormEntry.self, from: Data("""
            {"code":"G1","lon":\(at.lon),"lat":\(at.lat),"path":"meteoradar/volumes/20261004T020500/de-G4800011580.mcvx","tier":2,"scanned_at":"2026-10-04T02:09:00Z"}
            """.utf8))
        let scene = StormScene(frame: GeoFrame(latitude: 48, longitude: 11, altitude: 500))
        scene.now = ISODate.parse("2026-10-04T02:15:00Z")!

        var storm = scene.place(entry, volume: volume, cell: nil)
        // North is -z in ARKit's world; the box's floor is sea level, 500 m
        // below the viewer, and the earth's curve takes another 70 m.
        precondition(abs(storm.centre.x) < 1 && abs(storm.centre.z + 30_000) < 20, "centre \(storm.centre)")
        precondition(storm.centre.y < -560 && storm.centre.y > -580, "height \(storm.centre.y)")
        precondition(abs(storm.distance - 30_000) < 1 && abs(storm.bearing) < 0.01)
        precondition(abs(storm.age! - 360) < 1)

        // A heading error of 10 degrees turns everything 10 degrees anticlockwise.
        scene.alignmentError = 10
        let turned = scene.place(entry, volume: volume, cell: nil)
        precondition(abs(StormScene.frameAzimuth(ofWorld: SIMD3<Float>(turned.centre)) - 350) < 0.05)
        scene.alignmentError = 0

        // A camera at the origin looking north, 5 degrees up: the column's
        // middle, 30 km away and 4.5 km up, is just above the screen's centre.
        let pose = lookingNorth(pitch: 5)
        let centre = pose.project(SIMD3<Float>(storm.centre + storm.up * 4_500))!
        precondition(abs(centre.x - 200) < 1 && centre.y < 300 && centre.y > 200, "projected \(centre)")
        precondition(scene.pick(centre, pose: pose, storms: [storm])?.entry.code == "G1")
        precondition(scene.pick(CGPoint(x: 20, y: 300), pose: pose, storms: [storm]) == nil)

        // The cut for Slice faces the viewer: its normal points back at them.
        scene.mode = .slice
        scene.sliderValue = 0
        let (_, normal) = scene.cutPlane(for: storm, pose: pose)!
        precondition(normal.z > 0.99, "slice normal \(normal)")
        let uniforms = scene.uniforms(for: storm, volume: volume, pose: pose, target: CGSize(width: 200, height: 300),
                                      light: SIMD3(0, 0, 1))
        precondition(uniforms.planeNormal.w == 1 && uniforms.planeNormal.y < -0.99, "box normal \(uniforms.planeNormal)")

        // Extrapolating a storm moving east at 60 km/h, measured six minutes ago.
        scene.extrapolate = true
        let cell = try JSONDecoder.snake.decode(TrackedCell.self, from: Data("""
            {"code":"2026100402050000012345","lon":\(at.lon),"lat":\(at.lat),"heading_deg":90,"speed_kmh":60}
            """.utf8))
        storm = scene.place(entry, volume: volume, cell: cell)
        precondition(abs((storm.extrapolatedMinutes ?? 0) - 6) < 0.01 && abs(storm.centre.x - 6_000) < 50, "moved \(storm.centre)")
    }

    static func lookingNorth(pitch: Float) -> CameraPose {
        let p = pitch * .pi / 180
        let cameraToWorld = simd_float4x4(simd_quatf(angle: p, axis: SIMD3(1, 0, 0)))
        let fovY: Float = 55 * .pi / 180, aspect: Float = 400.0 / 600, near: Float = 1, far: Float = 400_000
        let ys = 1 / tan(fovY / 2), xs = ys / aspect, zs = far / (near - far)
        let projection = simd_float4x4(columns: (SIMD4(xs, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs * near, 0)))
        return CameraPose(view: cameraToWorld.transpose, projection: projection, position: .zero, viewport: CGSize(width: 400, height: 600))
    }

    // MARK: Shaders

    static func shaders() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("no Metal device; shader checks skipped")
            return
        }
        // Both variants: near to far with the layer limit, and the blender's.
        // Every Mac and iPhone GPU of Apple's reads its render target; the iOS
        // simulator's claims to and its compiler refuses, so there only the
        // blender is checked (the app falls back the same way).
        #if targetEnvironment(simulator)
        let fetchVariants = [false]
        #else
        let fetchVariants = device.supportsFamily(.apple1) ? [true, false] : [false]
        #endif
        for fetch in fetchVariants {
            let options = MTLCompileOptions()
            options.preprocessorMacros = ["STORM_FETCH": NSNumber(value: fetch ? 1 : 0)]
            let library = try device.makeLibrary(source: StormShaders.source, options: options)
            for name in ["fullscreen_vertex", "camera_fragment", "sky_fragment", "volume_fragment", "composite_fragment",
                         "line_vertex", "line_fragment"] {
                precondition(library.makeFunction(name: name) != nil, "missing \(name)")
            }
            // The uniform structs, as Metal lays them out, against their mirrors.
            func fragmentBufferSize(_ fragment: String, vertex: String = "fullscreen_vertex", format: MTLPixelFormat,
                                    layers: Bool = false) throws -> Int {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: vertex)
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                descriptor.colorAttachments[0].pixelFormat = format
                if layers { descriptor.colorAttachments[1].pixelFormat = .r16Float }
                var reflection: MTLRenderPipelineReflection?
                _ = try device.makeRenderPipelineState(descriptor: descriptor, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
                let binding = reflection?.fragmentBindings.first { $0.type == .buffer && $0.index == 0 } as? MTLBufferBinding
                return binding?.bufferDataSize ?? -1
            }
            let volume = try fragmentBufferSize("volume_fragment", format: .rgba16Float, layers: fetch)
            precondition(volume == MemoryLayout<VolumeUniforms>.size, "VolumeUniforms: Metal \(volume), Swift \(MemoryLayout<VolumeUniforms>.size)")
            let camera = try fragmentBufferSize("camera_fragment", format: .bgra8Unorm)
            precondition(camera == MemoryLayout<CameraUniforms>.size, "CameraUniforms: Metal \(camera), Swift \(MemoryLayout<CameraUniforms>.size)")
            let sky = try fragmentBufferSize("sky_fragment", format: .bgra8Unorm)
            precondition(sky == MemoryLayout<SkyUniforms>.size, "SkyUniforms: Metal \(sky), Swift \(MemoryLayout<SkyUniforms>.size)")
        }
        precondition(MemoryLayout<LineVertex>.stride == 32)

        // Three storms in a row, each about 0.4 opaque: with the layer limit
        // the one behind the first two is never drawn; through the blender it is.
        let one = 1 - exp(-0.8 * 0.62)
        let two = 1 - pow(1 - one, 2), three = 1 - pow(1 - one, 3)
        let blended = try threeStorms(device: device, fetch: false)
        precondition(abs(Double(blended) - three) < 0.04, "blender: alpha \(blended), three layers would be \(three)")
        guard fetchVariants.contains(true) else {
            print(String(format: "three storms in a row: blender %.3f (three layers %.3f); no layer limit on this GPU", blended, three))
            return
        }
        let limited = try threeStorms(device: device, fetch: true)
        print(String(format: "three storms in a row: layer limit %.3f (two layers %.3f), blender %.3f (three layers %.3f)",
                     limited, two, blended, three))
        precondition(abs(Double(limited) - two) < 0.04, "layer limit: alpha \(limited), two layers would be \(two)")
    }

    /// The alpha at the middle of a frame looking down -z through three
    /// identical 1 km deep boxes of 30 dBZ storm, 10, 12 and 14 km away.
    static func threeStorms(device: MTLDevice, fetch: Bool) throws -> Float {
        let options = MTLCompileOptions()
        options.preprocessorMacros = ["STORM_FETCH": NSNumber(value: fetch ? 1 : 0)]
        let library = try device.makeLibrary(source: StormShaders.source, options: options)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "volume_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        if fetch {
            descriptor.colorAttachments[1].pixelFormat = .r16Float
        } else {
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let size = 8
        func target(_ format: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        let colour = target(.rgba16Float), layers = target(.r16Float)

        let volumeDescriptor = MTLTextureDescriptor()
        volumeDescriptor.textureType = .type3D
        volumeDescriptor.pixelFormat = .rg8Unorm
        volumeDescriptor.width = 8; volumeDescriptor.height = 8; volumeDescriptor.depth = 8
        let volume = device.makeTexture(descriptor: volumeDescriptor)!
        // 30 dBZ, seen perfectly: a density of 0.8 under core's ramp.
        let voxels: [UInt8] = (0 ..< 8 * 8 * 8 * 2).map { $0 % 2 == 0 ? 124 : 255 }
        voxels.withUnsafeBytes { volume.replace(region: MTLRegionMake3D(0, 0, 0, 8, 8, 8), mipmapLevel: 0, slice: 0,
                                                withBytes: $0.baseAddress!, bytesPerRow: 16, bytesPerImage: 128) }
        let ramp = device.makeTexture(descriptor: MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false))!
        let white = [UInt8](repeating: 255, count: 1024)
        white.withUnsafeBytes { ramp.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 1024) }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colour
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        if fetch {
            pass.colorAttachments[1].texture = layers
            pass.colorAttachments[1].loadAction = .clear
            pass.colorAttachments[1].storeAction = .dontCare
        }
        let queue = device.makeCommandQueue()!
        let buffer = queue.makeCommandBuffer()!
        let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(volume, index: 0)
        encoder.setFragmentTexture(ramp, index: 1)

        let ys: Float = 1 / tan(Float.pi / 6), zs: Float = 100_000 / (1 - 100_000)
        let projection = simd_float4x4(columns: (SIMD4(ys, 0, 0, 0), SIMD4(0, ys, 0, 0), SIMD4(0, 0, zs, -1), SIMD4(0, 0, zs, 0)))
        // Near to far for the layer limit, far to near for the blender.
        let order = fetch ? [0, 1, 2] : [2, 1, 0]
        for box in order {
            let nearZ = 10_000 + Float(box) * 2_000
            // World to unit cube: x, y across 10 km, z through 1 km, far face at 0.
            var worldToBox = matrix_identity_float4x4
            worldToBox.columns.0.x = 1 / 10_000
            worldToBox.columns.1.y = 1 / 10_000
            worldToBox.columns.2.z = 1 / 1_000
            worldToBox.columns.3 = SIMD4(0.5, 0.5, (nearZ + 1_000) / 1_000, 1)
            var u = VolumeUniforms()
            u.inverseViewProjection = projection.inverse
            u.worldToBox = worldToBox
            u.camera = SIMD4(0, 0, 0, 1)
            u.earth = SIMD4(0, -1e9, 0, 1)
            u.extentKm = SIMD4(10, 10, 1, 0)
            u.light = SIMD4(0, 0, 1, 0)
            u.shells = SIMD4(35, 45, 55, 0)
            u.viewport = SIMD2(Float(size), Float(size))
            u.slab = SIMD2(-1, 2)
            u.dbzFloor = -32
            u.dbzScale = 2
            u.low = 20
            u.steps = 96
            u.dim = 1
            encoder.setFragmentBytes(&u, length: MemoryLayout<VolumeUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        let readback = device.makeBuffer(length: size * size * 8, options: .storageModeShared)!
        let blit = buffer.makeBlitCommandEncoder()!
        blit.copy(from: colour, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0, 0, 0),
                  sourceSize: MTLSizeMake(size, size, 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: size * 8, destinationBytesPerImage: size * size * 8)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        let halves = readback.contents().bindMemory(to: Float16.self, capacity: size * size * 4)
        let middle = (size / 2 * size + size / 2) * 4
        return Float(halves[middle + 3])
    }
}

extension JSONDecoder {
    static var snake: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
