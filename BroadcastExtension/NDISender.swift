// NDISender.swift
// NDI 发送端封装。低延迟要点全部体现在这里的三个选择上：
//   1. clock_video = false —— 不让 NDI 自己按时间戳节流排队（这是最大的一笔延迟）
//   2. send_video_async_v2 —— 不阻塞 ReplayKit 的采集回调
//   3. 双缓冲轮转 —— 异步发送期间 NDI 仍在读上一帧，必须保证那块内存不被改写
//
// 只有定义 NDI_ENABLED 编译标志时才会编进来（需要放置 NDI SDK）。
// 只想用 UDP 模式的话，在 project.yml 里去掉 NDI_ENABLED 即可，无需 SDK。
#if NDI_ENABLED

import Foundation
import CoreVideo

final class NDISender {

    private var instance: NDIlib_send_instance_t?
    private var namePtr: UnsafeMutablePointer<CChar>?
    private var currentFPS: Int32 = 60

    private(set) var outputWidth = 0
    private(set) var outputHeight = 0

    // MARK: - 生命周期

    /// - Parameters:
    ///   - name: NDI 源名称，接收端按此名称识别
    ///   - fps: 预期的实际发送帧率，用于告诉接收端做缓冲估算（不参与节流）
    init?(name: String, fps: Int) {
        guard NDIlib_initialize() else {
            NSLog("[NDI] initialize failed")
            return nil
        }

        // NDI 会复制这个名字，但保持指针存活更稳妥
        let cstr = strdup(name)
        namePtr = cstr
        currentFPS = Int32(max(1, fps))

        var desc = NDIlib_send_create_t()
        desc.p_ndi_name = UnsafePointer(cstr)
        desc.p_groups = nil
        // ★ 关键：关掉 NDI 自带的时钟节流，来一帧发一帧，延迟最低
        desc.clock_video = false
        desc.clock_audio = false

        // 显式声明为 Optional：C 头文件没有 nullability 标注时，
        // 不同 Swift 版本对指针返回值的导入结果不一致，这样写两种都能编译
        let sendRaw: NDIlib_send_instance_t? = NDIlib_send_create(&desc)
        guard let send = sendRaw else {
            NSLog("[NDI] send_create failed（多半是缺 com.apple.developer.networking.multicast）")
            free(cstr)
            namePtr = nil
            return nil
        }
        instance = send
        NSLog("[NDI] sender created: %@", name)
    }

    deinit { destroy() }

    func destroy() {
        if let send = instance {
            // 收尾：把异步队列里最后一帧冲出去
            NDIlib_send_send_video_async_v2(send, nil)
            NDIlib_send_destroy(send)
            instance = nil
        }
        if let p = namePtr {
            free(p)
            namePtr = nil
        }
    }

    // MARK: - 发送

    /// 发送一帧 BGRA 数据。
    /// - Parameters:
    ///   - pixels: BGRA8888 数据指针，在下次调用本方法前不得改写
    ///   - width: 像素宽
    ///   - height: 像素高
    ///   - rowBytes: 每行字节数（= width * 4，可能带对齐填充）
    ///   - fps: 当前实际帧率
    func send(pixels: UnsafeMutableRawPointer,
              width: Int,
              height: Int,
              rowBytes: Int,
              fps: Int) {

        guard let send = instance, width > 0, height > 0 else { return }

        outputWidth = width
        outputHeight = height
        if fps > 0 { currentFPS = Int32(fps) }

        var frame = NDIlib_video_frame_v2_t()
        frame.xres = Int32(width)
        frame.yres = Int32(height)
        frame.FourCC = NDIlib_FourCC_video_type_BGRA
        frame.frame_rate_N = currentFPS * 1000
        frame.frame_rate_D = 1000
        frame.picture_aspect_ratio = Float(width) / Float(height)
        frame.frame_format_type = NDIlib_frame_format_type_progressive
        frame.timecode = Int64(NDIlib_send_timecode_synthesize)
        frame.p_data = pixels.assumingMemoryBound(to: UInt8.self)
        frame.line_stride_in_bytes = Int32(rowBytes)
        frame.p_metadata = nil
        frame.timestamp = 0

        NDIlib_send_send_video_async_v2(send, &frame)
    }

    /// 已连接的接收端数量（用于状态显示）
    var connectionCount: Int {
        guard let send = instance else { return 0 }
        return Int(NDIlib_send_get_no_connections(send, 0))
    }
}

#endif // NDI_ENABLED
