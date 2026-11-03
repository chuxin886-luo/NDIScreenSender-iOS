// FrameScaler.swift
// 裁剪 + 缩放，全程走 Accelerate（vImage），零中间拷贝。
//
// 两种输出形态：
//   cropAndScale(...)              → 裸 BGRA 指针，给 NDI 用（NDI 直接吃裸内存）
//   cropAndScaleToPixelBuffer(...) → CVPixelBuffer，给 VideoToolbox 硬编用
import Foundation
import Accelerate
import CoreVideo

final class FrameScaler {

    /// 双缓冲：异步发送期间 NDI 还在读上一块，所以至少 2 块
    private let slotCount = 2
    private var slots: [UnsafeMutableRawPointer] = []
    private var writeIndex = 0

    private var dstWidth = 0
    private var dstHeight = 0
    private var dstRowBytes = 0

    /// VideoToolbox 路径用的输出缓冲池
    private var pool: CVPixelBufferPool?

    deinit {
        for p in slots { p.deallocate() }
    }

    var width: Int { dstWidth }
    var height: Int { dstHeight }

    // MARK: - 缓冲准备

    @discardableResult
    func prepare(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }

        if width != dstWidth || height != dstHeight || slots.isEmpty {
            for p in slots { p.deallocate() }
            slots.removeAll()

            dstWidth = width
            dstHeight = height
            dstRowBytes = width * 4

            let byteCount = dstRowBytes * height
            for _ in 0..<slotCount {
                let p = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
                slots.append(p)
            }
            writeIndex = 0
        }

        preparePool(width: width, height: height)
        return true
    }

    private func preparePool(width: Int, height: Int) {
        if let p = pool {
            let attrs = CVPixelBufferPoolGetPixelBufferAttributes(p) as? [String: Any]
            let w = attrs?[kCVPixelBufferWidthKey as String] as? Int
            let h = attrs?[kCVPixelBufferHeightKey as String] as? Int
            if w == width, h == height { return }
        }

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                             poolAttrs as CFDictionary, &newPool)
        if status == kCVReturnSuccess {
            pool = newPool
        } else {
            NSLog("[Scaler] pool create failed: %d", status)
            pool = nil
        }
    }

    // MARK: - 公共工具：把源像素缓冲里的裁剪区域渲染到目标内存

    private func render(src pixelBuffer: CVPixelBuffer,
                        crop cropPixelRect: CGRect,
                        dst: UnsafeMutableRawPointer,
                        dstW: Int,
                        dstH: Int,
                        dstRow: Int) -> Bool {

        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard srcWidth > 0, srcHeight > 0 else { return false }

        var crop = cropPixelRect.standardized
        crop.origin.x = max(0, min(crop.origin.x, CGFloat(srcWidth - 4)))
        crop.origin.y = max(0, min(crop.origin.y, CGFloat(srcHeight - 4)))
        crop.size.width = max(4, min(crop.size.width, CGFloat(srcWidth) - crop.origin.x))
        crop.size.height = max(4, min(crop.size.height, CGFloat(srcHeight) - crop.origin.y))

        let cw = Int(crop.size.width)
        let ch = Int(crop.size.height)
        let cx = Int(crop.origin.x)
        let cy = Int(crop.origin.y)

        guard kCVReturnSuccess == CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let srcPtr = base.advanced(by: cy * srcRowBytes + cx * 4)

        if cw == dstW && ch == dstH {
            // 尺寸相同：逐行 memcpy（比 vImage 缩放快）
            if srcRowBytes == dstRow {
                memcpy(dst, srcPtr, dstRow * ch)
            } else {
                for row in 0..<ch {
                    memcpy(dst.advanced(by: row * dstRow),
                           srcPtr.advanced(by: row * srcRowBytes),
                           dstRow)
                }
            }
        } else {
            var srcBuf = vImage_Buffer(data: srcPtr,
                                       height: vImagePixelCount(ch),
                                       width: vImagePixelCount(cw),
                                       rowBytes: srcRowBytes)
            var dstBuf = vImage_Buffer(data: dst,
                                       height: vImagePixelCount(dstH),
                                       width: vImagePixelCount(dstW),
                                       rowBytes: dstRow)
            let err = vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageNoFlags))
            if err != kvImageNoError {
                NSLog("[Scaler] vImageScale error %d", err)
                return false
            }
        }
        return true
    }

    // MARK: - NDI 路径：输出裸指针

    func cropAndScale(pixelBuffer: CVPixelBuffer,
                      cropPixelRect: CGRect,
                      outWidth: Int,
                      outHeight: Int) -> (ptr: UnsafeMutableRawPointer, width: Int, height: Int, rowBytes: Int)? {

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0 else { return nil }

        var crop = cropPixelRect.standardized
        let cw = Int(max(4, min(crop.size.width, CGFloat(srcW))))
        let ch = Int(max(4, min(crop.size.height, CGFloat(srcH))))
        let ow = outWidth > 0 ? outWidth : cw
        let oh = outHeight > 0 ? outHeight : ch

        guard prepare(width: ow, height: oh), !slots.isEmpty else { return nil }

        let dst = slots[writeIndex]
        writeIndex = (writeIndex + 1) % slots.count

        guard render(src: pixelBuffer, crop: crop, dst: dst, dstW: ow, dstH: oh, dstRow: dstRowBytes) else {
            return nil
        }
        return (dst, ow, oh, dstRowBytes)
    }

    // MARK: - 编码路径：输出 CVPixelBuffer

    func cropAndScaleToPixelBuffer(pixelBuffer: CVPixelBuffer,
                                   cropPixelRect: CGRect,
                                   outWidth: Int,
                                   outHeight: Int) -> CVPixelBuffer? {

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0 else { return nil }

        let cw = Int(max(4, min(cropPixelRect.width, CGFloat(srcW))))
        let ch = Int(max(4, min(cropPixelRect.height, CGFloat(srcH))))
        let ow = outWidth > 0 ? outWidth : cw
        let oh = outHeight > 0 ? outHeight : ch

        prepare(width: ow, height: oh)
        guard let pool = pool else { return nil }

        var outPB: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outPB) == kCVReturnSuccess,
              let out = outPB else { return nil }

        guard CVPixelBufferLockBaseAddress(out, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(out, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(out) else { return nil }
        let dstRow = CVPixelBufferGetBytesPerRow(out)

        guard render(src: pixelBuffer, crop: cropPixelRect, dst: dstBase,
                     dstW: CVPixelBufferGetWidth(out),
                     dstH: CVPixelBufferGetHeight(out),
                     dstRow: dstRow) else { return nil }

        return out
    }
}
