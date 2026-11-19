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
    /// 기판마다 따로 둔 MAC 입니다. 한 대의 주소가 다른 대에 덮이지 않습니다.
    @Published private(set) var radiosByBoard: [UUID: BoardRadios] = [:]
    private var manager: CBCentralManager?
    private var waiter: ((Bool, String, Int, BoardRadios) -> Void)?
    private enum Purpose { case idle, readMac, join }
    private var purpose = Purpose.idle
    private var job = 0

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
        phase = "\(board.kind.title) 의 MAC 을 읽는 중입니다. 다른 기판은 건드리지 않습니다."
        purpose = .readMac
        job += 1
        let token = job
        target = board.peripheral
        board.peripheral.delegate = self
        return await withCheckedContinuation { continuation in
            waiter = { _, _, _, radios in
                continuation.resume(returning: radios)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.job == token, self.waiter != nil, self.purpose == .readMac else { return }
                self.finish(ok: false, host: "", port: 0, note: "MAC 은 기판이 알려 주기 전에는 비어 있습니다.")
            }
            manager.connect(board.peripheral, options: nil)
        }
    }

    func send(board: SeenBoard, ssid: String, password: String, ip: String) async -> (ok: Bool, host: String, port: Int, radios: BoardRadios) {
        guard let manager, manager.state == .poweredOn else {
            return (false, "", 0, radiosByBoard[board.id] ?? BoardRadios())
        }
        phase = "\(board.kind.title) 만 집 와이파이에 넣는 중입니다."
        purpose = .join
        job += 1
        let token = job
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
                guard let self, self.job == token, self.waiter != nil else { return }
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
        phase = boards.count > 1
            ? "기판 \(boards.count)대를 찾았습니다. 한 대씩 따로 설정합니다."
            : "기판 1대를 찾았습니다."
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
        guard peripheral.identifier == target?.identifier,
              let data = characteristic.value,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let parsed = BoardRadios.parse(object)
        if !parsed.wifi.isEmpty || !parsed.ethernet.isEmpty {
            radiosByBoard[peripheral.identifier] = parsed
        }
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
        let id = target?.identifier ?? UUID()
        pending?(ok, host, port, radiosByBoard[id] ?? BoardRadios())
    }
}

