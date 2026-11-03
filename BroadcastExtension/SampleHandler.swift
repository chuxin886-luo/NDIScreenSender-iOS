// SampleHandler.swift
// ReplayKit 系统录屏的接收端。两种传输方式：
//
//   NDI 模式：vImage 裁剪缩放 → 裸 BGRA 指针 → NDI 异步发送
//             （需要 com.apple.developer.networking.multicast，即付费开发者账号）
//
//   UDP 模式：vImage 裁剪缩放 → CVPixelBuffer → VideoToolbox H.264 硬编 → UDP 分片发送
//             （不需要任何 entitlement，免费签名可用；电脑端跑 ndi_bridge.py 转成 NDI）
//
// 两条路的共同点：都不排队。处理不过来就丢帧，宁可掉帧也不加延迟。
import ReplayKit
import CoreMedia
import CoreVideo
import QuartzCore

class SampleHandler: RPBroadcastSampleHandler {

    private var config: SenderConfig = .default
    private var scaler = FrameScaler()

    // NDI 路径
    #if NDI_ENABLED
    private var ndiSender: NDISender?
    #endif

    // UDP 路径
    private var encoder: H264Encoder?
    private var streamer: UDPStreamer?

    private var sourceSize: CGSize = .zero
    private var cropPixelRect: CGRect = .zero

    private var minFrameInterval: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0

    private var setupFailed = false
    private var frameCount = 0
    private var skipped = 0

    // MARK: - 生命周期

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        config = ConfigStore.load()
        minFrameInterval = config.maxFPS > 0 ? 1.0 / Double(config.maxFPS) : 0
        lastFrameTime = 0
        setupFailed = false
        frameCount = 0
        skipped = 0

        NSLog("[NDI-BC] start transport=%@ preset=%@ fps=%d crop=%@ udp=%@:%d",
              config.transport.rawValue,
              config.outputPreset.rawValue,
              config.maxFPS,
              NSCoder.string(for: config.cropRect),
              config.udpHost,
              config.udpPort)
    }

    override func broadcastPaused() {
        lastFrameTime = 0
    }

    override func broadcastResumed() {
        lastFrameTime = 0
        encoder?.requestKeyframe()
    }

    override func broadcastFinished() {
        NSLog("[NDI-BC] finish frames=%d skipped=%d", frameCount, skipped)
        teardown()
    }

    private func teardown() {
        #if NDI_ENABLED
        ndiSender?.destroy()
        ndiSender = nil
        #endif
        encoder?.invalidate()
        encoder = nil
        streamer = nil
    }

    // MARK: - 帧处理

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {

        guard sampleBufferType == .video else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // ① 帧率闸门：超出的帧直接丢，不排队
        if minFrameInterval > 0 {
            let now = CACurrentMediaTime()
            if lastFrameTime > 0, now - lastFrameTime < minFrameInterval {
                skipped += 1
                return
            }
            lastFrameTime = now
        }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return }

        // ② 首次 / 方向变化时重建
        if setupFailed == false {
            #if NDI_ENABLED
            let transportReady = (ndiSender != nil || encoder != nil)
            #else
            let transportReady = (encoder != nil)
            #endif
            let needRebuild = !transportReady
                || sourceSize.width != CGFloat(w)
                || sourceSize.height != CGFloat(h)
            if needRebuild {
                rebuild(sourceWidth: w, sourceHeight: h)
            }
        }

        switch config.transport {
        case .ndi:
            #if NDI_ENABLED
            routeNDI(pixelBuffer: pixelBuffer)
            #endif
        case .udp:
            routeUDP(pixelBuffer: pixelBuffer,
                     pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }

        frameCount += 1
        if frameCount % 120 == 0 {
            #if NDI_ENABLED
            let extra = ndiSender.map { "conns=\($0.connectionCount)" } ?? "udp"
            #else
            let extra = "udp"
            #endif
            NSLog("[NDI-BC] frames=%d skipped=%d %@", frameCount, skipped, extra)
        }
    }

    // MARK: - NDI 路径

    #if NDI_ENABLED
    private func routeNDI(pixelBuffer: CVPixelBuffer) {
        guard let sender = ndiSender else { return }
        let preset = config.outputPreset.size

        guard let frame = scaler.cropAndScale(pixelBuffer: pixelBuffer,
                                              cropPixelRect: cropPixelRect,
                                              outWidth: preset.width,
                                              outHeight: preset.height) else { return }

        sender.send(pixels: frame.ptr,
                    width: frame.width,
                    height: frame.height,
                    rowBytes: frame.rowBytes,
                    fps: config.maxFPS)
    }
    #endif

    // MARK: - UDP 路径

    private func routeUDP(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let encoder = encoder else { return }
        let preset = config.outputPreset.size

        guard let out = scaler.cropAndScaleToPixelBuffer(pixelBuffer: pixelBuffer,
                                                         cropPixelRect: cropPixelRect,
                                                         outWidth: preset.width,
                                                         outHeight: preset.height) else { return }

        encoder.encode(pixelBuffer: out, pts: pts)
    }

    // MARK: - 重建

    private func rebuild(sourceWidth: Int, sourceHeight: Int) {
        teardown()

        sourceSize = CGSize(width: sourceWidth, height: sourceHeight)
        cropPixelRect = config.sanitizedCropRect(forPixelSize: sourceSize)

        let preset = config.outputPreset.size
        let outW = preset.width > 0 ? preset.width : Int(cropPixelRect.width)
        let outH = preset.height > 0 ? preset.height : Int(cropPixelRect.height)
        scaler.prepare(width: outW, height: outH)

        switch config.transport {

        case .ndi:
            #if NDI_ENABLED
            if let s = NDISender(name: config.ndiName, fps: config.maxFPS) {
                ndiSender = s
                NSLog("[NDI-BC][NDI] %dx%d → %dx%d", sourceWidth, sourceHeight, outW, outH)
            } else {
                setupFailed = true
                NSLog("[NDI-BC][NDI] 创建失败：缺 com.apple.developer.networking.multicast？改走 UDP 模式")
            }
            #else
            setupFailed = true
            NSLog("[NDI-BC] 本次构建未启用 NDI（没有定义 NDI_ENABLED），请改用 UDP 模式")
            #endif

        case .udp:
            guard let port = UInt16(exactly: config.udpPort) else {
                setupFailed = true
                NSLog("[NDI-BC][UDP] 端口非法: %d", config.udpPort)
                return
            }
            guard let st = UDPStreamer(host: config.udpHost, port: port) else {
                setupFailed = true
                NSLog("[NDI-BC][UDP] 创建 socket 失败")
                return
            }
            self.streamer = st

            let enc = H264Encoder(width: outW,
                                  height: outH,
                                  fps: config.maxFPS,
                                  bitrate: max(500, config.bitrateKbps) * 1000) { [weak st] data, isKey in
                st?.send(frame: data, isKey: isKey)
            }
            guard let enc = enc else {
                setupFailed = true
                NSLog("[NDI-BC][UDP] H264 编码器创建失败")
                return
            }
            self.encoder = enc
            NSLog("[NDI-BC][UDP] %dx%d → %dx%d @%dkbps → %@:%d",
                  sourceWidth, sourceHeight, outW, outH,
                  config.bitrateKbps, config.udpHost, config.udpPort)
        }
    }
}
