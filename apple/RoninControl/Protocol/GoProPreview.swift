import CoreImage
import CoreMedia
import Darwin
import Foundation
import VideoToolbox

/// 고프로 와이파이 미리보기입니다. 카메라가 UDP 8554로 보내는 MPEG-TS만 그림으로 풉니다.
/// 그림이 없으면 빈 화면을 만들지 않고, 다른 장치에는 이 수신기를 켜지 않습니다.
final class GoProPreview: ObservableObject {
    @Published var image: CGImage?
    @Published var note = "실시간 그림을 기다리는 중입니다."

    private let queue = DispatchQueue(label: "gopro.preview")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var running = false
    private var fd: Int32 = -1
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var codec: Codec = .unknown
    private var pmtPID: UInt16?
    private var videoPID: UInt16?
    private var pes = Data()
    private var sps: Data?
    private var pps: Data?
    private var vps: Data?
    private var packets = 0
    private var drewFrame = false
    private var ticket = 0
    private var lastDraw = Date.distantPast
    private var formatToken: String?

    private enum Codec { case unknown, h264, hevc }

    func open(_ device: DeviceRecord) {
        guard device.kind.supportsLiveView else { return }
        DispatchQueue.main.async {
            self.image = nil
            self.note = "실시간 그림을 기다리는 중입니다."
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.ticket += 1
            let mine = self.ticket
            self.shutdownLocked()
            self.listen(mine)
        }
        Task {
            do {
                _ = try await GoProClient.previewStream(device, start: true)
            } catch {
                await MainActor.run {
                    if self.image == nil {
                        self.note = "미리보기 스트림을 열지 못했습니다. 가짜 영상은 보여 주지 않습니다."
                    }
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.ticket += 1
            self.shutdownLocked()
        }
        DispatchQueue.main.async {
            self.image = nil
        }
    }

    private func shutdownLocked() {
        running = false
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        self.session = nil
        format = nil
        formatToken = nil
        pes.removeAll()
        pmtPID = nil
        videoPID = nil
        codec = .unknown
        sps = nil
        pps = nil
        vps = nil
        packets = 0
        drewFrame = false
    }

    private func listen(_ mine: Int) {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            publishNote("미리보기 포트를 열지 못했습니다. 가짜 영상은 보여 주지 않습니다.")
            return
        }
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var timeout = timeval(tv_sec: 0, tv_usec: 400_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(8554).bigEndian
        addr.sin_addr.s_addr = in_addr_t(0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(socketFD)
            publishNote("미리보기 포트 8554를 잡지 못했습니다. 가짜 영상은 보여 주지 않습니다.")
            return
        }
        fd = socketFD
        running = true
        var buffer = [UInt8](repeating: 0, count: 2048)
        while running, mine == ticket {
            let count = recv(socketFD, &buffer, buffer.count, 0)
            if count <= 0 { continue }
            ingest(Array(buffer.prefix(count)))
        }
        if fd == socketFD {
            Darwin.close(socketFD)
            fd = -1
        }
    }

    private func ingest(_ datagram: [UInt8]) {
        packets += 1
        var bytes = datagram
        if bytes.first != 0x47, bytes.count > 12, bytes[12] == 0x47 {
            bytes.removeFirst(12)
        }
        var offset = 0
        while offset + 188 <= bytes.count {
            if bytes[offset] != 0x47 { break }
            consume(Array(bytes[offset..<(offset + 188)]))
            offset += 188
        }
        if !drewFrame, packets == 80 {
            publishNote("스트림은 들어왔지만 그림으로 풀지 못했습니다. 없는 영상은 그리지 않습니다.")
        }
    }

    private func consume(_ packet: [UInt8]) {
        let pid = (UInt16(packet[1] & 0x1F) << 8) | UInt16(packet[2])
        let start = (packet[1] & 0x40) != 0
        let adapt = (packet[3] >> 4) & 0x03
        var index = 4
        if adapt == 2 || adapt == 3 {
            let length = Int(packet[index])
            index += 1 + length
        }
        if adapt == 2 || index >= packet.count { return }
        let payload = Array(packet[index...])
        if pid == 0 {
            parsePAT(payload, start: start)
        } else if let pmtPID, pid == pmtPID {
            parsePMT(payload, start: start)
        } else if let videoPID, pid == videoPID {
            if start {
                if !pes.isEmpty { handlePES(pes) }
                pes = Data(payload)
            } else {
                pes.append(contentsOf: payload)
            }
        }
    }

    private func parsePAT(_ payload: [UInt8], start: Bool) {
        guard let section = table(payload, start: start), section.count > 12, section[0] == 0 else { return }
        let length = (Int(section[1] & 0x0F) << 8) | Int(section[2])
        let end = min(section.count, 3 + length - 4)
        var index = 8
        while index + 4 <= end {
            let program = (UInt16(section[index]) << 8) | UInt16(section[index + 1])
            let epid = (UInt16(section[index + 2] & 0x1F) << 8) | UInt16(section[index + 3])
            if program != 0 {
                pmtPID = epid
                return
            }
            index += 4
        }
    }

    private func parsePMT(_ payload: [UInt8], start: Bool) {
        guard let section = table(payload, start: start), section.count > 16, section[0] == 2 else { return }
        let length = (Int(section[1] & 0x0F) << 8) | Int(section[2])
        let end = min(section.count, 3 + length - 4)
        let info = (Int(section[10] & 0x0F) << 8) | Int(section[11])
        var index = 12 + info
        while index + 5 <= end {
            let kind = section[index]
            let epid = (UInt16(section[index + 1] & 0x1F) << 8) | UInt16(section[index + 2])
            let extra = (Int(section[index + 3] & 0x0F) << 8) | Int(section[index + 4])
            if kind == 0x1B || kind == 0x24 {
                videoPID = epid
                codec = kind == 0x1B ? .h264 : .hevc
                return
            }
            index += 5 + extra
        }
    }

    private func table(_ payload: [UInt8], start: Bool) -> [UInt8]? {
        guard start, let pointer = payload.first else { return payload }
        let skip = 1 + Int(pointer)
        guard payload.count > skip else { return nil }
        return Array(payload[skip...])
    }

    private func handlePES(_ data: Data) {
        guard data.count > 9, data[0] == 0, data[1] == 0, data[2] == 1 else { return }
        let header = Int(data[8])
        let bodyStart = 9 + header
        guard data.count > bodyStart else { return }
        let units = nalUnits(data.subdata(in: bodyStart..<data.count))
        var picture: [Data] = []
        for unit in units where !unit.isEmpty {
            let kind = nalKind(unit)
            switch codec {
            case .h264:
                if kind == 7 { sps = unit }
                else if kind == 8 { pps = unit }
                else if (1...5).contains(kind) { picture.append(unit) }
            case .hevc:
                if kind == 32 { vps = unit }
                else if kind == 33 { sps = unit }
                else if kind == 34 { pps = unit }
                else if kind <= 31 { picture.append(unit) }
            case .unknown:
                break
            }
        }
        guard !picture.isEmpty else { return }
        decode(picture)
    }

    private func nalKind(_ unit: Data) -> Int {
        switch codec {
        case .h264: return Int(unit[0] & 0x1F)
        case .hevc: return Int((unit[0] >> 1) & 0x3F)
        case .unknown: return -1
        }
    }

    private func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var marks: [Int] = []
        var index = 0
        while index + 3 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                marks.append(index)
                index += 3
            } else if index + 4 < bytes.count, bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                marks.append(index)
                index += 4
            } else {
                index += 1
            }
        }
        var units: [Data] = []
        for (offset, mark) in marks.enumerated() {
            let prefix = bytes[mark + 2] == 1 ? 3 : 4
            let start = mark + prefix
            let end = offset + 1 < marks.count ? marks[offset + 1] : bytes.count
            if end > start { units.append(Data(bytes[start..<end])) }
        }
        return units
    }

    private func decode(_ picture: [Data]) {
        guard ensureFormat() else { return }
        var sampleData = Data()
        for unit in picture {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { sampleData.append(contentsOf: $0) }
            sampleData.append(unit)
        }
        guard let format, let session else { return }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &block
        ) == noErr, let block else { return }
        sampleData.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: sampleData.count)
            }
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid)
        var size = sampleData.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return }
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
    }

    private func ensureFormat() -> Bool {
        let sets: [Data]
        switch codec {
        case .h264:
            guard let sps, let pps else { return false }
            sets = [sps, pps]
        case .hevc:
            guard let vps, let sps, let pps else { return false }
            sets = [vps, sps, pps]
        case .unknown:
            return false
        }
        let token = sets.map { $0.base64EncodedString() }.joined(separator: "|")
        if token == formatToken, session != nil { return true }
        guard let description = makeFormat(sets) else { return false }
        if let session { VTDecompressionSessionInvalidate(session) }
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refcon, _, status, _, buffer, _, _ in
                guard status == noErr, let buffer, let refcon else { return }
                Unmanaged<GoProPreview>.fromOpaque(refcon).takeUnretainedValue().publish(buffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var created: VTDecompressionSession?
        let made = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &record,
            decompressionSessionOut: &created
        )
        guard made == noErr, let created else { return false }
        format = description
        session = created
        formatToken = token
        return true
    }

    private func makeFormat(_ sets: [Data]) -> CMVideoFormatDescription? {
        if codec == .h264, sets.count >= 2 {
            return sets[0].withUnsafeBytes { spsRaw in
                sets[1].withUnsafeBytes { ppsRaw in
                    guard let spsPtr = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsPtr = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
                    var pointers = [spsPtr, ppsPtr]
                    var sizes = [spsRaw.count, ppsRaw.count]
                    return pointers.withUnsafeMutableBufferPointer { pointerBuffer in
                        sizes.withUnsafeMutableBufferPointer { sizeBuffer in
                            var description: CMVideoFormatDescription?
                            let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 2,
                                parameterSetPointers: pointerBuffer.baseAddress!,
                                parameterSetSizes: sizeBuffer.baseAddress!,
                                nalUnitHeaderLength: 4,
                                formatDescriptionOut: &description
                            )
                            return status == noErr ? description : nil
                        }
                    }
                }
            }
        }
        guard codec == .hevc, sets.count >= 3 else { return nil }
        return sets[0].withUnsafeBytes { vpsRaw in
            sets[1].withUnsafeBytes { spsRaw in
                sets[2].withUnsafeBytes { ppsRaw in
                    guard let vpsPtr = vpsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let spsPtr = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let ppsPtr = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
                    var pointers = [vpsPtr, spsPtr, ppsPtr]
                    var sizes = [vpsRaw.count, spsRaw.count, ppsRaw.count]
                    return pointers.withUnsafeMutableBufferPointer { pointerBuffer in
                        sizes.withUnsafeMutableBufferPointer { sizeBuffer in
                            var description: CMVideoFormatDescription?
                            let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: pointerBuffer.baseAddress!,
                                parameterSetSizes: sizeBuffer.baseAddress!,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &description
                            )
                            return status == noErr ? description : nil
                        }
                    }
                }
            }
        }
    }

    private func publish(_ buffer: CVImageBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastDraw) > 0.08 else { return }
        lastDraw = now
        drewFrame = true
        let source = CIImage(cvPixelBuffer: buffer)
        guard let rendered = ciContext.createCGImage(source, from: source.extent) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.image = rendered
            self?.note = ""
        }
    }

    private func publishNote(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.image == nil else { return }
            self.note = text
        }
    }
}
