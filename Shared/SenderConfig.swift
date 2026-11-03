// SenderConfig.swift
// 主 App 与 Broadcast Extension 之间的共享配置（App Group UserDefaults）
import Foundation
import CoreGraphics

/// App Group 标识。必须与两个 target 的 entitlements 完全一致。
public enum AppGroupID {
    public static let id = "group.com.yourname.ndisender"
}

/// 传输方式
public enum Transport: String, CaseIterable, Identifiable, Codable {
    case ndi = "NDI（需开发者账号）"
    case udp = "UDP 直连（免账号，推荐）"
    public var id: String { rawValue }
}

/// 裁剪方式
public enum CropMode: String, CaseIterable, Identifiable, Codable {
    /// 按屏幕比例裁剪（四条边距滑块）
    case ratio = "按比例"
    /// 直接指定像素尺寸，以屏幕中心为基准
    case pixels = "按尺寸"
    public var id: String { rawValue }
}

/// 输出分辨率预设
public enum OutputPreset: String, CaseIterable, Identifiable, Codable {
    case followCrop = "跟随裁剪"
    case p540 = "960 × 540"
    case p720 = "1280 × 720"
    case p810 = "1440 × 810"
    case p1080 = "1920 × 1080"

    public var id: String { rawValue }

    public var size: (width: Int, height: Int) {
        switch self {
        case .followCrop: return (0, 0)
        case .p540:       return (960, 540)
        case .p720:       return (1280, 720)
        case .p810:       return (1440, 810)
        case .p1080:      return (1920, 1080)
        }
    }
}

/// 发送端配置
public struct SenderConfig: Codable, Equatable {

    public var transport: Transport
    public var ndiName: String
    public var udpHost: String
    public var udpPort: Int
    public var bitrateKbps: Int

    /// 裁剪方式
    public var cropMode: CropMode
    /// 比例模式下的裁剪矩形（归一化 0...1，原点左上）
    public var cropRect: CGRect
    /// 尺寸模式下的裁剪宽高（像素），以屏幕中心为基准
    public var customWidth: Int
    public var customHeight: Int

    public var outputPreset: OutputPreset
    public var maxFPS: Int
    public var sendAudio: Bool

    public static let `default` = SenderConfig(
        transport: .udp,
        ndiName: "iOS Screen",
        udpHost: "192.168.1.100",
        udpPort: 47777,
        bitrateKbps: 8000,
        cropMode: .pixels,
        cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
        customWidth: 960,
        customHeight: 540,
        outputPreset: .followCrop,
        maxFPS: 60,
        sendAudio: false
    )

    public init(transport: Transport,
                ndiName: String,
                udpHost: String,
                udpPort: Int,
                bitrateKbps: Int,
                cropMode: CropMode,
                cropRect: CGRect,
                customWidth: Int,
                customHeight: Int,
                outputPreset: OutputPreset,
                maxFPS: Int,
                sendAudio: Bool) {
        self.transport = transport
        self.ndiName = ndiName
        self.udpHost = udpHost
        self.udpPort = udpPort
        self.bitrateKbps = bitrateKbps
        self.cropMode = cropMode
        self.cropRect = cropRect
        self.customWidth = customWidth
        self.customHeight = customHeight
        self.outputPreset = outputPreset
        self.maxFPS = maxFPS
        self.sendAudio = sendAudio
    }

    /// 计算出实际要抓取的像素区域
    /// - 尺寸模式：以屏幕中心为基准，按 customWidth/customHeight 取矩形
    /// - 比例模式：按 cropRect 归一化换算
    /// 两种模式都会做边界夹取和 4 像素对齐
    public func sanitizedCropRect(forPixelSize size: CGSize) -> CGRect {
        let srcW = size.width
        let srcH = size.height
        guard srcW > 8, srcH > 8 else { return CGRect(origin: .zero, size: size) }

        var w: CGFloat
        var h: CGFloat
        var x: CGFloat
        var y: CGFloat

        if cropMode == .pixels {
            w = min(max(16, CGFloat(customWidth)), srcW)
            h = min(max(16, CGFloat(customHeight)), srcH)
            x = ((srcW - w) / 2).rounded()
            y = ((srcH - h) / 2).rounded()
        } else {
            var r = cropRect.standardized
            r.origin.x = max(0, min(r.origin.x, 1))
            r.origin.y = max(0, min(r.origin.y, 1))
            r.size.width = max(0.02, min(r.size.width, 1 - r.origin.x))
            r.size.height = max(0.02, min(r.size.height, 1 - r.origin.y))
            x = (r.origin.x * srcW).rounded()
            y = (r.origin.y * srcH).rounded()
            w = (r.size.width * srcW).rounded()
            h = (r.size.height * srcH).rounded()
        }

        // x / 宽度对齐到 4 像素（BGRA 每像素 4 字节）
        x = (x / 4).rounded(.down) * 4
        w = (w / 4).rounded(.down) * 4
        // 夹进画面内
        if x + w > srcW { w = ((srcW - x) / 4).rounded(.down) * 4 }
        if y + h > srcH { h = srcH - y }
        w = max(4, w)
        h = max(4, h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// 用于界面预览：给定屏幕像素尺寸，返回归一化裁剪矩形
    public func normalizedPreviewRect(forPixelSize size: CGSize) -> CGRect {
        let px = sanitizedCropRect(forPixelSize: size)
        guard size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: px.origin.x / size.width,
                      y: px.origin.y / size.height,
                      width: px.size.width / size.width,
                      height: px.size.height / size.height)
    }
}

/// 配置与运行时状态读写
public enum ConfigStore {

    /// 免费证书签名时 App Group 不可用，会退回到这里的编译期常量
    public enum Fallback {
        public static let config = SenderConfig.default
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupID.id)
    }

    private static let key = "sender.config.v3"

    public static func load() -> SenderConfig {
        guard let d = defaults else { return Fallback.config }
        guard let data = d.data(forKey: key),
              let cfg = try? JSONDecoder().decode(SenderConfig.self, from: data) else {
            return .default
        }
        return cfg
    }

    public static func save(_ config: SenderConfig) {
        guard let data = try? JSONEncoder().encode(config), let d = defaults else { return }
        d.set(data, forKey: key)
        d.synchronize()
    }

    public static var isAppGroupAvailable: Bool { defaults != nil }

    // MARK: - 广播状态（Extension 写，主 App 读）

    private static let broadcastingKey = "sender.broadcasting"

    public static var isBroadcasting: Bool {
        defaults?.bool(forKey: broadcastingKey) ?? false
    }

    public static func setBroadcasting(_ value: Bool) {
        guard let d = defaults else { return }
        d.set(value, forKey: broadcastingKey)
        d.synchronize()
    }

    // MARK: - 停止请求（主 App 写，Extension 读）

    private static let stopKey = "sender.stopRequested"

    public static func requestStop() {
        guard let d = defaults else { return }
        d.set(true, forKey: stopKey)
        d.synchronize()
    }

    public static var isStopRequested: Bool {
        defaults?.bool(forKey: stopKey) ?? false
    }

    public static func clearStopRequest() {
        guard let d = defaults else { return }
        d.set(false, forKey: stopKey)
        d.synchronize()
    }
}
