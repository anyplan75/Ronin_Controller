import CoreBluetooth
import SwiftUI

/// 처음 연결에서 고르는 기판입니다. 이름은 블루투스 광고입니다.
struct SeenBoard: Identifiable {
    var id: UUID
    var name: String
    var kind: Kind
    var peripheral: CBPeripheral

    enum Kind {
        case olimex
        case c3

        var title: String {
            switch self {
            case .olimex: return "올리멕스"
            case .c3: return "C3"
            }
        }

        var suggestedIP: String {
            switch self {
            case .olimex: return "192.168.10.151"
            case .c3: return "192.168.10.152"
            }
        }
    }
}

/// 기판이 알려 준 MAC 입니다. 공유기 고정 주소 예약에 씁니다.
struct BoardRadios: Equatable {
    var wifi = ""
    var ethernet = ""
    var hotspot = ""

    static func parse(_ object: [String: Any]) -> BoardRadios {
        BoardRadios(
            wifi: (object["wifiMac"] as? String) ?? "",
            ethernet: (object["ethMac"] as? String) ?? "",
            hotspot: (object["apMac"] as? String) ?? ""
        )
    }
}

/// 기판 블루투스에 와이파이 이름과 비밀번호를 넣고, 붙은 주소를 받습니다.
final class BoardProvision: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "7b1e9c10-5a20-4c31-8d10-726f6e696e31")
    static let characteristic = CBUUID(string: "7b1e9c11-5a20-4c31-8d10-726f6e696e31")

    @Published private(set) var boards: [SeenBoard] = []
    @Published private(set) var phase = "블루투스를 준비하는 중입니다."
    @Published private(set) var radios = BoardRadios()
    private var manager: CBCentralManager?
    private var waiter: ((Bool, String, Int, BoardRadios) -> Void)?
    private enum Purpose { case idle, readMac, join }
    private var purpose = Purpose.idle

    func start() {
        if manager == nil {
            manager = CBCentralManager(delegate: self, queue: .main)
        } else if manager?.state == .poweredOn {
            scan()
        }
    }

    func stop() {
        manager?.stopScan()
    }

    func identify(board: SeenBoard) async -> BoardRadios {
        guard let manager, manager.state == .poweredOn else { return BoardRadios() }
        phase = "\(board.name) 의 MAC 을 읽는 중입니다."
        purpose = .readMac
        target = board.peripheral
        board.peripheral.delegate = self
        return await withCheckedContinuation { continuation in
            waiter = { _, _, _, radios in
                continuation.resume(returning: radios)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.waiter != nil, self.purpose == .readMac else { return }
                self.finish(ok: false, host: "", port: 0, note: "MAC 은 기판이 알려 주기 전에는 비어 있습니다.")
            }
            manager.connect(board.peripheral, options: nil)
        }
    }

    func send(board: SeenBoard, ssid: String, password: String, ip: String) async -> (ok: Bool, host: String, port: Int, radios: BoardRadios) {
        guard let manager, manager.state == .poweredOn else {
            return (false, "", 0, radios)
        }
        phase = "\(board.name) 에 집 와이파이를 넣는 중입니다."
        purpose = .join
        pendingSSID = ssid
        pendingPass = password
        pendingIP = ip
        target = board.peripheral
        board.peripheral.delegate = self
        return await withCheckedContinuation { continuation in
            waiter = { ok, host, port, radios in
                continuation.resume(returning: (ok, host, port, radios))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, self.waiter != nil else { return }
                self.finish(ok: false, host: "", port: 0, note: "기판이 20초 안에 답하지 않았습니다.")
            }
            manager.connect(board.peripheral, options: nil)
        }
    }

    private var pendingSSID = ""
    private var pendingPass = ""
    private var pendingIP = ""
    private var target: CBPeripheral?

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            scan()
        } else {
            phase = "블루투스가 꺼져 있습니다."
        }
    }

    private func scan() {
        phase = "Ronin-Olimex 와 Ronin-C3 를 찾는 중입니다."
        manager?.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let kind: SeenBoard.Kind?
        if name.contains("Olimex") {
            kind = .olimex
        } else if name.contains("C3") {
            kind = .c3
        } else {
            kind = nil
        }
        guard let kind else { return }
        let title = name.isEmpty ? kind.title : name
        if let index = boards.firstIndex(where: { $0.id == peripheral.identifier }) {
            boards[index] = SeenBoard(id: peripheral.identifier, name: title, kind: kind, peripheral: peripheral)
        } else {
            boards.append(SeenBoard(id: peripheral.identifier, name: title, kind: kind, peripheral: peripheral))
        }
        phase = "기판 \(boards.count)대를 찾았습니다."
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        phase = "설정을 보내는 중입니다."
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(ok: false, host: "", port: 0, note: "블루투스에 붙지 못했습니다.")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            finish(ok: false, host: "", port: 0, note: "설정 서비스를 찾지 못했습니다.")
            return
        }
        peripheral.discoverCharacteristics([Self.characteristic], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.characteristic }) else {
            finish(ok: false, host: "", port: 0, note: "설정 칸을 찾지 못했습니다.")
            return
        }
        peripheral.setNotifyValue(true, for: characteristic)
        if purpose == .readMac {
            peripheral.readValue(for: characteristic)
            return
        }
        let payload: [String: String] = ["ssid": pendingSSID, "pass": pendingPass, "ip": pendingIP]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            finish(ok: false, host: "", port: 0, note: "설정을 만들지 못했습니다.")
            return
        }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let parsed = BoardRadios.parse(object)
        if !parsed.wifi.isEmpty || !parsed.ethernet.isEmpty { radios = parsed }
        if purpose == .readMac, object["ok"] == nil {
            finish(ok: true, host: "", port: 0, note: parsed.wifi.isEmpty ? "MAC 이 비어 있습니다." : "MAC 을 읽었습니다.")
            return
        }
        let ok = object["ok"] as? Bool ?? false
        let host = object["ip"] as? String ?? ""
        let port = object["port"] as? Int ?? 0
        let reason = object["reason"] as? String ?? ""
        finish(ok: ok, host: host, port: port, note: ok ? "\(host):\(port) 로 붙었습니다." : reason)
    }

    private func finish(ok: Bool, host: String, port: Int, note: String) {
        phase = note.isEmpty ? (ok ? "망에 붙었습니다." : "붙지 못했습니다.") : note
        let pending = waiter
        waiter = nil
        purpose = .idle
        if let target {
            manager?.cancelPeripheralConnection(target)
        }
        pending?(ok, host, port, radios)
    }
}

