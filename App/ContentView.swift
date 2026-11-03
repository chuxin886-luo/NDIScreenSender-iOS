// ContentView.swift
// 主界面：NDI 名称 / 输出分辨率 / 帧率 / 可视化裁剪。
// 所有改动即时写入 App Group，Broadcast Extension 在下一次开始时读取。
import SwiftUI

struct ContentView: View {

    @State private var config: SenderConfig = ConfigStore.load()
    @State private var showAdvanced = false

    private let fpsOptions = [30, 60, 90, 120]

    var body: some View {
        NavigationView {
            Form {
                transportSection
                if config.transport == .ndi {
                    ndiSection
                } else {
                    udpSection
                }
                outputSection
                cropSection
                startSection
                infoSection
            }
            .navigationTitle("NDI 投屏")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: config) { newValue in
                ConfigStore.save(newValue)
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 传输方式

    private var transportSection: some View {
        Section {
            Picker("传输方式", selection: $config.transport) {
                ForEach(Transport.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("传输方式")
        } footer: {
            if config.transport == .udp {
                Text("H.264 硬编 + 裸 UDP 单播。不需要开发者账号和任何 entitlement，免费签名即可。电脑端跑 bridge/ndi_bridge.py 转成 NDI。")
            } else {
                Text("标准 NDI。需要 com.apple.developer.networking.multicast（付费开发者账号 + Apple 审批），免费签名用不了。")
            }
        }
    }

    private var udpSection: some View {
        Section {
            HStack {
                Text("电脑 IP")
                Spacer()
                TextField("192.168.1.100", text: $config.udpHost)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            HStack {
                Text("端口")
                Spacer()
                TextField("47777", value: $config.udpPort, format: .number)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.numberPad)
            }
            Picker("码率", selection: $config.bitrateKbps) {
                Text("4 Mbps（省电）").tag(4000)
                Text("8 Mbps（推荐）").tag(8000)
                Text("12 Mbps").tag(12000)
                Text("16 Mbps").tag(16000)
                Text("24 Mbps（高画质）").tag(24000)
            }
        } header: {
            Text("UDP 直连")
        } footer: {
            Text("IP 填跑 ndi_bridge.py 的那台电脑。手机和电脑要在同一网段（网线直连交换机或同一 WiFi）。")
        }
    }

    // MARK: - NDI

    private var ndiSection: some View {
        Section {
            HStack {
                Text("源名称")
                Spacer()
                TextField("iOS Screen", text: $config.ndiName)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        } header: {
            Text("NDI")
        } footer: {
            Text("接收端（Nixsense / NDI Studio Monitor 等）按这个名字找到你。改成好认的名字，避免同网段重名。")
        }
    }

    // MARK: - 输出

    private var outputSection: some View {
        Section {
            Picker("输出分辨率", selection: $config.outputPreset) {
                ForEach(OutputPreset.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }

            Picker("帧率上限", selection: $config.maxFPS) {
                ForEach(fpsOptions, id: \.self) { f in
                    Text("\(f) fps").tag(f)
                }
            }

            Toggle("发送音频", isOn: $config.sendAudio)
        } header: {
            Text("输出")
        } footer: {
            Text("帧率是硬上限：超出的帧会被直接丢弃，不会排队（排队 = 延迟）。投屏游戏建议 60；追求最低延迟就用「跟随裁剪」+ 60 fps。")
        }
    }

    // MARK: - 裁剪

    private var cropSection: some View {
        Section {
            CropPreview(rect: config.cropRect)
                .frame(height: 180)
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))

            percentSlider("左边距", value: $config.cropRect.origin.x, range: 0...0.9)
            percentSlider("上边距", value: $config.cropRect.origin.y, range: 0...0.9)
            percentSlider("宽度",   value: $config.cropRect.size.width, range: 0.1...1.0)
            percentSlider("高度",   value: $config.cropRect.size.height, range: 0.1...1.0)

            HStack(spacing: 10) {
                quickButton("全屏") {
                    config.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                }
                quickButton("居中 16:9") {
                    let w: CGFloat = 1.0
                    let h: CGFloat = min(1.0, 9.0 / 16.0)
                    config.cropRect = CGRect(x: 0, y: (1 - h) / 2, width: w, height: h)
                }
                quickButton("上半屏") {
                    config.cropRect = CGRect(x: 0, y: 0, width: 1, height: 0.5)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        } header: {
            Text("裁剪")
        } footer: {
            Text("归一化比例，跟随屏幕方向自动换算。裁剪越小 → 编码越快 → 延迟越低，这是压延迟最有效的一步。")
        }
    }

    private func percentSlider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: 0.01)
        }
        .padding(.vertical, 2)
    }

    private func quickButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 开始

    private var startSection: some View {
        Section {
            BroadcastStartButton()
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("点上面按钮 → 系统弹窗里选中「NDI 投屏」→ 开始直播。之后切到任何 App / 游戏都会持续发送。")
                Text("停止：回到本 App 点停止，或在控制中心停止录屏。")
            }
        }
    }

    // MARK: - 信息

    private var infoSection: some View {
        Section {
            DisclosureGroup("部署与限制", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    line("架构", "ReplayKit 录屏 → vImage 裁剪缩放 → H.264+UDP / NDI")
                    line("延迟", "≈ 30–75 ms（ReplayKit 跨进程占 16–50 ms）")
                    line("App Group",
                         ConfigStore.isAppGroupAvailable
                         ? "✅ 可用，界面设置生效"
                         : "❌ 不可用，读 Fallback 配置")
                    line("要求", "iOS 15+ / arm64")
                    Text("""
                    App Group 显示「不可用」说明当前签名方式没有带 App Groups 能力，\
                    界面上的参数传不进录屏扩展。此时改 Shared/SenderConfig.swift 里的 \
                    Fallback.config，重新编译即可。

                    NDI 模式还需要 com.apple.developer.networking.multicast，\
                    没有的话只能用 UDP 模式（搭配电脑端 ndi_bridge.py）。
                    """)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("关于")
        }
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.footnote).foregroundColor(.secondary).frame(width: 66, alignment: .leading)
            Text(v).font(.footnote)
        }
    }
}

// MARK: - 裁剪预览

struct CropPreview: View {
    let rect: CGRect

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))

                // 屏幕示意
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)

                // 裁剪框
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: max(2, rect.width * w), height: max(2, rect.height * h))
                    .overlay(
                        Rectangle().stroke(Color.accentColor, lineWidth: 2)
                    )
                    .position(x: (rect.origin.x + rect.width / 2) * w,
                              y: (rect.origin.y + rect.height / 2) * h)

                VStack {
                    HStack {
                        Text("\(Int((rect.width * 100).rounded()))% × \(Int((rect.height * 100).rounded()))%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
