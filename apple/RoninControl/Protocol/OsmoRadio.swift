import CoreBluetooth
import Foundation

struct OsmoLive: Equatable, Sendable {
    var phase = "연결 안 됨"
    var mode: Int?
    var status: Int?
    var resolution: Int?
    var fps: Int?
    var eis: Int?
    var battery: Int?
    var modeName = ""
    var product = ""
    var lastError = ""
    var ready = false
}

/// 오즈모 액션·360의 공식 블루투스(R SDK, 서비스 FFF0)입니다.
/// 고프로 Open GoPro(FEA6)도, HM-10(FFE0)도 아닙니다. 로닌 기판을 거치지 않습니다.
/// 한 번 연결한 세션으로만 명령을 보냅니다. 요청마다 붙였다 끊지 않습니다.
/// 포켓, 모바일, 나노는 이 프로토콜 대상이 아니라 여기서 명령을 만들지 않습니다.
final class OsmoRadio: NSObject, ObservableObject {
    @Published var seen: [SeenOsmo] = []
    @Published var live: [UUID: OsmoLive] = [:]
    @Published var scanning = false
    @Published var bluetoothNote = "블루투스를 확인하는 중"

    struct SeenOsmo: Identifiable {
        var id: UUID { identifier }
        var identifier: UUID
        var name: String
        var rssi: Int
    }

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var links: [UUID: Link] = [:]
    private var deviceByPeripheral: [UUID: UUID] = [:]
    private var connectWait: FrameWait<Void>?
    private var serviceWait: FrameWait<Void>?
    private var characteristicWait: FrameWait<Void>?
    private var notifyWait: FrameWait<Void>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func isReady(_ deviceId: UUID) -> Bool {
        links[deviceId]?.ready == true
    }

