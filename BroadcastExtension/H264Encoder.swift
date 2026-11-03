// H264Encoder.swift
// VideoToolbox 硬件 H.264 编码（低延迟配置）。
//
// 低延迟相关的三个关键设置：
//   1. AllowFrameReordering = false  → 禁用 B 帧，不产生重排序延迟
//   2. RealTime = true               → 编码器走实时模式，不做多帧前瞻
//   3. ProfileLevel = Baseline/High AutoLevel + 短 GOP → 关键帧间隔 ≤ 1~2 秒
//
// 输出：Annex-B（每个 NAL 前加 0x00000001），关键帧前自动附 SPS+PPS。
// 这样电脑端可以直接把每帧数据喂给解码器，不需要传 avcC。
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class H264Encoder {

    private var session: VTCompressionSession?
    private let width: Int
    private let height: Int
    private let fps: Int
    private var frameIndex: Int64 = 0
    private var forceKeyframe = true

    /// (annexB 数据, 是否关键帧)
    private let onEncoded: (Data, Bool) -> Void

    init?(width: Int, height: Int, fps: Int, bitrate: Int, onEncoded: @escaping (Data, Bool) -> Void) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
        self.fps = max(1, fps)
        self.onEncoded = onEncoded

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        var sessionOut: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: { refcon, _, status, _, sampleBuffer in
                guard status == noErr, let sb = sampleBuffer, let refcon = refcon else { return }
                Unmanaged<H264Encoder>.fromOpaque(refcon).takeUnretainedValue()
                    .handleEncodedFrame(sb)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &sessionOut
        )

        guard status == noErr, let session = sessionOut else {
            NSLog("[H264] VTCompressionSessionCreate failed: %d", status)
            return nil
        }
        self.session = session

        // ── 低延迟配置 ──
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AllowTemporalCompression, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: self.fps))
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: self.fps * 2))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2))
        // 每秒最多重排 0 帧；DataRateLimits 给编码器一个字节/秒的硬上限
        set(kVTCompressionPropertyKey_DataRateLimits,
            [NSNumber(value: bitrate / 8), NSNumber(value: 1)] as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(session)
        NSLog("[H264] encoder ready %dx%d @%dfps %d kbps", width, height, self.fps, bitrate / 1000)
    }

    deinit { invalidate() }

    private func set(_ key: CFString, _ value: CFTypeRef) {
        guard let session = session else { return }
        VTSessionSetProperty(session, key: key, value: value)
    }

    func invalidate() {
        if let session = session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }

    /// 请求下一帧强制关键帧（旋转/分辨率变化/重连时用）
    func requestKeyframe() {
        forceKeyframePending = true
    }

    // MARK: - 编码

    private var forceKeyframePending = true

    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session = session else { return }

        var frameProps: CFDictionary?
        if forceKeyframePending {
            forceKeyframePending = false
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        var flags: VTEncodeInfoFlags = []
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProps,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        if status != noErr {
            NSLog("[H264] encode failed: %d", status)
        }
        frameIndex += 1
    }

    // MARK: - 回调：AVCC → Annex-B

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // 是否关键帧（NotSync 取反）
        var isKey = false
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]],
           let first = attachments.first {
            let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            isKey = !notSync
        } else {
            isKey = true
        }

        // NAL 长度前缀字节数（VideoToolbox 默认 4）
        var nalLengthSize: Int32 = 4
        var paramCount = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: &nalLengthSize)

        var annexB = Data()
        annexB.reserveCapacity(64 * 1024)

        // 关键帧前补 SPS / PPS
        if isKey, paramCount > 0 {
            for i in 0..<paramCount {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i,
                    parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if st == noErr, let p = ptr, size > 0 {
                    annexB.append(contentsOf: [0, 0, 0, 1])
                    annexB.append(p, count: size)
                }
            }
        }

        var totalLength = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPtr) == noErr,
              let base = dataPtr else { return }

        let prefix = Int(nalLengthSize)
        var offset = 0
        while offset + prefix <= totalLength {
            var nalLen = 0
            if prefix == 4 {
                nalLen = Int(UInt32(bigEndian: base.advanced(by: offset)
                    .withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }))
            } else if prefix == 2 {
                nalLen = Int(UInt16(bigEndian: base.advanced(by: offset)
                    .withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee }))
            } else {
                nalLen = Int(base[offset])
            }
            offset += prefix
            guard nalLen > 0, offset + nalLen <= totalLength else { break }
            annexB.append(contentsOf: [0, 0, 0, 1])
            annexB.append(UnsafeRawPointer(base.advanced(by: offset)).assumingMemoryBound(to: UInt8.self),
                          count: nalLen)
            offset += nalLen
        }

        if !annexB.isEmpty {
            onEncoded(annexB, isKey)
        }
    }
}
