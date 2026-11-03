// BroadcastPicker.swift
// RPSystemBroadcastPickerView 是系统提供的「开始直播」入口，不能改文案，
// 所以这里把它藏起来，用自定义按钮触发它内部的 UIButton。
import SwiftUI
import ReplayKit

/// 广播扩展的 Bundle ID（与 project.yml 里的 target 保持一致）
enum BroadcastTarget {
    static var extensionBundleID: String {
        (Bundle.main.bundleIdentifier ?? "com.yourname.ndisender") + ".BroadcastExtension"
    }
}

/// 持有系统 Picker 并提供代码触发
final class PickerProxy {
    weak var view: UIView?

    func trigger() {
        guard let view = view else { return }
        Self.findButton(in: view)?.sendActions(for: .touchUpInside)
    }

    private static func findButton(in view: UIView) -> UIButton? {
        if let b = view as? UIButton { return b }
        for sub in view.subviews {
            if let b = findButton(in: sub) { return b }
        }
        return nil
    }
}

/// 不可见的 RPSystemBroadcastPickerView 宿主
struct PickerHost: UIViewRepresentable {
    let proxy: PickerProxy

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        container.backgroundColor = .clear

        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.preferredExtension = BroadcastTarget.extensionBundleID
        picker.showsMicrophoneButton = false
        picker.backgroundColor = .clear
        container.addSubview(picker)

        proxy.view = picker
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// 外观自定义、实际由系统 Picker 响应的「开始」按钮
struct BroadcastStartButton: View {
    @State private var proxy = PickerProxy()

    var body: some View {
        ZStack {
            PickerHost(proxy: proxy)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)

            Button {
                proxy.trigger()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("开始 NDI 投屏")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}
