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
    /// 标准 NDI。需要 com.apple.developer.networking.multicast，即需要付费开发者账号
    case ndi = "NDI（需开发者账号）"
    /// 裸 UDP + H.264 硬编。不需要任何 entitlement，免费签名可用，电脑端跑桥接工具转成 NDI
    case udp = "UDP 直连（免账号，推荐）"

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

    /// 返回 (宽, 高)；followCrop 返回 (0, 0) 表示按裁剪尺寸原样输出
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

/// 发送端配置。所有字段都通过 App Group 在主 App 与 Extension 之间同步。
public struct SenderConfig: Codable, Equatable {

    /// 传输方式
    public var transport: Transport
    /// NDI 源名称（NDI 模式用）
    public var ndiName: String
    /// 电脑端桥接程序的 IP（UDP 模式用）
    public var udpHost: String
    /// 电脑端桥接程序的端口（UDP 模式用）
    public var udpPort: Int
    /// H.264 码率，kbps（UDP 模式用）
    public var bitrateKbps: Int
    /// 裁剪区域，归一化坐标 (0...1)，原点左上
    public var cropRect: CGRect
    /// 输出预设
    public var outputPreset: OutputPreset
    /// 帧率上限
    public var maxFPS: Int
    /// 是否发送音频（NDI 视频为主，默认关，降低延迟）
    public var sendAudio: Bool

    public static let `default` = SenderConfig(
        transport: .udp,
        ndiName: "iOS Screen",
        udpHost: "192.168.1.100",
        udpPort: 47777,
        bitrateKbps: 8000,
        cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
        outputPreset: .p540,
        maxFPS: 60,
        sendAudio: false
    )

    public init(transport: Transport,
                ndiName: String,
                udpHost: String,
                udpPort: Int,
                bitrateKbps: Int,
                cropRect: CGRect,
                outputPreset: OutputPreset,
                maxFPS: Int,
                sendAudio: Bool) {
        self.transport = transport
        self.ndiName = ndiName
        self.udpHost = udpHost
        self.udpPort = udpPort
        self.bitrateKbps = bitrateKbps
        self.cropRect = cropRect
        self.outputPreset = outputPreset
        self.maxFPS = maxFPS
        self.sendAudio = sendAudio
    }

    /// 归一化裁剪矩形修正：夹在 0...1 内，并对齐到 4 像素，保证 vImage 对齐与编码效率
    public func sanitizedCropRect(forPixelSize size: CGSize) -> CGRect {
        var r = cropRect.standardized
        r.origin.x = max(0, min(r.origin.x, 1))
        r.origin.y = max(0, min(r.origin.y, 1))
        r.size.width = max(0.02, min(r.size.width, 1 - r.origin.x))
        r.size.height = max(0.02, min(r.size.height, 1 - r.origin.y))

        var px = CGRect(
            x: (r.origin.x * size.width).rounded(),
            y: (r.origin.y * size.height).rounded(),
            width: (r.size.width * size.width).rounded(),
            height: (r.size.height * size.height).rounded()
        )
        // x 对齐到 4 像素（BGRA 每像素 4 字节）
        px.origin.x = (px.origin.x / 4).rounded(.down) * 4
        px.size.width = (px.size.width / 4).rounded(.down) * 4
        if px.origin.x + px.size.width > size.width {
            px.size.width = ((size.width - px.origin.x) / 4).rounded(.down) * 4
        }
        if px.origin.y + px.size.height > size.height {
            px.size.height = size.height - px.origin.y
        }
        px.size.width = max(4, px.size.width)
        px.size.height = max(4, px.size.height)
        return px
    }
}

/// 配置读写
public enum ConfigStore {

    /// 免费证书签名时 App Group 不可用，会退回到「编译期常量」。
    /// 那种情况下直接改这里的值，然后重新编译 Extension 即可。
    public enum Fallback {
        public static let config = SenderConfig.default
    }

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppGroupID.id)
    }

    private static let key = "sender.config.v2"

    public static func load() -> SenderConfig {
        guard let d = defaults else { return Fallback.config }
        guard let data = d.data(forKey: key),
              let cfg = try? JSONDecoder().decode(SenderConfig.self, from: data) else {
            return .default
        }
        return cfg
    }

    /// App Group 是否真的可用（主界面用来提示签名方式）
    public static var isAppGroupAvailable: Bool {
        defaults != nil
    }

    public static func save(_ config: SenderConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        guard let d = defaults else { return }
        d.set(data, forKey: key)
        d.synchronize()
    }
}