    func startScan() {
        guard central.state == .poweredOn else {
            bluetoothNote = bluetoothMessage(central.state)
            return
        }
        seen.removeAll()
        scanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.stopScan()
        }
    }

    func stopScan() {
        central.stopScan()
        scanning = false
    }

    func pair(device: DeviceRecord, senderId: UInt32, mac: [UInt8], verifyMode: UInt8) async -> CallOutcome {
        guard device.osmoModel.supportsRSDK, let cameraId = device.osmoModel.commandDeviceId else {
            return CallOutcome(ok: false, text: "\(device.name): 이 기종은 공개 R SDK에 없습니다.", practice: false)
        }
        do {
            let link = try await connectLink(device)
            try await link.lane.run {
                try await self.handshake(link: link, device: device, senderId: senderId, mac: mac, verifyMode: verifyMode, cameraId: cameraId)
            }
            return CallOutcome(ok: true, text: live[device.id]?.phase ?? "연결됨", practice: false)
        } catch {
            publish(device.id) { $0.ready = false; $0.phase = "연결 실패"; $0.lastError = error.localizedDescription }
            return CallOutcome(ok: false, text: "\(device.name): \(error.localizedDescription)", practice: false)
        }
    }

    func setMode(_ device: DeviceRecord, mode: Int) async -> CallOutcome {
        guard let cameraId = device.osmoModel.commandDeviceId else {
            return CallOutcome(ok: false, text: "모드를 보낼 기기 번호가 없습니다.", practice: false)
        }
        guard OsmoCatalog.writableModes(for: device.osmoModel).contains(where: { $0.0 == mode }) else {
            return CallOutcome(ok: false, text: "이 기종 문서에 없는 모드입니다.", practice: false)
        }
        return await command(device, cmdSet: 0x1D, cmdId: 0x04, cmdType: 0x01, payload: modePayload(cameraId, UInt8(mode)), label: "모드")
    }

    func record(_ device: DeviceRecord, start: Bool) async -> CallOutcome {
        guard let cameraId = device.osmoModel.commandDeviceId else {
            return CallOutcome(ok: false, text: "\(device.name): 녹화 명령을 보낼 기기 번호가 없습니다.", practice: false)
        }
        var payload = le32(cameraId)
        payload.append(start ? 0x00 : 0x01)
        payload.append(contentsOf: [0, 0, 0, 0])
        return await command(device, cmdSet: 0x1D, cmdId: 0x03, cmdType: 0x01, payload: payload, label: start ? "촬영 시작" : "촬영 중지")
    }

    private func command(
        _ device: DeviceRecord,
        cmdSet: UInt8,
        cmdId: UInt8,
        cmdType: UInt8,
        payload: [UInt8],
        label: String
    ) async -> CallOutcome {
        guard let link = links[device.id], link.ready else {
            return CallOutcome(ok: false, text: "\(device.name): 먼저 블루투스 연결을 끝내세요.", practice: false)
        }
        do {
            let text = try await link.lane.run {
                let seq = link.nextSeq()
                let frame = DjiRFrame.build(cmdSet: cmdSet, cmdId: cmdId, cmdType: cmdType, seq: seq, payload: payload)
                try await self.write(frame, link: link)
                let reply = try await self.nextFrame(on: link, timeout: 4, matching: { $0.cmdSet == cmdSet && $0.cmdId == cmdId && $0.isResponse })
                let code = reply.payload.first ?? 0xFF
                if code != 0 {
                    throw CallError.ble("\(label) 거절 코드 \(code)")
                }
                return "\(label) 수락"
            }
            return CallOutcome(ok: true, text: "\(device.name): \(text)", practice: false)
        } catch {
            return CallOutcome(ok: false, text: "\(device.name): \(error.localizedDescription)", practice: false)
        }
    }

    private func connectLink(_ device: DeviceRecord) async throws -> Link {
        if let link = links[device.id], link.peripheral.state == .connected, link.write != nil {
            return link
        }
        stopScan()
        let peripheral = try peripheral(for: device)
        peripheral.delegate = self
        if peripheral.state != .connected {
            try await waitConnect(peripheral)
        }
        let link = links[device.id] ?? Link(peripheral: peripheral)
        links[device.id] = link
        deviceByPeripheral[peripheral.identifier] = device.id
        if link.write == nil {
            try await waitService(peripheral)
            try await waitCharacteristics(peripheral)
        }
        guard link.write != nil else { throw CallError.ble("쓰기 특성 FFF5를 찾지 못했습니다.") }
        if !link.notified {
            try await waitNotify(peripheral, link: link)
        }
        return link
    }

    private func peripheral(for device: DeviceRecord) throws -> CBPeripheral {
        if let text = UUID(uuidString: device.bleIdentifier), let found = peripherals[text] {
            return found
        }
        if let text = UUID(uuidString: device.bleIdentifier) {
            let known = central.retrievePeripherals(withIdentifiers: [text])
            if let first = known.first {
                peripherals[first.identifier] = first
                return first
            }
        }
        throw CallError.ble("저장된 카메라를 찾지 못했습니다. 찾기를 다시 하세요.")
    }

    private func handshake(
        link: Link,
        device: DeviceRecord,
        senderId: UInt32,
        mac: [UInt8],
        verifyMode: UInt8,
        cameraId: UInt32
    ) async throws {
        _ = cameraId
        let verify = UInt16.random(in: 0...9999)
        publish(device.id) {
            $0.phase = verifyMode == 1 ? "카메라 확인 창을 기다리는 중. 숫자 \(verify)" : "저장된 페어링으로 연결 중"
            $0.lastError = ""
        }
        let payload = connectionPayload(senderId: senderId, mac: mac, verifyMode: verifyMode, verify: verify)
        let seq = link.nextSeq()
        let frame = DjiRFrame.build(cmdSet: 0x00, cmdId: 0x19, cmdType: 0x02, seq: seq, payload: payload)
        try await write(frame, link: link)

        let deadline = Date().addingTimeInterval(30)
        var approved: DjiRFrame.Parsed?
        while Date() < deadline {
            let incoming = try await nextFrame(on: link, timeout: deadline.timeIntervalSinceNow, matching: { _ in true })
            if incoming.cmdSet == 0x00 && incoming.cmdId == 0x19 && !incoming.isResponse && incoming.payload.count >= 29 {
                let mode = incoming.payload[26]
                let data = UInt16(incoming.payload[27]) | (UInt16(incoming.payload[28]) << 8)
                if mode == 2 {
                    if data != 0 { throw CallError.ble("카메라가 연결을 거절했습니다.") }
                    approved = incoming
                    break
                }
            }
        }
        guard let approved else { throw CallError.ble("카메라의 연결 허용이 오지 않았습니다.") }

        var ack = le32(senderId)
        ack.append(0)
        ack.append(contentsOf: [0, 0, 0, 0])
        let ackFrame = DjiRFrame.build(cmdSet: 0x00, cmdId: 0x19, cmdType: 0x20, seq: approved.seq, payload: ack)
        try await write(ackFrame, link: link)
        link.ready = true
        publish(device.id) { $0.ready = true; $0.phase = "프로토콜 연결됨" }

        let versionSeq = link.nextSeq()
        let version = DjiRFrame.build(cmdSet: 0x00, cmdId: 0x00, cmdType: 0x02, seq: versionSeq, payload: [])
        try await write(version, link: link)
        if let reply = try? await nextFrame(on: link, timeout: 2, matching: { $0.cmdSet == 0x00 && $0.cmdId == 0x00 }) {
            let product = productText(reply.payload)
            publish(device.id) { $0.product = product }
        }
        let subSeq = link.nextSeq()
        let sub = DjiRFrame.build(cmdSet: 0x1D, cmdId: 0x05, cmdType: 0x00, seq: subSeq, payload: [3, 20, 0, 0, 0, 0])
        try await write(sub, link: link)
    }

    private func productText(_ payload: [UInt8]) -> String {
        guard payload.count >= 18 else { return "" }
        let bytes = payload[2..<18]
        return String(bytes: bytes.filter { $0 != 0 }, encoding: .utf8) ?? ""
    }

    private func connectionPayload(senderId: UInt32, mac: [UInt8], verifyMode: UInt8, verify: UInt16) -> [UInt8] {
        var payload = le32(senderId)
        payload.append(UInt8(min(6, mac.count)))
        var mac16 = [UInt8](repeating: 0, count: 16)
        for index in 0..<min(6, mac.count) { mac16[index] = mac[index] }
        payload.append(contentsOf: mac16)
        payload.append(contentsOf: le32(0))
        payload.append(0)
        payload.append(verifyMode)
        payload.append(UInt8(verify & 0xFF))
        payload.append(UInt8((verify >> 8) & 0xFF))
        payload.append(contentsOf: [0, 0, 0, 0])
        return payload
    }

    private func modePayload(_ deviceId: UInt32, _ mode: UInt8) -> [UInt8] {
        var payload = le32(deviceId)
        payload.append(mode)
        payload.append(contentsOf: [0x01, 0x47, 0x39, 0x36])
        return payload
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private func write(_ bytes: [UInt8], link: Link) async throws {
        guard let characteristic = link.write else { throw CallError.ble("쓰기 통로가 없습니다.") }
        let data = Data(bytes)
        let kind: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        let chunk = max(20, link.peripheral.maximumWriteValueLength(for: kind))
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            let piece = data.subdata(in: offset..<end)
            offset = end
            if kind == .withResponse {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    DispatchQueue.main.async {
                        let wait = FrameWait(cont)
                        link.writeWait = wait
                        link.peripheral.writeValue(piece, for: characteristic, type: .withResponse)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            if link.writeWait === wait {
                                link.writeWait = nil
                                wait.fail(CallError.ble("블루투스 쓰기가 끝나지 않았습니다."))
                            }
                        }
                    }
                }
            } else {
                await MainActor.run {
                    link.peripheral.writeValue(piece, for: characteristic, type: .withoutResponse)
                }
            }
        }
    }

    private func nextFrame(
        on link: Link,
        timeout: TimeInterval,
        matching match: @escaping (DjiRFrame.Parsed) -> Bool
    ) async throws -> DjiRFrame.Parsed {
        let deadline = Date().addingTimeInterval(max(0.2, timeout))
        while Date() < deadline {
            let frame = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<DjiRFrame.Parsed, Error>) in
                DispatchQueue.main.async {
                    if let index = link.inbox.firstIndex(where: match) {
                        cont.resume(returning: link.inbox.remove(at: index))
                        return
                    }
                    let wait = FrameWait(cont)
                    wait.match = match
                    link.waiters.append(wait)
                    DispatchQueue.main.asyncAfter(deadline: .now() + max(0.2, deadline.timeIntervalSinceNow)) {
                        if let index = link.waiters.firstIndex(where: { $0 === wait }) {
                            link.waiters.remove(at: index)
                        }
                        wait.fail(CallError.ble("응답 시간이 지났습니다."))
                    }
                }
            }
            if match(frame) { return frame }
        }
        throw CallError.ble("원하는 답이 오지 않았습니다.")
    }

    private func waitConnect(_ peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                let wait = FrameWait(cont)
                self.connectWait = wait
                self.central.connect(peripheral, options: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    if self.connectWait === wait {
                        self.connectWait = nil
                        wait.fail(CallError.ble("블루투스 연결 시간이 지났습니다."))
                    }
                }
            }
        }
    }

    private func waitService(_ peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                let wait = FrameWait(cont)
                self.serviceWait = wait
                peripheral.discoverServices([CBUUID(string: "FFF0")])
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    if self.serviceWait === wait {
                        self.serviceWait = nil
                        wait.fail(CallError.ble("서비스 FFF0을 찾지 못했습니다."))
                    }
                }
            }
        }
    }

    private func waitCharacteristics(_ peripheral: CBPeripheral) async throws {
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: "FFF0") }) else {
            throw CallError.ble("서비스 FFF0이 없습니다.")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                let wait = FrameWait(cont)
                self.characteristicWait = wait
                peripheral.discoverCharacteristics([CBUUID(string: "FFF4"), CBUUID(string: "FFF5")], for: service)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    if self.characteristicWait === wait {
                        self.characteristicWait = nil
                        wait.fail(CallError.ble("특성 FFF4/FFF5를 찾지 못했습니다."))
                    }
                }
            }
        }
    }

    private func waitNotify(_ peripheral: CBPeripheral, link: Link) async throws {
        guard let notify = link.notify else { throw CallError.ble("알림 특성 FFF4가 없습니다.") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                let wait = FrameWait(cont)
                self.notifyWait = wait
                peripheral.setNotifyValue(true, for: notify)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    if self.notifyWait === wait {
                        self.notifyWait = nil
                        wait.fail(CallError.ble("알림을 켜지 못했습니다."))
                    }
                }
            }
        }
        link.notified = true
    }

    private func publish(_ id: UUID, _ change: @escaping (inout OsmoLive) -> Void) {
        DispatchQueue.main.async {
            var item = self.live[id] ?? OsmoLive()
            change(&item)
            self.live[id] = item
        }
    }

    private func bluetoothMessage(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "블루투스가 켜져 있습니다."
        case .poweredOff: return "블루투스가 꺼져 있습니다."
        case .unauthorized: return "블루투스 권한이 없습니다. 설정에서 허용하세요."
        case .unsupported: return "이 기기는 블루투스를 지원하지 않습니다."
        default: return "블루투스를 준비하는 중입니다."
        }
    }

    private func link(for peripheral: CBPeripheral) -> Link? {
        guard let deviceId = deviceByPeripheral[peripheral.identifier] else { return nil }
        return links[deviceId]
    }
}

