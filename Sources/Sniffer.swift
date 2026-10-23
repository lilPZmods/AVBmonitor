// Sniffer: watches ACMP connect/disconnect traffic on the AVB network so the manager can see
// who (which controller) changed a route, and react to changes to locked routes immediately.
// Uses BPF (read-only); needs the access_bpf group, which ChmodBPF sets up at boot.

import Foundation

struct ACMPEvent {
    var time: Date
    var connect: Bool        // true = CONNECT_RX, false = DISCONNECT_RX
    var controller: UInt64
    var talker: UInt64
    var talkerUID: UInt16
    var listener: UInt64
    var listenerUID: UInt16
    var sinkKey: String { "\(hex(listener))[\(listenerUID)]" }
}

final class Sniffer {
    let ifname: String
    var onEvent: ((ACMPEvent) -> Void)?
    private var fd: Int32 = -1

    init(_ ifname: String) { self.ifname = ifname }

    func start() -> Bool {
        for i in 0..<256 {
            fd = open("/dev/bpf\(i)", O_RDONLY)
            if fd >= 0 || errno != EBUSY { break }
        }
        guard fd >= 0 else { log("sniffer: cannot open /dev/bpf (\(String(cString: strerror(errno)))) - change attribution disabled"); return false }
        var ifr = [UInt8](repeating: 0, count: 32)
        let n = Array(ifname.utf8.prefix(15)); ifr.replaceSubrange(0..<n.count, with: n)
        let BIOCSETIF: UInt = 0x8020426c, BIOCIMMEDIATE: UInt = 0x80044270, BIOCGBLEN: UInt = 0x40044266
        guard ifr.withUnsafeMutableBytes({ ioctl(fd, BIOCSETIF, $0.baseAddress!) }) == 0 else {
            log("sniffer: cannot attach to \(ifname)"); close(fd); return false
        }
        var one: UInt32 = 1
        _ = ioctl(fd, BIOCIMMEDIATE, &one)
        var blen: UInt32 = 0
        _ = ioctl(fd, BIOCGBLEN, &blen)
        let bufLen = Int(blen == 0 ? 4096 : blen)
        Thread.detachNewThread { [self] in
            var buf = [UInt8](repeating: 0, count: bufLen)
            while true {
                let got = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress!, bufLen) }
                if got <= 0 { if got < 0 && errno != EINTR { Thread.sleep(forTimeInterval: 1) }; continue }
                var i = 0
                while i + 18 <= got {
                    // struct bpf_hdr: timeval32 (8), caplen (4), datalen (4), hdrlen (2)
                    let caplen = Int(buf[i + 8]) | Int(buf[i + 9]) << 8 | Int(buf[i + 10]) << 16 | Int(buf[i + 11]) << 24
                    let hdrlen = Int(buf[i + 16]) | Int(buf[i + 17]) << 8
                    let start = i + hdrlen
                    if start + caplen <= got { parse(buf, start, caplen) }
                    i += (hdrlen + caplen + 3) & ~3
                }
            }
        }
        return true
    }

    private func parse(_ b: [UInt8], _ s: Int, _ len: Int) {
        // Ethernet + ACMP PDU (subtype 0xFC) is 14 + 56 bytes
        guard len >= 70, b[s + 12] == 0x22, b[s + 13] == 0xF0, b[s + 14] == 0xFC else { return }
        let p = s + 14
        let msg = b[p + 1] & 0x0F, status = b[p + 2] >> 3
        // only successful CONNECT_RX_RESPONSE (7) and DISCONNECT_RX_RESPONSE (9)
        guard status == 0, msg == 7 || msg == 9 else { return }
        func u64(_ o: Int) -> UInt64 { (0..<8).reduce(UInt64(0)) { $0 << 8 | UInt64(b[o + $1]) } }
        func u16(_ o: Int) -> UInt16 { UInt16(b[o]) << 8 | UInt16(b[o + 1]) }
        let e = ACMPEvent(time: Date(), connect: msg == 7, controller: u64(p + 12), talker: u64(p + 20), talkerUID: u16(p + 36),
                          listener: u64(p + 28), listenerUID: u16(p + 38))
        onEvent?(e)
    }
}
