#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ndi_bridge.py — 把 iOS 发来的 H.264 over UDP 转成标准 NDI 源

为什么需要它：
    iOS 要发标准 NDI 必须带 com.apple.developer.networking.multicast entitlement
    （付费开发者账号 + Apple 审批）。普通 UDP 单播不需要任何 entitlement，
    所以 iOS 端发裸 UDP，这里收到后解码、再用官方 NDI 运行时重新发成 NDI 源，
    Nixsense / NDI Studio Monitor / OBS 就能像收普通 NDI 一样收到它。

用法：
    python ndi_bridge.py                        # 监听 0.0.0.0:47777，发 NDI
    python ndi_bridge.py --port 47777 --name "iOS Screen"
    python ndi_bridge.py --selftest             # 不接手机，发测试图案，验证 NDI 链路
    python ndi_bridge.py --ndi-dll "C:\\...\\Processing.NDI.Lib.x64.dll"

依赖：
    pip install av numpy
    NDI 运行时 DLL（装过 NDI Tools 或 Nixsense 就自带）

协议（与 iOS 端 UDPStreamer.swift 一致，小端）：
    magic 4B "NSP1" | frameID u32 | chunkIdx u16 | chunkCount u16
    flags u8（bit0=关键帧）| reserved u8 | payloadLen u16 | payload
    头部固定 16 字节
