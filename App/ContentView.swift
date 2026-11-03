// ContentView.swift
// 「一个木函」那种简约工具风：
//   · 浅灰底 + 白色大圆角卡片 + 彩色小图标
//   · spring 弹性动画（不生硬）
//   · 宽屏自动切双列（iPad 横屏 / 大屏）
//   · 适配 120Hz ProMotion（配合 Info.plist 的 CADisableMinimumFrameDurationOnPhone）
import SwiftUI

// MARK: - 主题

struct Theme {
    let scheme: ColorScheme

    var isDark: Bool { scheme == .dark }

    var bg: Color {
        isDark ? Color(red: 0.07, green: 0.07, blue: 0.08)
               : Color(red: 0.96, green: 0.96, blue: 0.97)
    }
    var card: Color {
        isDark ? Color(red: 0.12, green: 0.12, blue: 0.13)
               : Color.white
    }
    var accent: Color {
        isDark ? Color(red: 0.35, green: 0.61, blue: 1.0)
               : Color(red: 0.16, green: 0.42, blue: 0.94)
    }
    var accentSoft: Color {
        accent.opacity(isDark ? 0.18 : 0.10)
    }
    var hairline: Color {
        Color(uiColor: .separator).opacity(0.45)
    }
    var field: Color {
        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.035)
    }
    var shadow: Color {
        Color.black.opacity(isDark ? 0.0 : 0.05)
    }
    var success: Color {
        isDark ? Color(red: 0.32, green: 0.84, blue: 0.58)
               : Color(red: 0.13, green: 0.63, blue: 0.36)
    }
    var warn: Color {
        isDark ? Color(red: 0.98, green: 0.74, blue: 0.31)
               : Color(red: 0.85, green: 0.54, blue: 0.05)
    }
    var iconBlue: Color   { Color(red: 0.16, green: 0.42, blue: 0.94) }
    var iconTeal: Color   { Color(red: 0.08, green: 0.62, blue: 0.66) }
    var iconOrange: Color { Color(red: 0.95, green: 0.52, blue: 0.16) }
    var iconGray: Color   { Color(red: 0.45, green: 0.47, blue: 0.52) }
}

// MARK: - 动画常量（统一节奏，避免各处生硬）
private enum Anim {
    /// 选择、切换这类主交互
    static let select = Animation.spring(response: 0.32, dampingFraction: 0.82)
    /// 展开/收起
    static let expand = Animation.spring(response: 0.38, dampingFraction: 0.86)
    /// 滑块这类连续拖动：轻微平滑，不加弹性（否则会跟手延迟）
    static let drag = Animation.interactiveSpring(response: 0.14, dampingFraction: 0.95)
}

// MARK: - 通用组件

struct Card<Content: View>: View {
    let t: Theme
    var title: String?
    var icon: String?
    var tint: Color?
    let content: Content