/// 처음 연결 창입니다. 한 번에 기판 한 대만 설정합니다.
struct FirstJoinSheet: View {
    @StateObject private var radio = BoardProvision()
    @State private var editing: UUID?
    @State private var finished: [UUID: String] = [:]
    @State private var boardName = ""
    @State private var ssid = "JMEDIA"
    @State private var password = ""
    @State private var ip = ""
    @State private var busy = false
    @State private var reading = false
    var onReady: (SeenBoard.Kind, String, Int, BoardRadios, String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let board = radio.boards.first(where: { $0.id == editing }) {
                    oneBoard(board)
                } else {
                    boardList
                }
            }
            .navigationTitle(editing == nil ? "처음 연결" : "이 기판만 설정")
            .toolbar {
                if editing == nil {
                    Button("닫기") { dismiss() }
                        .buttonStyle(DeskButtonStyle())
                } else {
                    Button("목록으로") {
                        editing = nil
                        password = ""
                    }
                    .buttonStyle(DeskButtonStyle())
                    .disabled(busy)
                }
            }
            .onAppear { radio.start() }
            .onDisappear { radio.stop() }
        }
    }

    private var boardList: some View {
        Section {
            Text("올리멕스와 C3는 설정이 따로입니다. 하나를 골라 이름, 와이파이, 주소를 넣고 끝내세요. 그 다음에 다른 기판을 고릅니다. 한 화면의 값이 두 기판에 같이 들어가지 않습니다.")
                .font(.caption)
            if radio.boards.isEmpty {
                Text(radio.phase)
            }
            ForEach(radio.boards) { board in
                Button {
                    open(board)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(board.kind == .olimex ? "올리멕스 ESP32-PoE" : "C3 기판", systemImage: board.kind == .olimex ? "server.rack" : "dot.radiowaves.left.and.right")
                            .font(.headline)
                        Text(board.kind == .olimex
                             ? "액션 카메라 기판입니다. 이 줄을 누르면 올리멕스만 설정합니다."
                             : "로닌 또는 조명 기판입니다. 이 줄을 누르면 C3만 설정합니다.")
                            .font(.caption)
                        Text("블루투스 이름 \(board.name)")
                            .font(.caption.weight(.semibold))
                        if let host = finished[board.id] {
                            Text("이 기판 설정 끝 · \(host)")
                                .font(.caption.weight(.bold))
                        } else {
                            Text("아직 이 기판은 설정하지 않았습니다")
                                .font(.caption)
                        }
                    }
                }
                .buttonStyle(DeskButtonStyle(selected: finished[board.id] != nil, expand: true))
            }
            if !radio.boards.isEmpty, radio.boards.allSatisfy({ finished[$0.id] != nil }) {
                Button("두 기판 설정을 마칩니다") { dismiss() }
                    .buttonStyle(DeskButtonStyle(selected: true, expand: true))
            }
        } header: {
            Text("기판을 하나 고르세요")
        }
    }

    private func oneBoard(_ board: SeenBoard) -> some View {
        Group {
            Section {
                Text(board.kind == .olimex
                     ? "지금 설정하는 기판은 올리멕스 ESP32-PoE 입니다. C3 값은 이 화면에 없습니다."
                     : "지금 설정하는 기판은 C3 입니다. 올리멕스 값은 이 화면에 없습니다.")
                    .font(.caption.weight(.semibold))
                Text("블루투스 이름 \(board.name)")
                    .font(.caption)
                Text(reading ? "이 기판의 MAC 을 읽는 중입니다." : macLine(radio.radiosByBoard[board.id] ?? BoardRadios(), kind: board.kind))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text(board.kind == .olimex ? "올리멕스만" : "C3만")
            }
            Section {
                TextField("이 기판의 이름", text: $boardName)
                TextField("이 기판이 붙을 와이파이 이름", text: $ssid)
                SecureField("이 기판에 넣을 비밀번호", text: $password)
                TextField("이 기판의 고정 주소, 비우면 공유기가 줍니다", text: $ip)
                Text("고정 주소는 192.168.10.x 만 됩니다. 이 기판의 제안 주소는 \(board.kind.suggestedIP) 입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("이 기판의 이름과 와이파이")
            }
            Section {
                Button(busy ? "넣는 중" : "이 \(board.kind.title) 만 망에 넣기") {
                    Task { await send(board) }
                }
                .buttonStyle(DeskButtonStyle(selected: true, expand: true))
                .disabled(busy || reading || ssid.trimmingCharacters(in: .whitespaces).isEmpty || boardName.trimmingCharacters(in: .whitespaces).isEmpty)
                Text(radio.phase)
                    .font(.caption)
            }
        }
    }

    private func macLine(_ radios: BoardRadios, kind: SeenBoard.Kind) -> String {
        if radios.wifi.isEmpty && radios.ethernet.isEmpty {
            return "MAC 은 이 기판이 알려 주면 여기에 나타납니다."
        }
        var lines = ["와이파이 MAC \(radios.wifi.isEmpty ? "없음" : radios.wifi)"]
        if kind == .olimex {
            lines.append("이더넷 MAC \(radios.ethernet.isEmpty ? "없음" : radios.ethernet)")
        }
        return lines.joined(separator: "\n")
    }

    private func open(_ board: SeenBoard) {
        editing = board.id
        boardName = board.kind == .olimex ? "올리멕스" : "C3"
        ip = board.kind.suggestedIP
        password = ""
        reading = true
        Task {
            _ = await radio.identify(board: board)
            reading = false
        }
    }

    private func send(_ board: SeenBoard) async {
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
        onReady(board.kind, result.host, port, result.radios, boardName.trimmingCharacters(in: .whitespaces))
        finished[board.id] = result.host
        editing = nil
    }
}
