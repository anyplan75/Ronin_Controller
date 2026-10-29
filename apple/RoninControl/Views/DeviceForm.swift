import SwiftUI

struct DeviceForm: View {
    @EnvironmentObject private var studio: Studio
    @ObservedObject var radio: OsmoRadio
    let deviceId: UUID
    @State private var findingBoard = false
    @State private var findingCameras = false

    private var device: Binding<DeviceRecord> { studio.deviceBinding(deviceId) }

    var body: some View {
        Section("장치") {
            TextField("이름", text: device.name)
            if device.wrappedValue.kind == .osmoNoAPI {
                Text("오즈모 포켓·모바일·나노는 제어 API가 없어 새로 추가할 수 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("종류", selection: productChoice) {
                    ForEach(productChoices) { product in
                        Text(product.label).tag(product)
                    }
                }
            }
            Toggle("사용", isOn: device.enabled)
            Toggle("함께 촬영에 포함", isOn: studio.groupBinding(deviceId))
            if device.wrappedValue.kind == .goproBridge {
                bridgeBoard
            } else if device.wrappedValue.kind.usesHTTP {
                TextField(addressPrompt, text: device.host)
                    .autocorrectionDisabled()
                Stepper("포트 \(device.wrappedValue.port)", value: device.port, in: 1...65535)
                Text(device.wrappedValue.baseURLText.isEmpty ? "주소가 비어 있습니다." : device.wrappedValue.baseURLText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            note
        }
        .task(id: deviceId) {
            guard device.wrappedValue.kind == .goproBridge else { return }
            await studio.refreshBoard(deviceId)
        }
        if device.wrappedValue.kind == .osmoAction || device.wrappedValue.kind == .osmoNoAPI {
            osmoIdentity
        }
        if device.wrappedValue.kind == .osmoAction {
            osmoPair
        }
    }

    private var addressPrompt: String {
        device.wrappedValue.kind == .goproAction5 ? "중계 기판 주소" : "주소"
    }

    private var productChoice: Binding<DeviceProduct> {
        Binding(
            get: { DeviceProduct.matching(device.wrappedValue) ?? .ronin },
            set: { product in
                device.wrappedValue.kind = product.kind
                device.wrappedValue.osmoModel = product.osmoModel
                device.wrappedValue.port = product.kind.defaultPort
                if product.kind == .gopro, device.wrappedValue.host.isEmpty {
                    device.wrappedValue.host = "10.5.5.9"
                }
                if product.kind == .goproAction5, device.wrappedValue.host == "10.5.5.9" {
                    device.wrappedValue.host = ""
                }
                if product.kind == .goproBridge {
                    device.wrappedValue.port = 80
                    if !BoardMac.isFull(device.wrappedValue.boardMac) {
                        device.wrappedValue.boardMac = BoardMac.pluggedIn
                    }
                    device.wrappedValue.cameras = BridgeCameraSlot.padded(device.wrappedValue.cameras)
                }
            }
        )
    }

    private var productChoices: [DeviceProduct] {
        var list = DeviceProduct.addMenu
        if let current = DeviceProduct.matching(device.wrappedValue), !list.contains(current) {
            list.insert(current, at: 0)
        }
        return list
    }

    @ViewBuilder private var bridgeBoard: some View {
        TextField("기판 맥 주소", text: boardMacText)
            .autocorrectionDisabled()
        Button(findingBoard ? "기판 찾는 중" : "기판 찾기") {
            findingBoard = true
            Task {
                await studio.scanBoard(deviceId)
                findingBoard = false
            }
        }
        .disabled(findingBoard)
        Text("같은 망에서 기판을 찾습니다. 그 기판이 대답하면 맥 주소가 채워집니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
        let phase = studio.bridgePhase[deviceId] ?? "기판을 찾는 중입니다."
        Text(phase)
            .font(.caption)
        Text(device.wrappedValue.baseURLText.isEmpty ? "숫자 주소는 기판을 찾는 즉시 채워집니다." : device.wrappedValue.baseURLText)
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("기판은 JMEDIA 에 먼저 붙고, 안 되면 JMEDIA_Cam 에 붙습니다. 와이파이 비밀번호는 앱에 없습니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
        ForEach(0..<4, id: \.self) { index in
            VStack(alignment: .leading, spacing: 6) {
                Text("카메라 \(index + 1)")
                    .font(.caption.weight(.semibold))
                Picker("종류", selection: cameraRole(index)) {
                    ForEach(BridgeCameraRole.allCases) { role in
                        Text(role.title).tag(role)
                    }
                }
                TextField("카메라 블루투스 맥 주소", text: cameraMac(index))
                    .autocorrectionDisabled()
                Text(slotLine(index))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Button(findingCameras ? "고프로 찾는 중" : "주변 고프로 찾기") {
            findingCameras = true
            Task {
                await studio.scanCameras(deviceId)
                findingCameras = false
            }
        }
        .disabled(findingCameras || device.wrappedValue.host.isEmpty)
        Text("기판이 주변 고프로의 블루투스 맥 주소를 읽어 위 칸에 넣습니다.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Button("촬영 시작") {
            Task { await studio.bridgeRecord(device.wrappedValue, start: true) }
        }
        Button("촬영 정지") {
            Task { await studio.bridgeRecord(device.wrappedValue, start: false) }
        }
        Button("붙음 다시 읽기") {
            Task { await studio.refreshBoard(deviceId) }
        }
    }

    private var boardMacText: Binding<String> {
        Binding(
            get: { device.wrappedValue.boardMac },
            set: { newValue in
                device.wrappedValue.boardMac = BoardMac.isFull(newValue) ? BoardMac.normalize(newValue) : newValue.uppercased()
            }
        )
    }

    private func cameraRole(_ index: Int) -> Binding<BridgeCameraRole> {
        Binding(
            get: {
                let slots = device.wrappedValue.cameras
                guard slots.indices.contains(index) else { return .gopro }
                return slots[index].role
            },
            set: { newValue in
                var slots = BridgeCameraSlot.padded(device.wrappedValue.cameras)
                slots[index].role = newValue
                device.wrappedValue.cameras = slots
            }
        )
    }

    private func cameraMac(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                let slots = device.wrappedValue.cameras
                guard slots.indices.contains(index) else { return "" }
                return slots[index].mac
            },
            set: { newValue in
                var slots = BridgeCameraSlot.padded(device.wrappedValue.cameras)
                slots[index].mac = BoardMac.isFull(newValue) ? BoardMac.normalize(newValue) : newValue.uppercased()
                device.wrappedValue.cameras = slots
            }
        )
    }

    private func slotLine(_ index: Int) -> String {
        let slots = BridgeCameraSlot.padded(device.wrappedValue.cameras)
        guard slots.indices.contains(index) else { return "맥 주소를 적지 않았습니다." }
        if let live = studio.bridgeLive[deviceId] {
            return live.attachment(for: slots[index])
        }
        return BoardMac.isFull(slots[index].mac) ? "아직 읽지 못했습니다." : "맥 주소를 적지 않았습니다."
    }

    @ViewBuilder private var note: some View {
        switch device.wrappedValue.kind {
        case .ronin:
            Text(Honest.ronin).font(.caption).foregroundStyle(.secondary)
        case .gopro:
            Text(Honest.gopro).font(.caption).foregroundStyle(.secondary)
        case .goproAction5:
            Text(Honest.action5).font(.caption).foregroundStyle(.secondary)
        case .goproBridge:
            Text(Honest.bridge).font(.caption).foregroundStyle(.secondary)
        case .osmoAction:
            Text(device.wrappedValue.osmoModel == .osmo360 ? Honest.osmo360 : Honest.osmo)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .osmoNoAPI:
            Text(Honest.noAPI).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var osmoIdentity: some View {
        Section("오즈모 기종") {
            Picker("기종", selection: device.osmoModel) {
                ForEach(OsmoModel.choices(for: device.wrappedValue.kind, model: device.wrappedValue.osmoModel)) { model in
                    Text(model.title).tag(model)
                }
            }
            if device.wrappedValue.kind == .osmoNoAPI {
                ApiBadge(title: "API 없음", tint: .orange)
            }
        }
    }

    @ViewBuilder private var osmoPair: some View {
        Section("블루투스 세션") {
            Text(radio.bluetoothNote).font(.caption)
            Text(radio.live[deviceId]?.phase ?? "연결 안 됨")
            Button(radio.scanning ? "찾는 중" : "카메라 찾기") {
                radio.startScan()
            }
            .disabled(radio.scanning)
            ForEach(radio.seen) { seen in
                Button("\(seen.name)  \(seen.rssi)") {
                    device.wrappedValue.bleIdentifier = seen.identifier.uuidString
                }
            }
            Text(device.wrappedValue.bleIdentifier.isEmpty ? "고른 카메라가 없습니다." : device.wrappedValue.bleIdentifier)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("처음 연결 (카메라에 숫자 확인)") {
                Task { await pair(verify: device.wrappedValue.pairedOnce ? 0 : 1) }
            }
            Button("확인 없이 다시 시도") {
                Task { await pair(verify: 0) }
            }
            Text("요청마다 붙였다 끊지 않습니다. 페어링은 수십 초 걸릴 수 있어 함께 시작이 대신 연결하지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func pair(verify: UInt8) async {
        let current = device.wrappedValue
        let outcome = await radio.pair(
            device: current,
            senderId: studio.profile.senderId,
            mac: studio.profile.senderMac,
            verifyMode: verify
        )
        studio.note(outcome.text)
        if outcome.ok {
            device.wrappedValue.pairedOnce = true
        }
    }
}

/// 기판이 지금 알려 준 붙음만 보여 줍니다. 카메라를 일부러 연결하지는 않습니다.
struct BridgeAttachmentList: View {
    @EnvironmentObject private var studio: Studio
    let device: DeviceRecord

    var body: some View {
        let phase = studio.bridgePhase[device.id] ?? "기판을 찾는 중입니다."
        Text(phase)
        if BoardMac.isFull(device.boardMac) {
            Text("기판 \(BoardMac.normalize(device.boardMac))")
        }
        if let live = studio.bridgeLive[device.id], !live.ssid.isEmpty {
            Text("기판 망 \(live.ssid)")
        }
        ForEach(BridgeCameraSlot.padded(device.cameras)) { slot in
            let state = studio.bridgeLive[device.id]?.attachment(for: slot)
                ?? (BoardMac.isFull(slot.mac) ? "아직 읽지 못했습니다." : "맥 주소를 적지 않았습니다.")
            let mac = BoardMac.isFull(slot.mac) ? BoardMac.normalize(slot.mac) : "맥 없음"
            Text("\(slot.slot + 1). \(slot.role.title)  \(mac)  \(state)")
        }
    }
}
