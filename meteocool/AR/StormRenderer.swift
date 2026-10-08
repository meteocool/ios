//
//  StormRenderer.swift
//  meteocool
//
//  Metal: the camera image, the storms, and the lines over and under them.
//

import CoreVideo
import Metal
import MetalKit
import simd

/// Draws one frame the scene has laid out.
///
/// Its own Metal rather than RealityKit or SceneKit: a storm is a 3D texture
/// and a fragment shader, not a mesh, and both engines are
/// built for surfaces. The storms are raymarched into a texture at a fraction
/// of the screen's resolution, then stretched over the camera image: a
/// raymarch per pixel at a phone's full resolution is the most expensive
/// thing the app could ask of its GPU.
///
/// Near to far, on every GPU that can read its render target (all of Apple's):
/// each pixel counts the storms in front of it, and once two have drawn real
/// cloud there, or it is opaque, the storms behind are not marched at all.
/// From the ground a sky of storms is mostly storms hidden behind storms, and
/// that is the work this skips. See `volume_fragment` in `StormShaders`.
@MainActor
final class StormRenderer {
    enum Background {
        /// ARKit's camera image, and the transform from normalised view
        /// coordinates to normalised image coordinates.
        case camera(CVPixelBuffer, CGAffineTransform)
        /// The preview's sky.
        case sky(horizonDip: Double)
    }

    struct Storm {
        let path: String
        let volume: StormVolume
        let uniforms: VolumeUniforms
        let boxToWorld: simd_float4x4
        /// From the camera, for the drawing order.
        let distance: Float
        /// The storm it is a tile of (`StormEntry.stormKey`): layers are
        /// counted per storm, so a storm's own tiles never hide each other.
        let system: String
    }

    struct Frame {
        var background: Background
        var pose: CameraPose
        /// In any order; the renderer orders them.
        var storms: [Storm]
        var under: [WorldLine]
        var over: [WorldLine]
    }

    let device: MTLDevice
    /// The storm pass's resolution relative to the drawable's.
    var resolutionScale: CGFloat = 0.5
    /// Samples along a ray across a whole 40 km box, the size before tiles;
    /// a shorter stretch of ray inside a box takes proportionally fewer.
    var steps: Float = 96

    private let queue: MTLCommandQueue
    private let cameraPipeline: MTLRenderPipelineState
    private let skyPipeline: MTLRenderPipelineState
    private let volumePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private var ramp: MTLTexture?
    private var rampPalette: String?
    private var volumeTextures: [String: MTLTexture] = [:]
    private var offscreen: MTLTexture?
    private var layers: MTLTexture?
    /// Whether storms are drawn near to far with the layer limit
    /// (`STORM_FETCH`), or far to near through the blender.
    let limitsLayers: Bool

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true