"""

import argparse
import ctypes
import ctypes.util
import os
import socket
import struct
import sys
import time
from collections import defaultdict

import numpy as np

# ─────────────────────────── NDI 绑定（ctypes） ───────────────────────────

NDI_FOURCC_BGRA = 0x41524742          # 'BGRA' 小端
NDI_FRAME_FORMAT_PROGRESSIVE = 1
NDI_SEND_TIMECODE_SYNTHESIZE = 0x7FFFFFFFFFFFFFFF


class NDIlib_send_create_t(ctypes.Structure):
    _fields_ = [
        ("p_ndi_name", ctypes.c_char_p),
        ("p_groups", ctypes.c_char_p),
        ("clock_video", ctypes.c_bool),
        ("clock_audio", ctypes.c_bool),
    ]


class NDIlib_video_frame_v2_t(ctypes.Structure):
    _fields_ = [
        ("xres", ctypes.c_int),
        ("yres", ctypes.c_int),
        ("FourCC", ctypes.c_int),
        ("frame_rate_N", ctypes.c_int),
        ("frame_rate_D", ctypes.c_int),
        ("picture_aspect_ratio", ctypes.c_float),
        ("frame_format_type", ctypes.c_int),
        ("timecode", ctypes.c_int64),
        ("p_data", ctypes.c_void_p),
        ("line_stride_in_bytes", ctypes.c_int),
        ("p_metadata", ctypes.c_char_p),
        ("timestamp", ctypes.c_int64),
    ]


def find_ndi_dll(explicit=None):
    """在常见位置找 NDI 运行时"""
    if explicit:
        return explicit if os.path.isfile(explicit) else None

    candidates = []
    here = os.path.dirname(os.path.abspath(__file__))

    # 1. 脚本同级及上级
    for up in (here, os.path.dirname(here), os.path.dirname(os.path.dirname(here))):
        candidates.append(os.path.join(up, "Processing.NDI.Lib.x64.dll"))

    # 2. 环境变量（NDI Tools 会设）
    for env in ("NDI_RUNTIME_DIR_V6", "NDI_RUNTIME_DIR_V5", "NDI_RUNTIME_DIR_V4"):
        d = os.environ.get(env)
        if d:
            candidates.append(os.path.join(d, "Processing.NDI.Lib.x64.dll"))

    # 3. 标准安装路径
    for base in (r"C:\Program Files\NDI", r"C:\Program Files (x86)\NDI",
                 r"D:\Program Files\NDI", r"E:\Program Files\NDI"):
        if not os.path.isdir(base):
            continue
        for root, _dirs, files in os.walk(base):
            if "Processing.NDI.Lib.x64.dll" in files:
                candidates.append(os.path.join(root, "Processing.NDI.Lib.x64.dll"))

    # 4. 搜桌面（很多人把绿色版放桌面）
    desktop = os.path.join(os.path.expanduser("~"), "Desktop")
    if os.path.isdir(desktop):
        for root, dirs, files in os.walk(desktop):
            # 限制深度，别扫太久
            if root.count(os.sep) - desktop.count(os.sep) > 4:
                dirs[:] = []
                continue
            if "Processing.NDI.Lib.x64.dll" in files:
                candidates.append(os.path.join(root, "Processing.NDI.Lib.x64.dll"))

    for c in candidates:
        if c and os.path.isfile(c):
            return c
    return None


class NDISender:
    """官方 NDI 运行时的极简封装（同步发送）"""

    def __init__(self, dll_path, name, fps=60):
        self.lib = ctypes.CDLL(dll_path)
        self._bind()
        if not self.lib.NDIlib_initialize():
            raise RuntimeError("NDIlib_initialize 失败")

        desc = NDIlib_send_create_t()
        desc.p_ndi_name = name.encode("utf-8")
        desc.p_groups = None
        desc.clock_video = False      # 关掉 NDI 自带时钟节流 → 来一帧发一帧，延迟最低
        desc.clock_audio = False

        self.instance = self.lib.NDIlib_send_create(ctypes.byref(desc))
        if not self.instance:
            raise RuntimeError("NDIlib_send_create 失败")

        self.fps = fps
        self.width = 0
        self.height = 0
        self.name = name
        self.frames = 0
        self.t0 = time.time()

    def _bind(self):
        lib = self.lib
        lib.NDIlib_initialize.restype = ctypes.c_bool
        lib.NDIlib_initialize.argtypes = []

        lib.NDIlib_destroy.argtypes = []

        lib.NDIlib_send_create.restype = ctypes.c_void_p
        lib.NDIlib_send_create.argtypes = [ctypes.POINTER(NDIlib_send_create_t)]

        lib.NDIlib_send_destroy.argtypes = [ctypes.c_void_p]

        lib.NDIlib_send_send_video_v2.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(NDIlib_video_frame_v2_t)
        ]

        lib.NDIlib_send_get_no_connections.restype = ctypes.c_int
        lib.NDIlib_send_get_no_connections.argtypes = [ctypes.c_void_p, ctypes.c_uint32]

    def send_bgra(self, arr):
        """arr: numpy uint8 (H, W, 4)，BGRA 布局，C 连续"""
        if arr.ndim != 3 or arr.shape[2] != 4:
            return
        h, w = arr.shape[0], arr.shape[1]
        if w != self.width or h != self.height:
            self.width, self.height = w, h
            print(f"[NDI] 输出尺寸 → {w}x{h}")

        if not arr.flags["C_CONTIGUOUS"]:
            arr = np.ascontiguousarray(arr)

        frame = NDIlib_video_frame_v2_t()
        frame.xres = w
        frame.yres = h
        frame.FourCC = NDI_FOURCC_BGRA
        frame.frame_rate_N = self.fps * 1000
        frame.frame_rate_D = 1000
        frame.picture_aspect_ratio = ctypes.c_float(w / float(h))
        frame.frame_format_type = NDI_FRAME_FORMAT_PROGRESSIVE
        frame.timecode = NDI_SEND_TIMECODE_SYNTHESIZE
        frame.p_data = arr.ctypes.data_as(ctypes.c_void_p)
        frame.line_stride_in_bytes = w * 4
        frame.p_metadata = None
        frame.timestamp = 0

        self.lib.NDIlib_send_send_video_v2(self.instance, ctypes.byref(frame))
        self.frames += 1

    def connections(self):
        return self.lib.NDIlib_send_get_no_connections(self.instance, 0)

    def destroy(self):
        try:
            self.lib.NDIlib_send_destroy(self.instance)
            self.lib.NDIlib_destroy()
        except Exception:
            pass


# ─────────────────────────── UDP 重组 ───────────────────────────

MAGIC = b"NSP1"
HEADER = 16


class Reassembler:
    """按 frameID 重组分片；只保留最新的若干帧，过期帧直接丢（低延迟优先）"""

    def __init__(self, max_pending=64):
        self.pending = {}          # frameID -> bytearray / dict
        self.counts = {}
        self.max_pending = max_pending
        self.last_complete = -1
        self.stats_drop = 0
        self.stats_ok = 0

    def feed(self, data):
        """返回 (annexB bytes, is_key) 或 None"""
        if len(data) < HEADER or data[:4] != MAGIC:
            return None

        frame_id, idx, count = struct.unpack_from("<IHH", data, 4)
        flags = data[12]
        payload_len = struct.unpack_from("<H", data, 14)[0]
        payload = data[HEADER:HEADER + payload_len]

        if count == 0 or idx >= count:
            return None

        # 已经有更新的帧完成了 → 这帧直接丢
        if frame_id <= self.last_complete:
            self.stats_drop += 1
            return None

        slot = self.pending.get(frame_id)
        if slot is None:
            slot = {}
            self.pending[frame_id] = slot
            self.counts[frame_id] = count
            # 控制内存：只留最新的 max_pending 个帧号
            if len(self.pending) > self.max_pending:
                for old in sorted(self.pending.keys())[:len(self.pending) - self.max_pending]:
                    self.pending.pop(old, None)
                    self.counts.pop(old, None)

        slot[idx] = payload

        if len(slot) == count:
            buf = bytearray()
            for i in range(count):
                piece = slot.get(i)
                if piece is None:
                    self.pending.pop(frame_id, None)
                    self.stats_drop += 1
                    return None
                buf.extend(piece)

            self.pending.pop(frame_id, None)
            self.counts.pop(frame_id, None)
            self.last_complete = frame_id
            self.stats_ok += 1
            return bytes(buf), bool(flags & 1)

        return None


# ─────────────────────────── 解码 + 发送 ───────────────────────────

class H264Decoder:
    """PyAV 的 h264 解码器封装，处理分辨率变化时重建"""

    def __init__(self):
        import av
        self.av = av
        self.ctx = av.CodecContext.create("h264", "r")
        self._apply_low_delay()
        self.size = None

    def _apply_low_delay(self):
        """不同 PyAV 版本枚举名不一样（low_delay / LOW_DELAY），探测一下"""
        import av
        for name in ("LOW_DELAY", "low_delay"):
            flag = getattr(av.codec.context.Flags, name, None)
            if flag is None:
                continue
            try:
                self.ctx.flags |= flag
            except Exception:
                pass
            break

    def decode(self, data):
        try:
            packet = self.av.Packet(data)
            return self.ctx.decode(packet)
        except Exception as exc:  # noqa: BLE001
            # 丢包导致数据断裂时重置，等下一个关键帧
            if type(exc).__name__ not in ("InvalidDataError",):
                print(f"[AV] decode error: {exc}")
            self.reset()
            return []

    def reset(self):
        import av
        self.ctx = av.CodecContext.create("h264", "r")
        self._apply_low_delay()
        self.size = None


def frame_to_bgra(frame):
    """PyAV frame → BGRA numpy，统一尺寸"""
    return frame.to_ndarray(format="bgra")


def local_ipv4_list():
    """列出本机可用的局域网 IPv4，用来告诉用户手机该填哪个地址"""
    ips = []

    # 1. 默认路由出口地址（最可能是对的那个）
    try:
        probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        probe.connect(("8.8.8.8", 80))      # UDP connect 不发包，只选路
        ips.append(probe.getsockname()[0])
        probe.close()
    except Exception:
        pass

    # 2. 主机名解析出的其它地址
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127.") and ip not in ips:
                ips.append(ip)
    except Exception:
        pass

    return ips


def print_connect_hint(port):
    ips = local_ipv4_list()
    print()
    print("=" * 56)
    if ips:
        print(f"手机端「电脑 IP」填这个： {ips[0]}")
        if len(ips) > 1:
            print(f"（其它网卡：{', '.join(ips[1:])}）")
    else:
        print("没检测到局域网地址，用 ipconfig 看一下本机 IPv4")
    print(f"手机端「端口」填： {port}")
    print("=" * 56)
    print("如果手机一直发不出来：Windows 防火墙首次会弹窗，务必选「专用网络」允许")
    print()


def run(args):
    dll = find_ndi_dll(args.ndi_dll)
    if not dll:
        print("✗ 找不到 Processing.NDI.Lib.x64.dll")
        print("  装一个 NDI Tools，或用 --ndi-dll 指定路径")
        return 2
    print(f"[NDI] 运行时: {dll}")

    try:
        sender = NDISender(dll, args.name, fps=args.fps)
    except Exception as exc:  # noqa: BLE001
        print(f"✗ 创建 NDI 发送端失败: {exc}")
        return 3
    print(f"[NDI] 源已创建: {args.name}")

    if args.selftest:
        return selftest(sender, args)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
    sock.bind((args.bind, args.port))
    sock.settimeout(1.0)
    print(f"[UDP] 监听 {args.bind}:{args.port}，等待 iOS 端推流…（Ctrl+C 退出）")
    print_connect_hint(args.port)

    reasm = Reassembler()
    decoder = H264Decoder()

    last_report = time.time()
    got_first = False
    frames_out = 0

    try:
        while True:
            try:
                data, peer = sock.recvfrom(2048)
            except socket.timeout:
                # 超时：汇报状态，检查 NDI 连接数
                now = time.time()
                if now - last_report >= 2.0:
                    last_report = now
                    print(f"[状态] conns={sender.connections()} 收到帧={reasm.stats_ok} "
                          f"丢弃={reasm.stats_drop} 输出={frames_out}")
                continue

            if not got_first:
                got_first = True
                print(f"[UDP] 收到第一包，来自 {peer[0]}:{peer[1]}")

            result = reasm.feed(data)
            if not result:
                continue

            annexb, is_key = result
            for frame in decoder.decode(annexb):
                arr = frame_to_bgra(frame)
                sender.send_bgra(arr)
                frames_out += 1

            now = time.time()
            if now - last_report >= 2.0:
                last_report = now
                fps = frames_out / max(1e-6, (now - sender.t0))
                print(f"[状态] conns={sender.connections()} 帧={frames_out} "
                      f"丢={reasm.stats_drop} 平均={fps:.1f}fps 尺寸={sender.width}x{sender.height}")

    except KeyboardInterrupt:
        print("\n[退出] 收到 Ctrl+C")
    finally:
        sock.close()
        sender.destroy()
    return 0


def selftest(sender, args):
    """不发真实数据，直接发测试图案，验证 NDI 链路是否通"""
    print("[自测] 发送彩条测试画面。在接收端找源：", args.name)
    w, h = 1280, 720
    yy, xx = np.mgrid[0:h, 0:w]
    bars = ((xx * 8) // w).astype(np.uint8)
    palette = np.array([
        [255, 255, 255, 255], [0, 255, 255, 255], [255, 255, 0, 255], [0, 255, 0, 255],
        [255, 0, 255, 255], [255, 0, 0, 255], [0, 0, 255, 255], [0, 0, 0, 255],
    ], dtype=np.uint8)  # BGRA
    t0 = time.time()
    try:
        while True:
            img = palette[bars].astype(np.uint8)
            # 右下角跑一个方块，方便看是否卡住
            pos = int((time.time() - t0) * 300) % (w - 80)
            img[h - 80:h, pos:pos + 80] = [0, 0, 255, 255]
            sender.send_bgra(img)
            if sender.frames % 120 == 0:
                print(f"[自测] 已发 {sender.frames} 帧，conns={sender.connections()}")
            time.sleep(1.0 / args.fps)
    except KeyboardInterrupt:
        print("\n[自测] 结束")
    finally:
        sender.destroy()
    return 0


def main():
    # 让日志实时刷出（管道/重定向时默认会缓冲）
    try:
        sys.stdout.reconfigure(line_buffering=True)
        sys.stderr.reconfigure(line_buffering=True)
    except Exception:
        pass

    ap = argparse.ArgumentParser(description="iOS H.264/UDP → NDI 桥接")
    ap.add_argument("--bind", default="0.0.0.0", help="监听地址，默认 0.0.0.0")
    ap.add_argument("--port", type=int, default=47777, help="监听端口，默认 47777")
    ap.add_argument("--name", default="iOS Screen", help="NDI 源名称")
    ap.add_argument("--fps", type=int, default=60, help="告知接收端的帧率")
    ap.add_argument("--ndi-dll", default=None, help="Processing.NDI.Lib.x64.dll 路径")
    ap.add_argument("--selftest", action="store_true", help="发测试图案验证 NDI 链路")
    args = ap.parse_args()
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
