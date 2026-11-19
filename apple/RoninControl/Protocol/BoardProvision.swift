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

/// 기판 블루투스에 와이파이 이름과 비밀번호를 넣고, 붙은 주소를 받습니다.
final class BoardProvision: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "7b1e9c10-5a20-4c31-8d10-726f6e696e31")
    static let characteristic = CBUUID(string: "7b1e9c11-5a20-4c31-8d10-726f6e696e31")

    @Published private(set) var boards: [SeenBoard] = []
    @Published private(set) var phase = "블루투스를 준비하는 중입니다."
    private var manager: CBCentralManager?
    private var pending: [(CBPeripheral, CBCharacteristic)] = []
    private var waiter: ((Bool, String, Int) -> Void)?

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

    func send(board: SeenBoard, ssid: String, password: String, ip: String) async -> (ok: Bool, host: String, port: Int) {
        guard let manager, manager.state == .poweredOn else {
            return (false, "", 0)
        }
        phase = "\(board.name) 에 붙는 중입니다."
        pendingSSID = ssid
        pendingPass = password
        pendingIP = ip
        target = board.peripheral
        board.peripheral.delegate = self
        return await withCheckedContinuation { continuation in
            waiter = { ok, host, port in
                continuation.resume(returning: (ok, host, port))
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
        let ok = object["ok"] as? Bool ?? false
        let host = object["ip"] as? String ?? ""
        let port = object["port"] as? Int ?? 0
        let reason = object["reason"] as? String ?? ""
        finish(ok: ok, host: host, port: port, note: ok ? "\(host):\(port)" : reason)
    }

    private func finish(ok: Bool, host: String, port: Int, note: String) {
        phase = note.isEmpty ? (ok ? "망에 붙었습니다." : "붙지 못했습니다.") : note
        let pending = waiter
        waiter = nil
        if let target {
            manager?.cancelPeripheralConnection(target)
        }
        pending?(ok, host, port)
    }
}

/// 처음 연결 창입니다. 비밀번호는 기판에만 보내고 화면 소스에는 없습니다.
struct FirstJoinSheet: View {
    @StateObject private var radio = BoardProvision()
    @State private var picked: UUID?
    @State private var ssid = "JMEDIA"
    @State private var password = ""
    @State private var ip = ""
    @State private var busy = false
    var onReady: (SeenBoard.Kind, String, Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("찾은 기판") {
                    if radio.boards.isEmpty {
                        Text(radio.phase)
                    }
                    ForEach(radio.boards) { board in
                        Button {
                            picked = board.id
                            if ip.isEmpty { ip = board.kind.suggestedIP }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(board.name)
                                    Text(board.kind.title).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if picked == board.id { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Section("집 와이파이") {
                    TextField("이름", text: $ssid)
                    SecureField("비밀번호", text: $password)
                    TextField("고정 주소, 비우면 공유기가 줍니다", text: $ip)
                    Text("고정 주소는 192.168.10.x 만 됩니다. 올리멕스 기본은 192.168.10.151, C3 기본은 192.168.10.152 입니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("처음 연결")
            .toolbar {
                Button("닫기") { dismiss() }
                Button(busy ? "넣는 중" : "이 망에 넣기") {
                    Task { await send() }
                }
                .disabled(busy || picked == nil || ssid.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .onAppear { radio.start() }
            .onDisappear { radio.stop() }
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
        onReady(board.kind, result.host, result.port == 0 ? (board.kind == .olimex ? 81 : 82) : result.port)
        dismiss()
    }
}