        func compile(fetch: Bool) -> MTLLibrary? {
            let options = MTLCompileOptions()
            options.preprocessorMacros = ["STORM_FETCH": NSNumber(value: fetch ? 1 : 0)]
            do {
                return try device.makeLibrary(source: StormShaders.source, options: options)
            } catch where fetch {
                // The iOS simulator's GPU claims Apple's family but its
                // compiler refuses to read a render target. That is expected:
                // the blender takes over.
                NSLog("AR storms: this GPU cannot read its render target (%@)", error.localizedDescription)
                return nil
            } catch {
                NSLog("AR storm shaders did not compile: %@", String(describing: error))
                return nil
            }
        }
        func pipeline(_ library: MTLLibrary, _ fragment: String, vertex: String = "fullscreen_vertex",
                      format: MTLPixelFormat, blend: Bool, layers: Bool = false) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = format
            if layers { descriptor.colorAttachments[1].pixelFormat = Self.layersFormat }
            if blend {
                // Premultiplied "over": what is drawn later is in front.
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        // The layer limit where the GPU reads its target; the blender where
        // it cannot, or where that variant fails to build for any reason.
        var library: MTLLibrary?
        var volume: MTLRenderPipelineState?
        var limitsLayers = false
        if device.supportsFamily(.apple1), let fetching = compile(fetch: true),
           let layered = pipeline(fetching, "volume_fragment", format: .rgba16Float, blend: false, layers: true) {
            library = fetching
            volume = layered
            limitsLayers = true
        } else if let blending = compile(fetch: false) {
            library = blending
            volume = pipeline(blending, "volume_fragment", format: .rgba16Float, blend: true)
        }
        guard let library, let volume,
              let camera = pipeline(library, "camera_fragment", format: .bgra8Unorm, blend: false),
              let sky = pipeline(library, "sky_fragment", format: .bgra8Unorm, blend: false),
              let composite = pipeline(library, "composite_fragment", format: .bgra8Unorm, blend: true),
              let line = pipeline(library, "line_fragment", vertex: "line_vertex", format: .bgra8Unorm, blend: true) else { return nil }
        self.limitsLayers = limitsLayers
        NSLog("AR storms: %@", limitsLayers ? "near to far, at most two layers per pixel" : "far to near through the blender")
        cameraPipeline = camera
        skyPipeline = sky
        volumePipeline = volume
        compositePipeline = composite
        linePipeline = line
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    // MARK: Textures

    func setPalette(_ palette: String) {
        guard palette != rampPalette else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        let pixels = Colormaps.ramp(palette: palette)
        pixels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: 256 * 4)
        }
        ramp = texture
        rampPalette = palette
    }

    private func texture(for storm: Storm) -> MTLTexture? {
        if let existing = volumeTextures[storm.path] { return existing }
        let header = storm.volume.header
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rg8Unorm
        descriptor.width = header.nx
        descriptor.height = header.ny
        descriptor.depth = header.nz
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        storm.volume.voxels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, header.nx, header.ny, header.nz), mipmapLevel: 0, slice: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: header.nx * 2, bytesPerImage: header.nx * header.ny * 2)
        }
        volumeTextures[storm.path] = texture
        return texture
    }

    /// Let go of the textures of storms no longer held.
    func retain(only paths: Set<String>) {
        for path in volumeTextures.keys where !paths.contains(path) { volumeTextures[path] = nil }
    }

    // MARK: Drawing

    func draw(_ frame: Frame, in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        guard size.width > 0, size.height > 0 else { return }

        // The storms, into their own lower-resolution target.
        let target = stormTarget(for: size)
        if let target, let ramp {
            let stormPass = MTLRenderPassDescriptor()
            stormPass.colorAttachments[0].texture = target
            stormPass.colorAttachments[0].loadAction = .clear
            stormPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            stormPass.colorAttachments[0].storeAction = .store
            if limitsLayers, let layers = layersTarget(width: target.width, height: target.height) {
                // How many storms have drawn cloud at each pixel. Read only
                // inside this pass, so it never has to leave the GPU's tiles.
                stormPass.colorAttachments[1].texture = layers
                stormPass.colorAttachments[1].loadAction = .clear
                stormPass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                stormPass.colorAttachments[1].storeAction = .dontCare
            }
            // Near to far with the layer limit, far to near through the blender.
            let ordered = frame.storms.sorted { limitsLayers ? $0.distance < $1.distance : $0.distance > $1.distance }
            // Each storm a small number, exact in the half floats the layer
            // count is kept in.
            var systems: [String: Float] = [:]
            for storm in ordered where systems[storm.system] == nil { systems[storm.system] = Float(systems.count + 1) }
            if let encoder = buffer.makeRenderCommandEncoder(descriptor: stormPass) {
                encoder.setRenderPipelineState(volumePipeline)
                encoder.setFragmentTexture(ramp, index: 1)
                let targetSize = CGSize(width: target.width, height: target.height)
                for storm in ordered {
                    guard let texture = texture(for: storm),
                          let scissor = scissor(for: storm.boxToWorld, min: storm.uniforms.boxMin, max: storm.uniforms.boxMax,
                                                pose: frame.pose, target: targetSize) else { continue }
                    var uniforms = storm.uniforms
                    uniforms.viewport = SIMD2(Float(targetSize.width), Float(targetSize.height))
                    uniforms.steps = steps
                    uniforms.stepMetres = 40_000 / steps
                    uniforms.system = systems[storm.system] ?? 0
                    encoder.setScissorRect(scissor)
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VolumeUniforms>.stride, index: 0)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                encoder.endEncoding()
            }
        }

        // The frame: background, ground lines, storms, lines over them.
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var heldTextures: [CVMetalTexture] = []
        switch frame.background {
        case .camera(let pixelBuffer, let viewToImage):
            if let (luma, chroma) = cameraTextures(pixelBuffer) {
                heldTextures = [luma, chroma]
                var uniforms = CameraUniforms(
                    imageFromViewX: SIMD2(Float(viewToImage.a), Float(viewToImage.b)),
                    imageFromViewY: SIMD2(Float(viewToImage.c), Float(viewToImage.d)),
                    imageFromViewOffset: SIMD2(Float(viewToImage.tx), Float(viewToImage.ty)))
                encoder.setRenderPipelineState(cameraPipeline)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CameraUniforms>.stride, index: 0)
                encoder.setFragmentTexture(CVMetalTextureGetTexture(luma), index: 0)
                encoder.setFragmentTexture(CVMetalTextureGetTexture(chroma), index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        case .sky(let dip):
            var uniforms = SkyUniforms(inverseViewProjection: frame.pose.viewProjection.inverse,
                                       camera: SIMD4(frame.pose.position, 1), up: SIMD4(0, 1, 0, 0),
                                       viewport: SIMD2(Float(size.width), Float(size.height)),
                                       horizonDip: Float(sin(dip * .pi / 180)), padding: 0)
            encoder.setRenderPipelineState(skyPipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SkyUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        let scale = Float(view.contentScaleFactor)
        drawLines(frame.under, pose: frame.pose, size: size, scale: scale, encoder: encoder)
        if let target {
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setFragmentTexture(target, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        drawLines(frame.over, pose: frame.pose, size: size, scale: scale, encoder: encoder)
        encoder.endEncoding()

        buffer.present(drawable)
        // The camera textures must outlive the GPU's use of them.
        // Metal calls this on a thread of its own, hence `@Sendable` and the box.
        let held = HeldTextures(heldTextures)
        buffer.addCompletedHandler { @Sendable _ in _ = held }
        buffer.commit()
    }

    private func stormTarget(for size: CGSize) -> MTLTexture? {
        let width = max(1, Int(size.width * resolutionScale)), height = max(1, Int(size.height * resolutionScale))
        if let offscreen, offscreen.width == width, offscreen.height == height { return offscreen }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        offscreen = device.makeTexture(descriptor: descriptor)
        return offscreen
    }

    /// Storms counted at a pixel, and the last one counted (see `StormPixel`).
    static let layersFormat: MTLPixelFormat = .rg16Float

    private func layersTarget(width: Int, height: Int) -> MTLTexture? {
        if let layers, layers.width == width, layers.height == height { return layers }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.layersFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget
        #if targetEnvironment(simulator)
        descriptor.storageMode = .private
        #else
        // Never stored: it lives and dies in tile memory within the pass.
        descriptor.storageMode = .memoryless
        #endif
        layers = device.makeTexture(descriptor: descriptor)
        return layers
    }

    /// The pixels the marched part of a box can cover: the bounding rectangle
    /// of its corners on screen, or the whole target when the camera is among them.
    private func scissor(for boxToWorld: simd_float4x4, min boxMin: SIMD4<Float>, max boxMax: SIMD4<Float>,
                         pose: CameraPose, target: CGSize) -> MTLScissorRect? {
        let viewProjection = pose.viewProjection
        var minX = Float.infinity, minY = Float.infinity, maxX = -Float.infinity, maxY = -Float.infinity
        for corner in 0 ..< 8 {
            let unit = SIMD4<Float>(corner & 1 == 0 ? boxMin.x : boxMax.x,
                                    (corner >> 1) & 1 == 0 ? boxMin.y : boxMax.y,
                                    (corner >> 2) & 1 == 0 ? boxMin.z : boxMax.z, 1)
            let clip = viewProjection * (boxToWorld * unit)
            if clip.w <= 0.01 {
                return MTLScissorRect(x: 0, y: 0, width: Int(target.width), height: Int(target.height))
            }
            let ndc = SIMD2(clip.x, clip.y) / clip.w
            minX = min(minX, ndc.x); maxX = max(maxX, ndc.x)
            minY = min(minY, ndc.y); maxY = max(maxY, ndc.y)
        }
        let w = Float(target.width), h = Float(target.height)
        let left = max(0, Int(((minX + 1) / 2 * w).rounded(.down)))
        let right = min(Int(w), Int(((maxX + 1) / 2 * w).rounded(.up)))
        let top = max(0, Int(((1 - maxY) / 2 * h).rounded(.down)))
        let bottom = min(Int(h), Int(((1 - minY) / 2 * h).rounded(.up)))
        guard right > left, bottom > top else { return nil }
        return MTLScissorRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func cameraTextures(_ pixelBuffer: CVPixelBuffer) -> (CVMetalTexture, CVMetalTexture)? {
        guard let textureCache, CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return nil }
        func plane(_ index: Int, _ format: MTLPixelFormat) -> CVMetalTexture? {
            var texture: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil, format,
                                                      CVPixelBufferGetWidthOfPlane(pixelBuffer, index),
                                                      CVPixelBufferGetHeightOfPlane(pixelBuffer, index), index, &texture)
            return texture
        }
        guard let luma = plane(0, .r8Unorm), let chroma = plane(1, .rg8Unorm) else { return nil }
        return (luma, chroma)
    }

    /// World lines as screen-space ribbons a fixed number of points wide.
    private func drawLines(_ lines: [WorldLine], pose: CameraPose, size: CGSize, scale: Float, encoder: MTLRenderCommandEncoder) {
        guard !lines.isEmpty else { return }
        let viewProjection = pose.viewProjection
        let half = SIMD2(Float(size.width) / 2, Float(size.height) / 2)
        var vertices: [LineVertex] = []
        vertices.reserveCapacity(lines.count * 6)
        let nearW: Float = 0.5
        for line in lines {
            var a = viewProjection * SIMD4(line.a, 1), b = viewProjection * SIMD4(line.b, 1)
            if a.w < nearW && b.w < nearW { continue }
            // Clip against a plane just in front of the camera, so a segment
            // passing behind the viewer does not wrap across the screen.
            if a.w < nearW { a = a + (b - a) * ((nearW - a.w) / (b.w - a.w)) }
            if b.w < nearW { b = b + (a - b) * ((nearW - b.w) / (a.w - b.w)) }
            let na = SIMD2(a.x, a.y) / a.w, nb = SIMD2(b.x, b.y) / b.w
            let pixels = (nb - na) * half
            guard length(pixels) > 1e-3 else { continue }
            let perpendicular = normalize(SIMD2(-pixels.y, pixels.x)) * (line.width * scale / 2) / half
            let colour = SIMD4(SIMD3(line.colour.x, line.colour.y, line.colour.z) * line.colour.w, line.colour.w)
            let corners = [na - perpendicular, na + perpendicular, nb - perpendicular, nb + perpendicular]
                .map { (corner: SIMD2<Float>) in LineVertex(position: SIMD4<Float>(corner.x, corner.y, 0, 1), colour: colour) }
            vertices += [corners[0], corners[1], corners[2], corners[1], corners[3], corners[2]]
        }
        guard !vertices.isEmpty,
              let buffer = device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<LineVertex>.stride) else { return }
        encoder.setRenderPipelineState(linePipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    }
}

/// Keeps a frame's camera textures alive until the GPU is done with them.
/// Only ever read by being released, so sharing it across threads is safe.
private final class HeldTextures: @unchecked Sendable {
    let textures: [CVMetalTexture]
    init(_ textures: [CVMetalTexture]) { self.textures = textures }
}
