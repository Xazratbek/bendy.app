import Foundation
import ScreenCaptureKit
import CoreVideo
import Metal
import AppKit

final class CapturedFrame {
    let texture: MTLTexture
    private let cvTexture: CVMetalTexture
    private let pixelBuffer: CVPixelBuffer

    init(texture: MTLTexture, cvTexture: CVMetalTexture, pixelBuffer: CVPixelBuffer) {
        self.texture = texture
        self.cvTexture = cvTexture
        self.pixelBuffer = pixelBuffer
    }
}

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CapturedFrame) -> Void)?

    var onFailure: ((Error) -> Void)?

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.danielradosa.bendylocal.capture", qos: .userInteractive)
    private let stateLock = NSLock()
    private let deliveryLock = NSLock()
    private var generation: UInt64 = 0
    private var isRunning = false
    private var pendingFrame: CapturedFrame?
    private var isDeliveryScheduled = false

    init(device: MTLDevice) {
        self.device = device
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    func start(on displayID: CGDirectDisplayID, reducedQuality: Bool = false) async throws {
        let (token, previousStream): (UInt64, SCStream?) = withStateLock {
            generation &+= 1
            let token = generation
            let previous = stream
            stream = nil
            isRunning = false
            return (token, previous)
        }
        if let previousStream { try? await previousStream.stopCapture() }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let ourBundleID = Bundle.main.bundleIdentifier
        let ourApps = content.applications.filter { $0.bundleIdentifier == ourBundleID }
        let filter = SCContentFilter(
            display: display, excludingApplications: ourApps, exceptingWindows: []
        )

        // On battery, halving the pixel dimensions cuts the encode/blit/blur
        // cost roughly 4x, and 30fps is plenty for how slowly a lid actually
        // closes — the spring/render side still runs smoothly, this just
        // trims what ScreenCaptureKit has to produce every frame.
        let qualityDivisor = reducedQuality ? 2 : 1
        let frameRate: Int32 = reducedQuality ? 30 : 60

        let config = SCStreamConfiguration()
        config.width = display.width * Self.backingScale(for: displayID) / qualityDivisor
        config.height = display.height * Self.backingScale(for: displayID) / qualityDivisor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = Self.colorSpaceName(for: displayID)
        config.showsCursor = true
        config.capturesAudio = false
        config.queueDepth = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: frameRate)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()

        let accepted = withStateLock {
            guard generation == token else { return false }
            self.stream = stream
            isRunning = true
            return true
        }
        if !accepted { try? await stream.stopCapture() }
    }

    func stop() {
        let activeStream: SCStream? = withStateLock {
            generation &+= 1
            let active = stream
            stream = nil
            isRunning = false
            return active
        }
        guard let activeStream else { return }
        Task { try? await activeStream.stopCapture() }
    }

    static func colorSpaceName(for displayID: CGDirectDisplayID) -> CFString {
        guard let name = screen(for: displayID)?.colorSpace?.cgColorSpace?.name else {
            return CGColorSpace.sRGB
        }
        return name
    }

    static func colorSpace(for displayID: CGDirectDisplayID) -> CGColorSpace? {
        CGColorSpace(name: colorSpaceName(for: displayID))
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[.init("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    private static func backingScale(for displayID: CGDirectDisplayID) -> Int {
        Int(screen(for: displayID)?.backingScaleFactor ?? 2)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusValue = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusValue),
           status != .complete, status != .started {
            return
        }

        guard let pixelBuffer = sampleBuffer.imageBuffer,
              let frame = makeFrame(from: pixelBuffer) else { return }
        deliverNewest(frame)
    }

    private func makeFrame(from pixelBuffer: CVPixelBuffer) -> CapturedFrame? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }

        CVMetalTextureCacheFlush(cache, 0)

        return CapturedFrame(texture: texture, cvTexture: cvTexture, pixelBuffer: pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let isCurrent = withStateLock {
            guard self.stream === stream else { return false }
            generation &+= 1
            self.stream = nil
            isRunning = false
            return true
        }
        guard isCurrent else { return }
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error) }
    }

    private func deliverNewest(_ frame: CapturedFrame) {
        deliveryLock.lock()
        pendingFrame = frame
        guard !isDeliveryScheduled else {
            deliveryLock.unlock()
            return
        }
        isDeliveryScheduled = true
        deliveryLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.deliveryLock.lock()
            let newest = self.pendingFrame
            self.pendingFrame = nil
            self.isDeliveryScheduled = false
            self.deliveryLock.unlock()
            if let newest { self.onFrame?(newest) }
        }
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { "No capturable display was found." }
    }
}