private final class Lane {
    private var tail: Task<Void, Never> = Task {}

    func run<T>(_ body: @escaping () async throws -> T) async throws -> T {
        let previous = tail
        return try await withCheckedThrowingContinuation { cont in
            let next = Task {
                await previous.value
                do {
                    cont.resume(returning: try await body())
                } catch {
                    cont.resume(throwing: error)
                }
            }
            tail = Task { await next.value }
        }
    }
}

private final class Link {
    let peripheral: CBPeripheral
    let lane = Lane()
    var write: CBCharacteristic?
    var notify: CBCharacteristic?
    var buffer = DjiFrameBuffer()
    var seq: UInt16 = 0
    var ready = false
    var notified = false
    var inbox: [DjiRFrame.Parsed] = []
    var waiters: [FrameWait<DjiRFrame.Parsed>] = []
    var writeWait: FrameWait<Void>?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }

    func nextSeq() -> UInt16 {
        seq &+= 1
        return seq
    }
}

private final class FrameWait<T> {
    var resumed = false
    var match: ((DjiRFrame.Parsed) -> Bool)?
    private let cont: CheckedContinuation<T, Error>

    init(_ cont: CheckedContinuation<T, Error>) {
        self.cont = cont
    }

    func succeed(_ value: T) {
        guard !resumed else { return }
        resumed = true
        cont.resume(returning: value)
    }

