// UDPStreamer.swift
// 低延迟 UDP 分片发送。不依赖 NDI，因此**不需要 multicast entitlement**，
// 免费 Apple ID 签名也能用（只要用户允许「本地网络」）。
//
// 包结构（小端）：
//   magic      4B   "NSP1"
//   frameID    4B   帧序号（递增，接收端用来丢弃过期帧）
//   chunkIdx   2B   片索引，从 0 开始
//   chunkCount 2B   本帧总片数
//   flags      1B   bit0 = 关键帧
//   reserved   1B
//   payloadLen 2B   有效负载长度
//   payload    N B  H.264 Annex-B 片段
//
// 头部固定 16 字节。分片大小控制在 1400 字节以内，避免 IP 分片。
import Foundation
import Darwin

final class UDPStreamer {

    private var sock: Int32 = -1
    private var addr = sockaddr_in()
    private var frameID: UInt32 = 0

    /// 单包最大字节数（含头部），1500 - 20(IP) - 8(UDP) = 1472，取 1400 留余量
    private let maxDatagram = 1400
    private let headerSize = 16

    private(set) var host: String
    private(set) var port: UInt16

    init?(host: String, port: UInt16) {
        self.host = host
        self.port = port

        sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else {
            NSLog("[UDP] socket() failed: %d", errno)
            return nil
        }

        // 大发送缓冲：一次突发几百 KB 也不至于阻塞
        var sndBuf: Int32 = 4 * 1024 * 1024
        setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))

        // TO-DO: 不要 SOCK_DGRAM 阻塞；UDP 发送本来就是非阻塞语义，这里仍设非阻塞避免极端拥塞卡住采集线程
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            NSLog("[UDP] 非法 IP: %@", host)
            close(sock)
            sock = -1
            return nil
        }
    }

    deinit {
        if sock >= 0 { close(sock) }
    }

    /// 发送一帧 H.264 Annex-B 数据
    func send(frame: Data, isKey: Bool) {
        guard sock >= 0, !frame.isEmpty else { return }

        frameID &+= 1
        let payloadMax = maxDatagram - headerSize
        let chunkCount = (frame.count + payloadMax - 1) / payloadMax

        frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            var idx = 0
            while offset < frame.count {
                let len = min(payloadMax, frame.count - offset)
                sendChunk(base: base, offset: offset, length: len,
                          idx: UInt16(idx), count: UInt16(chunkCount), isKey: isKey)
                offset += len
                idx += 1
            }
        }
    }

    private func sendChunk(base: UnsafeRawPointer, offset: Int, length: Int,
                           idx: UInt16, count: UInt16, isKey: Bool) {

        var packet = [UInt8](repeating: 0, count: headerSize + length)

        packet[0] = 0x4E   // N
        packet[1] = 0x53   // S
        packet[2] = 0x50   // P
        packet[3] = 0x31   // 1

        writeU32(&packet, 4, frameID)
        writeU16(&packet, 8, idx)
        writeU16(&packet, 10, count)
        packet[12] = isKey ? 1 : 0
        packet[13] = 0
        writeU16(&packet, 14, UInt16(length))

        packet.withUnsafeMutableBytes { dst in
            guard let d = dst.baseAddress else { return }
            memcpy(d.advanced(by: headerSize), base.advanced(by: offset), length)
        }

        packet.withUnsafeBytes { pkt in
            guard let p = pkt.baseAddress else { return }
            var a = addr
            let sent = withUnsafePointer(to: &a) { ap -> Int in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sock, p, pkt.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            // EWOULDBLOCK 直接丢，不重试——低延迟优先
            if sent < 0 {
                let e = errno
                if e != EWOULDBLOCK && e != EAGAIN {
                    NSLog("[UDP] sendto failed: %d", e)
                }
            }
        }
    }

    private func writeU32(_ buf: inout [UInt8], _ at: Int, _ v: UInt32) {
        buf[at] = UInt8(v & 0xFF)
        buf[at + 1] = UInt8((v >> 8) & 0xFF)
        buf[at + 2] = UInt8((v >> 16) & 0xFF)
        buf[at + 3] = UInt8((v >> 24) & 0xFF)
    }

    private func writeU16(_ buf: inout [UInt8], _ at: Int, _ v: UInt16) {
        buf[at] = UInt8(v & 0xFF)
        buf[at + 1] = UInt8((v >> 8) & 0xFF)
    }
}
