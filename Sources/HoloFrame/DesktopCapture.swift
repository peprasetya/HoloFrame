//
//  DesktopCapture.swift — the canvas, as a Metal texture.
//
//  The whole performance argument for HoloFrame rests on this file staying zero-copy:
//  ScreenCaptureKit hands out IOSurface-backed CVPixelBuffers, and CVMetalTextureCache
//  wraps one as an MTLTexture without the pixels ever touching the CPU. A 7680x2160
//  canvas is 66 MB a frame; moving that through CPU memory would sink an Intel Mac.
//
//  The other half of the argument is that ScreenCaptureKit only delivers a frame when the
//  content actually changes. Turning your head does not dirty the desktop, so panning
//  costs one textured draw against a texture that is already resident — not a recapture.
//

import CoreVideo
import Foundation
import Metal
import ScreenCaptureKit

final class DesktopCapture: NSObject, SCStreamOutput {

    enum CaptureError: Error, CustomStringConvertible {
        case displayNotFound(CGDirectDisplayID)
        case textureCacheFailed(CVReturn)
        case permissionDenied

        var description: String {
            switch self {
            case .displayNotFound(let id):
                return "Display \(id) is not in ScreenCaptureKit's shareable content."
            case .textureCacheFailed(let r):
                return "CVMetalTextureCacheCreate failed (\(r))."
            case .permissionDenied:
                return """
                Screen Recording permission is required.
                Grant it in System Settings > Privacy & Security > Screen Recording,
                then run HoloFrame again.
                """
            }
        }
    }

    private let device: MTLDevice
    private let textureCache: CVMetalTextureCache
    private var stream: SCStream?

    /// Retained because the CVMetalTexture must outlive the MTLTexture derived from it.
    private var currentTexture: CVMetalTexture?
    private var latest: MTLTexture?
    private let lock = NSLock()

    private(set) var frameCount = 0

    init(device: MTLDevice) throws {
        self.device = device
        var cache: CVMetalTextureCache?
        let r = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard r == kCVReturnSuccess, let cache else { throw CaptureError.textureCacheFailed(r) }
        self.textureCache = cache
        super.init()
    }

    /// Most recently captured frame, or nil before the first one arrives.
    var texture: MTLTexture? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func start(displayID: CGDirectDisplayID) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                          onScreenWindowsOnly: false)
        } catch {
            // SCK reports a missing TCC grant as a generic failure; this is by far the
            // most likely cause on a first run.
            throw CaptureError.permissionDenied
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 3
        // Cap the delivery rate; the display is 60 Hz and there is nothing to gain above
        // it. SCK still only sends frames when something actually changed.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "id.prasetya.holoframe.capture",
                                                                     qos: .userInteractive))
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        stream?.stopCapture(completionHandler: { _ in })
        stream = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // SCK marks frames whose content did not change; skip them rather than re-wrapping.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard r == kCVReturnSuccess, let cvTexture,
              let metalTexture = CVMetalTextureGetTexture(cvTexture) else { return }

        lock.lock()
        currentTexture = cvTexture      // keep alive alongside the MTLTexture
        latest = metalTexture
        frameCount += 1
        lock.unlock()
    }
}