/// 처음 연결 창입니다. 한 단계에 할 일이 하나이고, 비밀번호는 기판에만 보냅니다.
struct FirstJoinSheet: View {
    @StateObject private var radio = BoardProvision()
    @State private var picked: UUID?
    @State private var ssid = "JMEDIA"
    @State private var password = ""
    @State private var ip = ""
    @State private var busy = false
    @State private var reading = false
    var onReady: (SeenBoard.Kind, String, Int, BoardRadios) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("기판 전원만 켜세요. USB 선은 펌웨어를 넣을 때만 씁니다. 이 단계에서 앱은 블루투스 이름 Ronin-Olimex 와 Ronin-C3 를 찾습니다.")
                        .font(.caption)
                    if radio.boards.isEmpty {
                        Text(radio.phase)
                    }
                    ForEach(radio.boards) { board in
                        Button {
                            choose(board)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(board.kind == .olimex ? "올리멕스 ESP32-PoE" : "C3 기판", systemImage: board.kind == .olimex ? "server.rack" : "dot.radiowaves.left.and.right")
                                    .font(.headline)
                                Text(board.kind == .olimex
                                     ? "하는 일: 액션 카메라입니다. 고프로, 오즈모, 인스타를 이 기판 블루투스로 붙입니다. 로닌 짐벌은 움직이지 않습니다."
                                     : "하는 일: 로닌 짐벌 또는 울란지 조명입니다. 어떤 일을 맡길지는 스튜디오의 기판 등록에서 하나만 고릅니다. 지금은 와이파이에 넣기만 합니다.")
                                    .font(.caption)
                                Text("블루투스 이름 \(board.name)")
                                    .font(.caption.weight(.semibold))
                                if picked == board.id {
                                    Text(reading ? "MAC 을 읽는 중입니다." : macLine(radio.radios, kind: board.kind))
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .buttonStyle(DeskButtonStyle(selected: picked == board.id, expand: true))
                    }
                } header: {
                    Text("1. 기판 찾기")
                }

                if let board = radio.boards.first(where: { $0.id == picked }) {
                    Section {
                        Text("공유기의 MAC 예약에 아래 주소를 적으면 이 기판이 항상 같은 192.168.10 번호를 받습니다. 와이파이로 쓸 때는 와이파이 MAC, 올리멕스를 랜 케이블로 쓸 때는 이더넷 MAC 입니다.")
                            .font(.caption)
                        Text(macLine(radio.radios, kind: board.kind))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        Text("제안 주소 \(board.kind.suggestedIP). 고정 주소를 비우면 공유기가 번호를 줍니다.")
                            .font(.caption)
                    } header: {
                        Text("2. 고른 기판의 주소표")
                    }

                    Section {
                        Text("이 \(board.kind == .olimex ? "올리멕스" : "C3") 를 집 공유기 JMEDIA 에 넣습니다. 비밀번호는 기판 저장소로만 가고, 앱 화면 소스에는 적지 않습니다.")
                            .font(.caption)
                        TextField("와이파이 이름", text: $ssid)
                        SecureField("와이파이 비밀번호", text: $password)
                        TextField("고정 주소, 비우면 공유기가 줍니다", text: $ip)
                    } header: {
                        Text("3. 집 와이파이에 넣기")
                    }

                    Section {
                        Button(busy ? "넣는 중" : "이 기판을 망에 넣기") {
                            Task { await send() }
                        }
                        .buttonStyle(DeskButtonStyle(selected: true, expand: true))
                        .disabled(busy || ssid.trimmingCharacters(in: .whitespaces).isEmpty)
                        Text(radio.phase)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("처음 연결")
            .toolbar {
                Button("닫기") { dismiss() }
                    .buttonStyle(DeskButtonStyle())
            }
            .onAppear { radio.start() }
            .onDisappear { radio.stop() }
        }
    }

    private func macLine(_ radios: BoardRadios, kind: SeenBoard.Kind) -> String {
        if radios.wifi.isEmpty && radios.ethernet.isEmpty {
            return "MAC 은 기판이 알려 주면 여기에 나타납니다."
        }
        var lines = ["와이파이 MAC \(radios.wifi.isEmpty ? "없음" : radios.wifi)"]
        if kind == .olimex {
            lines.append("이더넷 MAC \(radios.ethernet.isEmpty ? "없음" : radios.ethernet)")
        }
        return lines.joined(separator: "\n")
    }

    private func choose(_ board: SeenBoard) {
        picked = board.id
        if ip.isEmpty { ip = board.kind.suggestedIP }
        reading = true
        Task {
            _ = await radio.identify(board: board)
            reading = false
        }
    }

    private func send() async {
        guard let board = radio.boards.first(where: { $0.id == picked }) else { return }
        busy = true
        let result = await radio.send(
            board: board,
            ssid: ssid.trimmingCharacters(in: .whitespaces),
            password: password,
            ip: ip.trimmingCharacters(in: .whitespaces)
        )
        busy = false
        password = ""
        guard result.ok, !result.host.isEmpty else { return }
        let port = result.port == 0 ? (board.kind == .olimex ? 81 : 82) : result.port
        onReady(board.kind, result.host, port, result.radios)
        dismiss()
    }
}
