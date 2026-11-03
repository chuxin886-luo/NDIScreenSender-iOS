# NDI 投屏（iOS / iPadOS）

把 iPhone / iPad 整个屏幕（含其它 App、游戏）低延迟投出去，画面可自由裁剪。

**两条互不影响的传输链路，按你有没有开发者账号选一条：**

| | UDP 直连模式 | NDI 模式 |
|---|---|---|
| 需要开发者账号 | **不需要** | 需要（付费账号 + Apple 审批 multicast） |
| 免费 Apple ID 签名 | **能用** | 用不了 |
| 手机端编码 | VideoToolbox 硬件 H.264 | NDI SpeedHQ 软件编码 |
| 电脑端 | 跑 `bridge/ndi_bridge.py` 转成 NDI | 直接就是 NDI 源 |
| 端到端延迟 | **≈ 35-75 ms** | ≈ 20–35 ms |
| 手机发热 | 低（硬编） | 中（软编） |

> **一个常见误解**：entitlement 是**签名期**写进 provisioning profile 的东西，不是上架期才检查的。所以「只在内网自用、不上架」并不能免掉它——免费 Apple ID 根本生成不了带 multicast 的 profile。
> 但反过来也一样：**局域网自用根本不需要它**。你知道电脑 IP，直接单播过去即可，用不着 mDNS 发现。这就是下面这条路存在的意义。

---

## 一、UDP 直连模式（推荐，无需任何账号）

### 原理

```
iOS:  ReplayKit 系统录屏（系统直出 BGRA）
        → vImage 裁剪 + 缩放（零整帧拷贝）
        → VideoToolbox 硬件 H.264 编码（禁用 B 帧 / 实时模式）
        → 裸 UDP 分片发送（单播，不需要 multicast entitlement）

PC:   ndi_bridge.py
        → UDP 收包重组（丢片即丢帧）
        → PyAV 解码 H.264
        → 官方 Processing.NDI.Lib 重新发成 NDI 源
        → Nixsense / NDI Studio Monitor / OBS 正常接收
```

关键点：**普通 UDP 单播不受 iOS 组播限制**，只需要用户在「本地网络」权限弹窗点允许。所以免费 Apple ID 签的 IPA 完全够用。

这条链路我已经在本机实测通过：90 帧送入 → 90 帧输出 → 零丢包，NDI 源创建成功，重编码约 2.3 ms/帧。

### 电脑端（3 步）

```powershell
cd bridge
pip install -r requirements.txt        # av + numpy，一次就够
python ndi_bridge.py                   # 或双击 启动桥接.bat
```

看到这样就是好了：

```
[NDI] 运行时: ...\Processing.NDI.Lib.x64.dll
[NDI] 源已创建: iOS Screen
[UDP] 监听 0.0.0.0:47777，等待 iOS 端推流…

========================================================
手机端「电脑 IP」填这个： 192.168.1.100
手机端「端口」填： 47777
========================================================
```

**不用自己去 ipconfig 查 IP**——桥接启动会直接把该填的地址打出来，照抄到手机上就行。
（首次运行 Windows 防火墙会弹窗，选「专用网络」允许，否则手机发不进来。）

> **强烈建议：给这台电脑设一个固定 IP**（路由器里做 DHCP 保留/静态绑定）。
> 纯局域网自用时 IP 一旦固定，手机端配置就永远不用再改；否则路由器重新分配地址后要重填。

> NDI 运行时 DLL 会自动找：脚本同级、`NDI Tools` 安装目录、桌面。
> 找不到就手动 `--ndi-dll "C:\path\Processing.NDI.Lib.x64.dll"`。

**先自测一下 NDI 链路**（不需要手机）：双击 `自测NDI.bat`，会在接收端出现一个带移动红块的彩条画面。能看到就说明电脑这半边没问题。

参数：

```powershell
python ndi_bridge.py --port 47777 --name "我的iPad" --fps 60
python ndi_bridge.py --bind 0.0.0.0 --port 47777
```