    func fail(_ error: Error) {
        guard !resumed else { return }
        resumed = true
        cont.resume(throwing: error)
    }
}

extension OsmoRadio: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothNote = bluetoothMessage(central.state)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let looksLikeDji = data.map { bytes in
            let raw = [UInt8](bytes)
            return raw.count > 4 && raw[0] == 0xAA && raw[1] == 0x08 && raw[4] == 0xFA
        } ?? false
        let named = name.localizedCaseInsensitiveContains("osmo")
            || name.localizedCaseInsensitiveContains("action")
            || name.localizedCaseInsensitiveContains("dji")
        guard named || looksLikeDji else { return }
        peripherals[peripheral.identifier] = peripheral
        let label = name.isEmpty ? "이름 없는 DJI" : name
        if let index = seen.firstIndex(where: { $0.identifier == peripheral.identifier }) {
            seen[index] = SeenOsmo(identifier: peripheral.identifier, name: label, rssi: RSSI.intValue)
        } else {
            seen.append(SeenOsmo(identifier: peripheral.identifier, name: label, rssi: RSSI.intValue))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectWait?.succeed(())
        connectWait = nil
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectWait?.fail(error ?? CallError.ble("블루투스 연결에 실패했습니다."))
        connectWait = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            serviceWait?.fail(error)
        } else {
            serviceWait?.succeed(())
        }
        serviceWait = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let link = link(for: peripheral) {
            link.notify = service.characteristics?.first { $0.uuid == CBUUID(string: "FFF4") }
            link.write = service.characteristics?.first { $0.uuid == CBUUID(string: "FFF5") }
        }
        if let error {
            characteristicWait?.fail(error)
        } else {
            characteristicWait?.succeed(())
        }
        characteristicWait = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            notifyWait?.fail(error)
        } else {
            notifyWait?.succeed(())
        }
        notifyWait = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = link(for: peripheral) else { return }
        if let error {
            link.writeWait?.fail(error)
        } else {
            link.writeWait?.succeed(())
        }
        link.writeWait = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let link = link(for: peripheral), let deviceId = deviceByPeripheral[peripheral.identifier] else { return }
        let frames = link.buffer.append(characteristic.value ?? Data())
        for frame in frames {
            if frame.cmdSet == 0x1D && frame.cmdId == 0x02 {
                applyStatus(deviceId, frame.payload)
            } else if frame.cmdSet == 0x1D && frame.cmdId == 0x06 {
                applyName(deviceId, frame.payload)
            }
            if let index = link.waiters.firstIndex(where: { $0.match?(frame) ?? true }) {
                let wait = link.waiters.remove(at: index)
                wait.succeed(frame)
            } else {
                link.inbox.append(frame)
                if link.inbox.count > 30 { link.inbox.removeFirst() }
            }
        }
    }

    private func applyStatus(_ deviceId: UUID, _ payload: [UInt8]) {
        guard payload.count >= 5 else { return }
        var item = live[deviceId] ?? OsmoLive()
        item.mode = Int(payload[0])
        item.status = Int(payload[1])
        item.resolution = Int(payload[2])
        item.fps = Int(payload[3])
        item.eis = Int(payload[4])
        if payload.count > 37 { item.battery = Int(payload[37]) }
        live[deviceId] = item
    }

    private func applyName(_ deviceId: UUID, _ payload: [UInt8]) {
        guard payload.count >= 3 else { return }
        let length = min(Int(payload[1]), 21)
        guard payload.count >= 2 + length else { return }
        let name = String(bytes: payload[2..<(2 + length)].filter { $0 != 0 }, encoding: .utf8) ?? ""
        var item = live[deviceId] ?? OsmoLive()
        item.modeName = name
        live[deviceId] = item
    }
}