    init(t: Theme,
         title: String? = nil,
         icon: String? = nil,
         tint: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.t = t
        self.title = title
        self.icon = icon
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title = title {
                HStack(spacing: 10) {
                    if let icon = icon {
                        let c = tint ?? t.accent
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(c.opacity(t.isDark ? 0.22 : 0.13))
                                .frame(width: 27, height: 27)
                            Image(systemName: icon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(c)
                        }
                    }
                    Text(title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundColor(.primary)
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: t.shadow, radius: 12, x: 0, y: 4)
    }
}

struct DividerLine: View {
    let t: Theme
    var body: some View {
        Rectangle()
            .fill(t.hairline)
            .frame(height: 0.5)
    }
}

// MARK: - 主界面

struct ContentView: View {

    @Environment(\.colorScheme) private var scheme
    @State private var config: SenderConfig = ConfigStore.load()
    @State private var showAbout = false
    @State private var isBroadcasting = false
    @State private var pollTimer: Timer?
    @Namespace private var segNS

    private var t: Theme { Theme(scheme: scheme) }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 720

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    header(wide: wide)
                    statusBar
                    if wide {
                        HStack(alignment: .top, spacing: 18) {
                            VStack(spacing: 18) {
                                transportCard
                                outputCard
                            }
                            VStack(spacing: 18) {
                                cropCard
                                aboutCard
                            }
                        }
                    } else {
                        VStack(spacing: 18) {
                            transportCard
                            outputCard
                            cropCard
                            aboutCard
                        }
                    }
                    footer
                }
                .padding(.horizontal, wide ? 24 : 16)
                .padding(.top, wide ? 20 : 14)
                .padding(.bottom, 48)
                .frame(maxWidth: wide ? 1180 : .infinity)
                .frame(maxWidth: .infinity)
            }
            .background(t.bg.ignoresSafeArea())
        }
        .onChange(of: config) { newValue in
            ConfigStore.save(newValue)
        }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    // MARK: 广播状态轮询
    // Extension 在 App Group 里写 broadcasting 标志，主 App 每秒读一次。
    // 没有 App Group 时读不到，按钮会一直是「开始投屏」——这是签名限制，不是 bug。

    private func startPolling() {
        isBroadcasting = ConfigStore.isBroadcasting
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            let now = ConfigStore.isBroadcasting
            if now != isBroadcasting {
                withAnimation(Anim.select) { isBroadcasting = now }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func stopBroadcast() {
        ConfigStore.requestStop()
        // Extension 会在 0.5 秒内看到标志并自行结束；这里先乐观地改状态
        withAnimation(Anim.select) { isBroadcasting = false }
    }

    // MARK: 顶部

    private func header(wide: Bool) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NDI 投屏")
                    .font(.system(size: wide ? 32 : 28, weight: .bold))
                Text("把这块屏幕低延迟推送到局域网")
                    .font(.system(size: 13.5))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            if wide {
                Text(config.transport == .udp ? "UDP" : "NDI")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(t.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(t.accentSoft)
                    .clipShape(Capsule())
            }
        }
        .padding(.bottom, 2)
    }

    private var statusBar: some View {
        let ok = ConfigStore.isAppGroupAvailable
        let color = ok ? t.success : t.warn
        return HStack(spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(ok ? "配置可直接下发到录屏扩展" : "当前签名不支持配置下发，需改 Fallback")
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(color.opacity(scheme == .dark ? 0.13 : 0.075))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .animation(.easeOut(duration: 0.25), value: ok)
    }

    // MARK: 传输

    private var transportCard: some View {
        Card(t: t, title: "传输方式", icon: "antenna.radiowaves.left.and.right", tint: t.iconBlue) {
            VStack(spacing: 16) {
                segmented

                Text(config.transport == .udp
                     ? "H.264 硬编 + 裸 UDP 单播。不需要开发者账号，电脑端跑 ndi_bridge.py 转成 NDI。"
                     : "标准 NDI。需要 multicast entitlement（付费账号 + 审批），免费签名用不了。")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                BroadcastStartButton(accent: t.accent,
                                     isBroadcasting: isBroadcasting,
                                     onStop: stopBroadcast)

                Text(isBroadcasting
                     ? "正在投屏 · 手机上滑回本 App 可随时停止"
                     : "点上面的按钮 → 系统弹窗选「NDI 投屏」→ 开始")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var segmented: some View {
        HStack(spacing: 4) {
            segmentItem("UDP 直连", value: .udp)
            segmentItem("NDI", value: .ndi)
        }
        .padding(4)
        .background(t.field)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func segmentItem(_ title: String, value: Transport) -> some View {
        let selected = config.transport == value
        return ZStack {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(t.card)
                    .matchedGeometryEffect(id: "segment", in: segNS)
                    .shadow(color: Color.black.opacity(t.isDark ? 0.35 : 0.07),
                            radius: 3, x: 0, y: 1)
            }
            Text(title)
                .font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? t.accent : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !selected else { return }
            withAnimation(Anim.select) {
                config.transport = value
            }
        }
    }

    // MARK: 连接参数

    private var outputCard: some View {
        Card(t: t,
             title: config.transport == .udp ? "连接与画质" : "输出",
             icon: "slider.horizontal.3",
             tint: t.iconTeal) {
            VStack(spacing: 0) {
                if config.transport == .udp {
                    row("电脑 IP") {
                        TextField("192.168.1.100", text: $config.udpHost)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 14.5, design: .monospaced))
                    }
                    rowDivider
                    row("端口") {
                        TextField("47777", value: $config.udpPort, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 14.5, design: .monospaced))
                            .frame(maxWidth: 120)
                    }
                    rowDivider
                    row("码率") {
                        menuPicker(selection: $config.bitrateKbps) {
                            Text("4 Mbps").tag(4000)
                            Text("8 Mbps").tag(8000)
                            Text("12 Mbps").tag(12000)
                            Text("16 Mbps").tag(16000)
                            Text("24 Mbps").tag(24000)
                        }
                    }
                    rowDivider
                } else {
                    row("源名称") {
                        TextField("iOS Screen", text: $config.ndiName)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 14.5))
                    }
                    rowDivider
                }

                row("输出分辨率") {
                    menuPicker(selection: $config.outputPreset) {
                        ForEach(OutputPreset.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                }
                rowDivider

                row("帧率上限") {
                    menuPicker(selection: $config.maxFPS) {
                        ForEach([30, 60, 90, 120], id: \.self) { f in
                            Text("\(f) fps").tag(f)
                        }
                    }
                }
            }
        }
    }

    private var rowDivider: some View {
        DividerLine(t: t).padding(.vertical, 11)
    }

    private func row<V: View>(_ label: String, @ViewBuilder content: () -> V) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 14.5))
                .foregroundColor(.primary)
            Spacer(minLength: 8)
            content()
        }
    }

    private func menuPicker<S: Hashable, C: View>(selection: Binding<S>,
                                                  @ViewBuilder content: () -> C) -> some View {
        Picker("", selection: selection) { content() }
            .pickerStyle(.menu)
            .labelsHidden()
    }

    // MARK: 裁剪

    /// 屏幕物理像素尺寸（用于预览与像素模式换算）
    private var screenPixelSize: CGSize {
        let b = UIScreen.main.bounds
        let s = UIScreen.main.scale
        return CGSize(width: b.width * s, height: b.height * s)
    }

    private var previewRect: CGRect {
        config.normalizedPreviewRect(forPixelSize: screenPixelSize)
    }

    private var cropCard: some View {
        Card(t: t, title: "画面裁剪", icon: "crop", tint: t.iconOrange) {
            VStack(spacing: 16) {

                // 模式切换：按尺寸（居中） / 按比例
                HStack(spacing: 4) {
                    cropModeItem("按尺寸（居中）", .pixels)
                    cropModeItem("按比例", .ratio)
                }
                .padding(4)
                .background(t.field)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                CropPreview(rect: previewRect, t: t)
                    .frame(height: 156)
                    .animation(Anim.drag, value: previewRect)

                if config.cropMode == .pixels {
                    pixelSizeEditor
                } else {
                    VStack(spacing: 13) {
                        percentSlider("左边距", value: $config.cropRect.origin.x, range: 0...0.9)
                        percentSlider("上边距", value: $config.cropRect.origin.y, range: 0...0.9)
                        percentSlider("宽度", value: $config.cropRect.size.width, range: 0.1...1.0)
                        percentSlider("高度", value: $config.cropRect.size.height, range: 0.1...1.0)
                    }
                    HStack(spacing: 8) {
                        quickButton("全屏") {
                            animateCrop(CGRect(x: 0, y: 0, width: 1, height: 1))
                        }
                        quickButton("居中 16:9") {
                            let h: CGFloat = min(1.0, 9.0 / 16.0)
                            animateCrop(CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h))
                        }
                        quickButton("上半屏") {
                            animateCrop(CGRect(x: 0, y: 0, width: 1, height: 0.5))
                        }
                    }
                }

                Text(config.cropMode == .pixels
                     ? "以屏幕中心为基准取框，超出画面会自动夹取"
                     : "裁剪越小 → 编码越快 → 延迟越低")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func cropModeItem(_ title: String, _ mode: CropMode) -> some View {
        let selected = config.cropMode == mode
        return ZStack {
            if selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(t.card)
                    .matchedGeometryEffect(id: "cropMode", in: segNS)
                    .shadow(color: Color.black.opacity(t.isDark ? 0.30 : 0.07),
                            radius: 2, x: 0, y: 1)
            }
            Text(title)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? t.accent : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !selected else { return }
            withAnimation(Anim.select) { config.cropMode = mode }
        }
    }

    private var pixelSizeEditor: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                numberField("宽", value: $config.customWidth)
                Text("×")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
                numberField("高", value: $config.customHeight)
            }

            HStack(spacing: 8) {
                quickButton("960×540") { setCustomSize(960, 540) }
                quickButton("1280×720") { setCustomSize(1280, 720) }
                quickButton("全屏") {
                    let s = screenPixelSize
                    setCustomSize(Int(s.width), Int(s.height))
                }
            }
        }
    }

    private func numberField(_ label: String, value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            TextField("0", value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(t.field)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(maxWidth: 110)
        }
    }

    private func setCustomSize(_ w: Int, _ h: Int) {
        withAnimation(Anim.expand) {
            config.customWidth = max(16, w)
            config.customHeight = max(16, h)
        }
    }

    private func animateCrop(_ rect: CGRect) {
        withAnimation(Anim.expand) {
            config.cropRect = rect
        }
    }

    private func percentSlider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(t.accent)
            }
            Slider(value: value, in: range, step: 0.01)
                .tint(t.accent)
        }
    }

    private func quickButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(t.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(t.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: 关于

    private var aboutCard: some View {
        Card(t: t) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(Anim.expand) { showAbout.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(t.iconGray.opacity(t.isDark ? 0.22 : 0.13))
                                .frame(width: 27, height: 27)
                            Image(systemName: "info.circle")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(t.iconGray)
                        }
                        Text("部署与限制")
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .rotationEffect(.degrees(showAbout ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showAbout {
                    VStack(alignment: .leading, spacing: 11) {
                        DividerLine(t: t).padding(.vertical, 13)

                        infoLine("架构", "ReplayKit 录屏 → vImage 裁剪缩放 → H.264+UDP / NDI")
                        infoLine("延迟", "≈ 30–75 ms，其中 ReplayKit 跨进程占 16–50 ms")
                        infoLine("配置",
                                 ConfigStore.isAppGroupAvailable
                                 ? "App Group 可用，界面设置生效"
                                 : "App Group 不可用，读 Fallback 配置")
                        infoLine("刷新", "已解锁 ProMotion，120Hz 设备满帧渲染")
                        infoLine("要求", "iOS 15+ / arm64")

                        Text("若 App Group 不可用，改 Shared/SenderConfig.swift 的 Fallback.config 后重新编译。NDI 模式还需 com.apple.developer.networking.multicast。")
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
                }
            }
        }
    }

    private func infoLine(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(k)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 46, alignment: .leading)
            Text(v)
                .font(.system(size: 12))
                .foregroundColor(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        Text("v1.0 · \(config.transport == .udp ? "UDP 直连" : "NDI") 模式")
            .font(.system(size: 11))
            .foregroundColor(.secondary.opacity(0.7))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }
}

// MARK: - 裁剪预览

struct CropPreview: View {
    let rect: CGRect
    let t: Theme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let inset: CGFloat = 10
            let iw = max(1, w - inset * 2)
            let ih = max(1, h - inset * 2)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(t.field)

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(t.hairline, lineWidth: 1)
                    .padding(inset)

                Path { p in
                    p.move(to: CGPoint(x: w / 2, y: inset))
                    p.addLine(to: CGPoint(x: w / 2, y: h - inset))
                    p.move(to: CGPoint(x: inset, y: h / 2))
                    p.addLine(to: CGPoint(x: w - inset, y: h / 2))
                }
                .stroke(t.hairline.opacity(0.55), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

                Rectangle()
                    .fill(t.accent.opacity(0.10))
                    .overlay(Rectangle().stroke(t.accent, lineWidth: 1.5))
                    .frame(width: max(2, rect.width * iw),
                           height: max(2, rect.height * ih))
                    .position(x: inset + (rect.origin.x + rect.width / 2) * iw,
                              y: inset + (rect.origin.y + rect.height / 2) * ih)

                VStack {
                    HStack {
                        Spacer()
                        Text("\(Int((rect.width * 100).rounded()))% × \(Int((rect.height * 100).rounded()))%")
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(t.card.opacity(0.9))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    Spacer()
                }
                .padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ContentView().preferredColorScheme(.light)
            ContentView().preferredColorScheme(.dark)
            ContentView()
                .previewLayout(.fixed(width: 1024, height: 768))
                .preferredColorScheme(.light)
        }
    }
}