### iOS 端

1. 打开 App → **传输方式** 选「UDP 直连（免账号，推荐）」
2. **电脑 IP** 填跑 `ndi_bridge.py` 那台机器的局域网 IP（`ipconfig` 看，形如 `192.168.1.100`）
3. **端口** `47777`（与电脑端一致）
4. **码率** 选 8 Mbps（网线直连可以上 16–24）
5. 选输出分辨率 → 拖裁剪 → 点「开始 NDI 投屏」→ 系统弹窗选「NDI 投屏」→ 开始直播

第一次会弹「允许访问本地网络」，必须点允许，否则发不出去。

---

## 二、免费签名怎么装

免费 Apple ID 只能签 **7 天**，到期要重签。工具任选：

| 工具 | 说明 |
|---|---|
| **Sideloadly**（推荐） | Windows 可用，把 IPA 拖进去，填 Apple ID，签完直接装 |
| **AltStore / SideStore** | 支持后台自动续签（7 天到期前自动重签），省心 |
| **TrollStore** | 设备支持的话（iOS 14.0–16.6.1 等）永久有效，且能用 NDI 模式 |

**免费签名的两个限制，已经在本工程里处理好了：**

1. **没有 App Group** → 主界面调的参数传不进 Extension。
   处理方式：改 `Shared/SenderConfig.swift` 里的 `Fallback.config`，写成你要的参数，重新编译。`ConfigStore.load()` 在拿不到 App Group 时会自动落到这里。
2. **没有 multicast** → 所以必须用 UDP 模式，不要选 NDI 模式。

也就是说：免费签名 = **先改好 Fallback 配置 → 编译一次 → 之后 7 天重签只是换证书，参数不变**。

### 建议的 Fallback 配置（免费签名用这个）

```swift
public enum Fallback {
    public static let config = SenderConfig(
        transport: .udp,
        ndiName: "iOS Screen",
        udpHost: "192.168.1.100",   // ← 改成你电脑的 IP
        udpPort: 47777,
        bitrateKbps: 8000,
        cropRect: CGRect(x: 0, y: 0, width: 1, height: 1),  // ← 裁剪比例
        outputPreset: .p540,
        maxFPS: 60,
        sendAudio: false
    )
}
```

---

## 三、低延迟是怎么做到的

### iOS 端

| 措施 | 作用 |
|---|---|
| 帧率闸门 | 超过 maxFPS 的帧直接丢，**不排队**——多一层队列就多一帧延迟 |
| vImage 裁剪缩放 | 源 buffer 只 LOCK 一次，指针直接偏移到裁剪原点，不做整帧 memcpy |
| `AllowFrameReordering = false` | 禁用 B 帧，无重排序延迟 |
| `RealTime = true` + 短 GOP | 编码器走实时模式，关键帧间隔 ≤ 2 秒 |
| CVPixelBufferPool | 输出缓冲池化，稳定后每帧零分配 |
| UDP 分片 1400 字节 | 不触发 IP 分片 |

### 电脑端

| 措施 | 作用 |
|---|---|
| `clock_video = false` | 关掉 NDI 自带时钟节流，来一帧发一帧 |
| `last_complete` 帧号 | 旧帧到了直接丢，只等最新帧完整 |
| PyAV low_delay 标志 | 解码器不做输出缓冲 |

### 延迟分解（实测 + 系统固有开销）

**电脑端这两段是实测的**（脚本跑 140 帧取均值，见 `tools/` 同目录的基准输出）：

| 输出 | 解码 | NDI 重编码 | 电脑端合计 |
|---|---|---|---|
| 960×540 | 0.12 ms | 1.39 ms | **1.51 ms** |
| 1280×720 | 0.18 ms | 2.36 ms | **2.54 ms** |
| 1920×1080 | 0.35 ms | 5.16 ms | **5.51 ms** |

**完整链路**（⚠️ 标注「系统」的那几项由 iOS 决定，任何 App 都改不了）：

