#!/bin/bash
# build_ipa.sh — 在 macOS 上一键产出未签名 IPA
#
# 用法：
#   chmod +x scripts/build_ipa.sh
#   ./scripts/build_ipa.sh
#
# 产出：build/NDIScreenSender-unsigned.ipa
# 之后用 Sideloadly / AltStore / TrollStore 签名安装即可。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
echo "工程目录: $ROOT"

# ── 1. 准备 xcodegen ──
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "→ 安装 xcodegen ..."
  if command -v brew >/dev/null 2>&1; then
    brew install xcodegen
  else
    echo "✗ 没有 Homebrew。先装：/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    exit 1
  fi
fi

# ── 2. 没 NDI SDK 就自动切纯 UDP 模式 ──
if [ -f "NDI/include/Processing.NDI.Lib.h" ]; then
  echo "→ 检测到 NDI SDK，编译双模式"
else
  echo "→ 没找到 NDI SDK，自动切换为纯 UDP 模式"
  python3 scripts/strip_ndi.py project.yml
fi

# ── 3. 生成 Xcode 工程 ──
echo "→ 生成工程 ..."
xcodegen generate

# ── 4. 未签名编译（不依赖任何开发者账号）──
echo "→ 编译 Release（不签名）..."
rm -rf build
xcodebuild \
  -project NDIScreenSender.xcodeproj \
  -scheme NDIScreenSender \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="$ROOT/build/Build/Products/Release-iphoneos/NDIScreenSender.app"
if [ ! -d "$APP" ]; then
  echo "✗ 编译产物没找到: $APP"
  exit 1
fi

# ── 5. 打包成 IPA ──
echo "→ 打包 IPA ..."
rm -rf Payload NDIScreenSender-unsigned.ipa
mkdir -p Payload
cp -R "$APP" Payload/
# 去掉可能残留的签名，交给签名工具重签
rm -rf Payload/NDIScreenSender.app/_CodeSignature
rm -f  Payload/NDIScreenSender.app/embedded.mobileprovision
zip -qry NDIScreenSender-unsigned.ipa Payload
rm -rf Payload

echo ""
echo "============================================"
echo "✓ 完成：$ROOT/NDIScreenSender-unsigned.ipa"
echo "  大小：$(du -h NDIScreenSender-unsigned.ipa | cut -f1)"
echo ""
echo "下一步，三选一："
echo "  Sideloadly（Windows/Mac，免费 Apple ID，7天）"
echo "  AltStore / SideStore（自动续签）"
echo "  TrollStore（支持机型上永久有效，且可用 NDI 模式）"
echo "============================================"
