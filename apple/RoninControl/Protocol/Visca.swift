import Foundation

/// 이 PTZ의 Visca TCP입니다. ONVIF 로그인이 움직임을 막을 때 1259번으로 보냅니다.
enum Visca {
    static let port: UInt16 = 1259

    static func drive(host: String, port: UInt16 = 1259, pan: Double, tilt: Double, zoom: Double) async -> Bool {
        let panSpeed = speed(abs(pan), limit: 0x14)
        let tiltSpeed = speed(abs(tilt), limit: 0x10)
        let panDir: UInt8 = pan > 0.08 ? 0x02 : (pan < -0.08 ? 0x01 : 0x03)
        let tiltDir: UInt8 = tilt > 0.08 ? 0x01 : (tilt < -0.08 ? 0x02 : 0x03)
        var ok = true
        if panDir != 0x03 || tiltDir != 0x03 {
            ok = await send(host: host, port: port, bytes: [0x81, 0x01, 0x06, 0x01, panSpeed, tiltSpeed, panDir, tiltDir, 0xFF])
        }
        if abs(zoom) > 0.08 {
            let zoomByte: UInt8 = zoom > 0 ? 0x02 : 0x03
            ok = await send(host: host, port: port, bytes: [0x81, 0x01, 0x04, 0x07, zoomByte, 0xFF]) && ok
        }
        return ok
    }

    /// 무대 시선의 절대각입니다. 1단계는 0.075° 이고, 90 41 이 올 때만 성공입니다.
    static func absolute(host: String, port: UInt16 = 1259, pan: Double, tilt: Double, zoom: Double) async -> Bool {
        let panSteps = Int((max(-170, min(170, pan)) / 0.075).rounded())
        let tiltSteps = Int((max(-90, min(90, tilt)) / 0.075).rounded())
        var bytes: [UInt8] = [0x81, 0x01, 0x06, 0x02, 0x14, 0x12]
        bytes.append(contentsOf: nibbles(panSteps))
        bytes.append(contentsOf: nibbles(tiltSteps))
        bytes.append(0xFF)
        let moved = await send(host: host, port: port, bytes: bytes)
        let zoomSteps = Int((max(0, min(1, zoom)) * 0x4000).rounded())
        var zoomBytes: [UInt8] = [0x81, 0x01, 0x04, 0x47]
        zoomBytes.append(contentsOf: nibbles(zoomSteps))
        zoomBytes.append(0xFF)
        let zoomed = await send(host: host, port: port, bytes: zoomBytes)
        return moved || zoomed
    }

    static func stop(host: String, port: UInt16 = 1259) async -> Bool {
        let pan = await send(host: host, port: port, bytes: [0x81, 0x01, 0x06, 0x01, 0x01, 0x01, 0x03, 0x03, 0xFF])
        let zoom = await send(host: host, port: port, bytes: [0x81, 0x01, 0x04, 0x07, 0x00, 0xFF])
        return pan || zoom
    }

    private static func nibbles(_ value: Int) -> [UInt8] {
        let bits = UInt16(bitPattern: Int16(clamping: value))
        return [
            UInt8((bits >> 12) & 0x0F),
            UInt8((bits >> 8) & 0x0F),
            UInt8((bits >> 4) & 0x0F),
            UInt8(bits & 0x0F),
        ]
    }

    private static func speed(_ amount: Double, limit: UInt8) -> UInt8 {
        let scaled = Int((amount * Double(limit)).rounded())
        return UInt8(min(Int(limit), Swift.max(1, scaled)))
    }

    /// 카메라가 90 41(받음) 또는 90 50(완료)으로 답할 때만 성공입니다.
    private static func send(host: String, port: UInt16, bytes: [UInt8]) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: exchange(host: host, port: port, bytes: bytes))
            }
        }
    }

    private static func exchange(host: String, port: UInt16, bytes: [UInt8]) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var wait = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        dest.sin_addr.s_addr = inet_addr(host)
        let connected = withUnsafePointer(to: &dest) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 { return false }
        let sent = bytes.withUnsafeBytes { buffer in
            Darwin.send(fd, buffer.baseAddress, buffer.count, 0)
        }
        if sent < 0 { return false }
        var storage = [UInt8](repeating: 0, count: 64)
        let count = recv(fd, &storage, storage.count, 0)
        if count < 3 { return false }
        return storage[0] == 0x90 && (storage[1] == 0x41 || storage[1] == 0x50 || storage[1] == 0x51)
    }
}