| 环节 | 耗时 | 性质 |
|---|---|---|
| 屏幕合成 → ReplayKit 跨进程投递 | **16–50 ms**（1–3 帧） | ⚠️ 系统固有，最大的一项 |
| vImage 裁剪缩放 | 1–3 ms | 本工程可控 |
| VideoToolbox 硬编 | 8–20 ms | 硬件流水线，可控（降分辨率） |
| UDP 千兆网线 | <1 ms | 局域网 |
| 分片重组 | <1 ms | 本工程可控 |
| PyAV 解码 | **0.12 ms** | 实测 |
| NDI SpeedHQ 重编码 | **1.39 ms** | 实测 |
| NDI 网络到接收端 | <1 ms | 局域网 |
| **合计** | **≈ 30–75 ms，典型 40 ms** | |

**结论：瓶颈不在你的网络、不在电脑、也不在 NDI 重编码，而在 iOS 的 ReplayKit 和硬件编码上。**

ReplayKit 广播扩展要把屏幕合成结果**跨进程**传给 Extension 进程，这一跳是 1–3 帧，约 16–50 ms。这是 iOS 系统架构决定的，付费账号、App Store 应用、TrollStore 全都一样，绕不过去。

### 自己量一下（别信我，信数据）

`tools/latency_clock.html`：

1. 电脑上浏览器打开这个文件，全屏
2. 把这个文件也传到手机（AirDrop / 网盘 / 局域网 HTTP 都行），手机浏览器打开，全屏
3. 手机开始投屏，画面出现在电脑上（Nixsense / NDI Studio Monitor）
4. **拍一张照片，同时拍到电脑屏幕和手机屏幕**，对比两边的毫秒数
5. 差值就是端到端延迟（两屏走同一个系统时间，靠 NTP 对齐，差值可信）

### 想再低？只能换采集路线

| 方案 | 延迟 | 代价 |
|---|---|---|
| 本方案（ReplayKit + UDP + NDI） | 30–75 ms | 零硬件成本 |
| **USB-C → HDMI → 采集卡**（`capture_method = capture_card`） | **20–40 ms** | 需要手机支持 DP Alt Mode + 一张采集卡（MS2130 芯片约 100–300 元） |
| AirPlay 镜像到电脑 | 100–200 ms | 零成本但延迟最高 |

采集卡路线跳过 ReplayKit，手机直接输出 HDMI（零编码），由采集卡做 UVC 送入电脑，`Nixsense` 原生支持（`capture_method = capture_card`，走 DirectShow）。**要真低于 30 ms，这是唯一现实的路。**

---

## 四、为什么不能直接用 NDI（如果你没有账号）

NDI 靠 **mDNS 组播广告**（`239.x`）让接收端发现源。iOS 14 起，收发组播必须带：

```
com.apple.developer.networking.multicast
```

