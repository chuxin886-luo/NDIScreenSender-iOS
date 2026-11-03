#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
strip_ndi.py — 从 project.yml 里移除 NDI 相关配置

用途：没有 NDI SDK、只想走纯 UDP 模式时，让工程完全不依赖 NDI 也能编译。

    python3 scripts/strip_ndi.py project.yml

做的事：
  1. 删掉 GCC_PREPROCESSOR_DEFINITIONS 里的 NDI_ENABLED=1
  2. 把 SWIFT_ACTIVE_COMPILATION_CONDITIONS 里的 NDI_ENABLED 去掉
  3. 删掉 - framework: NDI/... 及其 embed / link 两行
  4. 若某个 target 的 dependencies 因此变空，整段删掉（避免 YAML 空值报错）
"""
import re
import sys


def strip(path):
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    out = []
    i = 0
    removed_framework = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # 1. GCC_PREPROCESSOR_DEFINITIONS 里带 NDI_ENABLED 的整行删掉
        if stripped.startswith("GCC_PREPROCESSOR_DEFINITIONS") and "NDI_ENABLED" in stripped:
            i += 1
            continue

        # 2. SWIFT_ACTIVE_COMPILATION_CONDITIONS 只去掉 NDI_ENABLED，保留别的
        if stripped.startswith("SWIFT_ACTIVE_COMPILATION_CONDITIONS"):
            indent = line[:len(line) - len(line.lstrip())]
            out.append(f'{indent}SWIFT_ACTIVE_COMPILATION_CONDITIONS: ""\n')
            i += 1
            continue

        # 3. NDI xcframework 依赖：- framework: ... 后面通常跟 embed / link
        if stripped.startswith("- framework:") and "libndi" in stripped and ".xcframework" in stripped:
            i += 1
            while i < len(lines) and re.match(r"^\s+(embed|link|codeSign):", lines[i]):
                i += 1
            removed_framework += 1
            continue

        out.append(line)
        i += 1

    # 4. 清掉变空的 dependencies 段
    final = []
    j = 0
    while j < len(out):
        if out[j].strip() == "dependencies:":
            k = j + 1
            # 跳过空行和纯注释
            while k < len(out) and (out[k].strip() == "" or out[k].strip().startswith("#")):
                k += 1
            # 下一个有效行缩进不比 dependencies 深 → 说明这一段是空的
            next_indent = len(out[k]) - len(out[k].lstrip()) if k < len(out) else 0
            cur_indent = len(out[j]) - len(out[j].lstrip())
            if k >= len(out) or next_indent <= cur_indent:
                j = k
                continue
        final.append(out[j])
        j += 1

    with open(path, "w", encoding="utf-8") as f:
        f.writelines(final)

    print(f"✓ 已移除 NDI 配置（framework 依赖 {removed_framework} 处）")
    print("  工程现在只走 UDP 模式，不需要 NDI SDK")


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "project.yml"
    strip(target)
