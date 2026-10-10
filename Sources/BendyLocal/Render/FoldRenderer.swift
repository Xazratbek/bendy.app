import Foundation
import Metal
import QuartzCore
import simd

final class FoldRenderer {
    private static let gridResolution = 48

    private struct FoldUniforms {
        var fold: Float = 0
        var perspective: Float = 0
        var darkening: Float = 0
        var shadowStrength: Float = 0
        var sheen: Float = 0
        var curvature: Float = 0
        var blurMix: Float = 0
        var blurLOD: Float = 0
        var vignette: Float = 0
        var edgeSoftness: Float = 0
        var cornerRadius: Float = 0
        var aspect: Float = 1
    }

    private struct BlurUniforms {
        var texelStep: SIMD2<Float> = .zero
        var radius: Float = 0
    }

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let blurPipeline: MTLRenderPipelineState
    private let foldPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let gridBuffer: MTLBuffer
    private let gridVertexCount: Int

    private var blurA: MTLTexture?
    private var blurB: MTLTexture?
    private var blurSize: CGSize = .zero
    private var panelTexture: MTLTexture?
    private var panelSize: CGSize = .zero

    private static let blurDownsample: CGFloat = 4
    private static let blurIterations = 2

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.noCommandQueue }
        commandQueue = queue

        let library = try device.makeLibrary(source: Shaders.source, options: nil)

        func pipeline(_ vertex: String, _ fragment: String, blending: Bool) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            if blending {
                desc.colorAttachments[0].isBlendingEnabled = true
                desc.colorAttachments[0].sourceRGBBlendFactor = .one
                desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                desc.colorAttachments[0].sourceAlphaBlendFactor = .one
                desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        blurPipeline = try pipeline("fullscreenVertex", "blurFragment", blending: false)
        foldPipeline = try pipeline("foldVertex", "foldFragment", blending: true)
        compositePipeline = try pipeline("fullscreenVertex", "compositeFragment", blending: true)

        let grid = Self.makeGrid(resolution: Self.gridResolution)
        gridVertexCount = grid.count
        guard let buffer = device.makeBuffer(
            bytes: grid, length: MemoryLayout<SIMD2<Float>>.stride * grid.count, options: .storageModeShared
        ) else { throw RendererError.noBuffer }
        gridBuffer = buffer
    }

    private static func makeGrid(resolution n: Int) -> [SIMD2<Float>] {
        var vertices: [SIMD2<Float>] = []
        vertices.reserveCapacity(n * n * 6)
        let step = 2.0 / Float(n)
        for row in 0..<n {
            for column in 0..<n {
                let x0 = -1 + Float(column) * step
                let x1 = x0 + step
                let y0 = -1 + Float(row) * step
                let y1 = y0 + step
                vertices.append(SIMD2(x0, y0))
                vertices.append(SIMD2(x1, y0))
                vertices.append(SIMD2(x0, y1))
                vertices.append(SIMD2(x1, y0))
                vertices.append(SIMD2(x1, y1))
                vertices.append(SIMD2(x0, y1))
            }
        }
        return vertices
    }

    private func ensureBlurTextures(for size: CGSize) {
        let scaled = CGSize(
            width: max(size.width / Self.blurDownsample, 1),
            height: max(size.height / Self.blurDownsample, 1)
        )
        guard scaled != blurSize || blurA == nil else { return }
        blurSize = scaled

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(scaled.width), height: Int(scaled.height), mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        blurA = device.makeTexture(descriptor: desc)

        let mipped = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(scaled.width), height: Int(scaled.height), mipmapped: true
        )
        mipped.usage = [.renderTarget, .shaderRead]
        mipped.storageMode = .private
        blurB = device.makeTexture(descriptor: mipped)
    }

    private func ensurePanelTexture(for size: CGSize) {
        guard size != panelSize || panelTexture == nil else { return }
        panelSize = size
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: max(Int(size.width), 1), height: max(Int(size.height), 1),
            mipmapped: true
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        panelTexture = device.makeTexture(descriptor: desc)
    }

    func copy(_ source: MTLTexture, into existing: MTLTexture?) -> MTLTexture? {
        var destination = existing
        if destination == nil
            || destination?.width != source.width
            || destination?.height != source.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: source.pixelFormat,
                width: source.width, height: source.height, mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .private
            destination = device.makeTexture(descriptor: desc)
        }
        guard let destination,
              let buffer = commandQueue.makeCommandBuffer(),
              let blit = buffer.makeBlitCommandEncoder() else { return existing }
        blit.copy(from: source, to: destination)
        blit.endEncoding()
        buffer.commit()
        return destination
    }

    func render(source: MTLTexture, fold: Double, softness: Double,
                style: FoldStyle, drawable: CAMetalDrawable) {
        encode(source: source, fold: fold, softness: softness,
               style: style, target: drawable.texture) { buffer in
            buffer.present(drawable)
        }
    }

    func render(source: MTLTexture, fold: Double, softness: Double? = nil,
                style: FoldStyle, into target: MTLTexture,
                waitForCompletion: Bool = false) {
        encode(source: source, fold: fold, softness: softness ?? fold,
               style: style, target: target) { buffer in
            if waitForCompletion {
                buffer.commit()
                buffer.waitUntilCompleted()
            }
        }
    }

    private func encode(source: MTLTexture, fold: Double, softness: Double,
                        style: FoldStyle, target: MTLTexture,
                        finish: (MTLCommandBuffer) -> Void) {
        let size = CGSize(width: target.width, height: target.height)
        ensureBlurTextures(for: size)
        ensurePanelTexture(for: size)
        guard let blurA, let blurB, let panelTexture,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let foldAmount = Float(min(max(fold, 0), 1))
        let softAmount = Float(min(max(softness, 0), 1))
        blurPass(commandBuffer: commandBuffer, from: source, to: blurA,
                 step: SIMD2(1.0 / Float(blurA.width), 0), radius: 1.0)
        blurPass(commandBuffer: commandBuffer, from: blurA, to: blurB,
                 step: SIMD2(0, 1.0 / Float(blurB.height)), radius: 1.0)

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: blurB)
            blit.endEncoding()
        }

        let reachInTexels = Float(style.blurRadius) / Float(Self.blurDownsample)
        let maxLOD = log2(max(reachInTexels, 1))
        let lod = maxLOD * softAmount

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = panelTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = FoldUniforms(
            fold: foldAmount,
            perspective: Float(style.perspective),
            darkening: Float(style.darkening),
            shadowStrength: Float(style.shadowStrength),
            sheen: Float(style.sheen),
            curvature: Float(style.curvature),
            blurMix: min(softAmount * 2.5, 1.0),
            blurLOD: lod,
            vignette: Float(style.vignette),
            edgeSoftness: Float(style.edgeSoftness),
            cornerRadius: Float(style.cornerRadius),
            aspect: Float(size.width / max(size.height, 1))
        )
        var panel = Self.panelTransform(fold: foldAmount, perspective: Float(style.perspective))
        encoder.setRenderPipelineState(foldPipeline)
        encoder.setVertexBuffer(gridBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 1)
        encoder.setVertexBytes(&panel, length: MemoryLayout<simd_float3x3>.stride, index: 2)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(blurB, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: gridVertexCount)
        encoder.endEncoding()

        if let bleedBlit = commandBuffer.makeBlitCommandEncoder() {
            bleedBlit.generateMipmaps(for: panelTexture)
            bleedBlit.endEncoding()
        }

        let composite = MTLRenderPassDescriptor()
        composite.colorAttachments[0].texture = target
        composite.colorAttachments[0].loadAction = .clear
        composite.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        composite.colorAttachments[0].storeAction = .store
        if let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: composite) {
            let bleedFraction = min(Float(style.edgeSoftness) * 1.35, 0.13)
                * pow(foldAmount, 0.55)
            let bleedPixels = Float(size.width) * bleedFraction
            var bleedLOD = bleedPixels > 1 ? log2(bleedPixels) : 0
            compositeEncoder.setRenderPipelineState(compositePipeline)
            compositeEncoder.setFragmentTexture(panelTexture, index: 0)
            compositeEncoder.setFragmentBytes(&bleedLOD, length: MemoryLayout<Float>.stride, index: 0)
            compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            compositeEncoder.endEncoding()
        }

        finish(commandBuffer)
        if commandBuffer.status == .notEnqueued {
            commandBuffer.commit()
        }
    }

    /// Where the desktop sits on screen for a given fold, as a homography from
    /// the content square to screen space (both 0–1, y up from the hinge).
    ///
    /// The desktop stays upright and lit while it settles: it keeps the full
    /// height of the lid and narrows toward a centred panel, and mid-fold its
    /// top edge pulls in further than the bottom, so it seems to hold still
    /// facing you while the lid tips forward. `perspective` scales that
    /// keystone; at fold 0 the transform is the identity.
    static func panelTransform(fold: Float, perspective: Float) -> simd_float3x3 {
        let f = min(max(fold, 0), 1)
        let keystone = min(max(perspective, 0), 2) * 0.17 * sin(.pi * f)
        let bottom = 1 - 0.36 * f
        let top = bottom - keystone
        let lift = 0.02 * f
        return squareToQuad(
            SIMD2(0.5 - bottom / 2, lift), SIMD2(0.5 + bottom / 2, lift),
            SIMD2(0.5 + top / 2, 1 - lift), SIMD2(0.5 - top / 2, 1 - lift)
        )
    }

    /// Heckbert's unit-square-to-quad projective map. Corners in order:
    /// (0,0), (1,0), (1,1), (0,1).
    private static func squareToQuad(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>,
                                     _ p2: SIMD2<Float>, _ p3: SIMD2<Float>) -> simd_float3x3 {
        let d1 = p1 - p2, d2 = p3 - p2, d3 = p0 - p1 + p2 - p3
        let denominator = d1.x * d2.y - d2.x * d1.y
        let g = (d3.x * d2.y - d2.x * d3.y) / denominator
        let h = (d1.x * d3.y - d3.x * d1.y) / denominator
        return simd_float3x3(rows: [
            SIMD3(p1.x - p0.x + g * p1.x, p3.x - p0.x + h * p3.x, p0.x),
            SIMD3(p1.y - p0.y + g * p1.y, p3.y - p0.y + h * p3.y, p0.y),
            SIMD3(g, h, 1),
        ])
    }

    private func blurPass(commandBuffer: MTLCommandBuffer, from source: MTLTexture,
                          to destination: MTLTexture, step: SIMD2<Float>, radius: Float) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = BlurUniforms(texelStep: step, radius: max(radius, 0.001))
        encoder.setRenderPipelineState(blurPipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    enum RendererError: LocalizedError {
        case noCommandQueue, noBuffer
        var errorDescription: String? {
            switch self {
            case .noCommandQueue: return "Could not create a Metal command queue."
            case .noBuffer: return "Could not allocate the panel mesh."
            }
        }
    }
}