这个 entitlement **不在任何普通证书里**，要向 Apple 单独申请（[申请入口](https://developer.apple.com/contact/request/networking-multicast)），通常 1–2 周批。免费 Apple ID 账号根本没有申请资格。

后果很直接：没有它，NDI SDK 的 `send_create` 虽然不报错，但广告发不出去，接收端列表里看不到这个源。

**所以 UDP 模式不是妥协，是把「不需要联网广播」这件事换成了「我知道你的 IP，直接单播给你」。**

如果你以后拿到账号了，改成 NDI 模式即可（代码已经双路都实现好了）。

---

## 五、目录结构

```
NDIScreenSender-iOS/
├── project.yml                      XcodeGen 工程描述
├── README.md
├── NDI/
│   └── NDIBridge.h                  NDI 模式才需要 SDK，UDP 模式可以不准备
├── Shared/
│   └── SenderConfig.swift           配置模型 + App Group / Fallback
├── App/
│   ├── NDIScreenSenderApp.swift
│   ├── ContentView.swift            传输方式 / 分辨率 / 帧率 / 可视化裁剪
│   ├── BroadcastPicker.swift        系统「开始直播」入口
│   ├── Info.plist                   含 NSLocalNetworkUsageDescription
│   └── NDIScreenSender.entitlements
├── BroadcastExtension/
│   ├── SampleHandler.swift          双路分发：NDI / UDP
│   ├── FrameScaler.swift            vImage 裁剪缩放（两种输出形态）
│   ├── H264Encoder.swift            VideoToolbox 硬编
│   ├── UDPStreamer.swift            UDP 分片发送
│   ├── NDISender.swift              NDI 封装（NDI 模式用）
│   ├── Info.plist
│   └── NDIBroadcast.entitlements
└── bridge/
    ├── ndi_bridge.py                UDP → 解码 → NDI
    ├── requirements.txt
    ├── 启动桥接.bat
    └── 自测NDI.bat
```

---

## 六、编译成 IPA

> **前提：iOS 只能在 macOS 上编译。** 没有 Mac 就走路线 A（云编译，免费）。

### 路线 A：没有 Mac —— GitHub Actions 云编译

工程里已经放好了 `.github/workflows/build-ipa.yml`，它会自动：装 xcodegen → 检测 NDI SDK（没有就自动剥离）→ **不签名编译** → 打包未签名 IPA → 上传 artifact。

**步骤：**

1. 把 `NDIScreenSender-iOS` **这个目录整个**作为 GitHub 仓库根上传（workflow 路径按这个假设写）
   ```
   仓库/
   ├── .github/workflows/build-ipa.yml
   ├── App/  BroadcastExtension/  Shared/  NDI/  scripts/
   └── project.yml
   ```
2. 打开仓库的 **Actions** 页 → 左边选「Build unsigned IPA」→ 右边 **Run workflow**
3. 约 3–5 分钟，全绿后有两种拿 IPA 的方式：

   | 方式 | 适合 | 说明 |
   |---|---|---|
   | **Releases 页** | ✅ **iPad 上直接下** | workflow 会自动发 Release，`github.com/你的名/仓库/releases` 里的 IPA 是**公开直链，不用登录** |
   | Artifacts | 电脑上下 | 必须登录 GitHub，路径更深 |

4. iPad 上用 Safari 打开 Releases 页面 → 点 `NDIScreenSender-unsigned.ipa` → 存到「文件」App

> **纯 iPad 流程**：Safari 上传代码（或在电脑上建好仓库后，iPad 只负责下载）→ 下载 IPA → NB 助手签名安装。全程不用连电脑。
>
> Release 免登录下载的前提是仓库为 **Public**；Private 仓库的 Release 资产同样需要登录。

GitHub 免费额度：macOS runner 按 10 倍计费，免费账号每月 2000 分钟 ≈ **200 分钟 macOS**，单次编译约 4 分钟，够用几十次。**Public 仓库则完全无限免费。**

> 也能用 Codemagic（免费 500 分钟/月）或直接租 MacinCloud。

### 路线 B：有 Mac —— 一条命令

```bash
cd NDIScreenSender-iOS
chmod +x scripts/build_ipa.sh
./scripts/build_ipa.sh
```

产出 `NDIScreenSender-unsigned.ipa`。

脚本做的就是在做：没有 NDI SDK 时自动跑 `scripts/strip_ndi.py` 剥离 NDI → `xcodegen generate` → `xcodebuild CODE_SIGNING_ALLOWED=NO` → 打包 Payload。

### 路线 C：有 Mac —— Xcode 手动

```bash
brew install xcodegen
cd NDIScreenSender-iOS
xcodegen generate
open NDIScreenSender.xcodeproj
```

- **只想装到自己手机上**：选真机 → Signing 里选你的 Personal Team（免费 Apple ID）→ `Cmd+R` 直接跑。**不需要 IPA**。
- **要 IPA 文件**：免费账号的 `Product → Archive → Distribute` 会失败（导出 IPA 需要付费账号），用路线 B 的脚本不会。

### 拿到未签名 IPA 之后

| 工具 | 平台 | 说明 |
|---|---|---|
| **NB 助手 / 轻松签 等设备端签名工具** | **iOS 设备本身** | 把 IPA 存进「文件」App，在工具里导入 + 用自己的证书签，**全程不用电脑** |
| **Sideloadly** | Win/Mac | 拖入 IPA，填 Apple ID，自动签名安装，**7 天有效** |
| **AltStore / SideStore** | Win/Mac | 同 WiFi 下自动续签，不用手动管 |
| **TrollStore** | iOS 设备 | 支持机型（iOS 14.0–16.6.1 等）永久有效，且 **NDI 模式也能用** |

**能拿到哪些 entitlement，取决于你签名时用的证书 profile：**

| 能力 | 后果 | 本工程的处理 |
|---|---|---|
| App Group | App 与 Extension 无法共享配置 | 自动落到 `Shared/SenderConfig.swift` 的 `Fallback.config`，改那里即可 |
| multicast entitlement | NDI 源无法被发现 | 用 UDP 模式 |

> 设备端签名工具（NB 助手这类）用的是你自备的证书，跟免费 Apple ID 一样拿不到 multicast——
> **除非该证书的 profile 里确实带了这一项，或者用 TrollStore 伪签名。**

**装完后打开 App → 「关于 → 部署与限制」，看 App Group 那一行：**

- 显示 **✅ 可用** → 界面上的 IP / 裁剪设置直接生效，改完就能用
- 显示 **❌ 不可用** → 参数进不了扩展，改 `Fallback.config` 重新编译

然后「传输方式」选 **UDP 直连**。

### 编译前要改的 ID（3 处，必须一致）

1. `project.yml` 的 `PRODUCT_BUNDLE_IDENTIFIER`（Extension 是主 App 加 `.BroadcastExtension`）
2. `Shared/SenderConfig.swift` 的 `AppGroupID.id`
3. `App/*.entitlements` 和 `BroadcastExtension/*.entitlements` 里的 App Group

不改也能编译（用默认的 `com.yourname.ndisender`），但多个 App 共存时会冲突。

### 关于 NDI SDK

- **UDP 模式**：完全不需要。`scripts/strip_ndi.py` 会把相关配置和依赖全部剥离。
- **NDI 模式**：到 <https://ndi.video/for-developers/ndi-sdk/> 免费下载 NDI SDK for Apple，`include/` 和 iOS 版 xcframework 放进 `NDI/`，`xcodegen` 会自动带上。

---

## 七、排错

| 现象 | 处理 |
|---|---|
| 电脑端一直 `收到帧=0` | 手机 IP 填错 / 不在同网段 / 防火墙挡了 UDP 47777。手机端日志看 `[NDI-BC][UDP]` 那行确认目标地址 |
| 电脑端有帧但接收端看不到源 | 换一台机器装 NDI Studio Monitor 验证；Nixsense 里 `ndi_source_name` 要填对名字 |
| 画面糊 | 码率调高（12–24 Mbps）；或输出分辨率升到 720p |
| 画面卡顿 | 降分辨率到 540p、帧率 60、降低手机屏幕刷新率；桥接程序所在机器 CPU 占用也要看 |
| 黑屏 / 花屏几秒后才好 | 正常：起点不是关键帧，等下一个关键帧（GOP ≤ 2 秒） |
| 控制中心没有「NDI 投屏」 | Extension 没嵌进 App，检查 Embed App Extensions |
| 第一次没弹「本地网络」权限 | 设置 → 隐私 → 本地网络 → 手动打开本 App |
| 免费签名后参数改不动 | 免费签名没有 App Group，改 `Fallback.config` 重新编译 |
| `av` 装不上 | `pip install av -i https://pypi.tuna.tsinghua.edu.cn/simple` |
| 桥接报找不到 NDI DLL | `python ndi_bridge.py --ndi-dll "C:\...\Processing.NDI.Lib.x64.dll"` |

日志：Xcode → Window → Devices and Simulators → Open Console，过滤 `NDI-BC`。
