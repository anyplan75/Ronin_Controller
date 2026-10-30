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
                    device.wrappedValue.cameras = BridgeCameraSlot.capped(device.wrappedValue.cameras)
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
        Text("같은 망에서 기판을 찾습니다. 그 기판이 대답하면 맥 주소가 채워지고 바로 붙습니다.")
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
        if device.wrappedValue.cameras.isEmpty {
            Text("카메라 칸이 없습니다. 장치 목록에서 카메라를 추가하세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(Array(device.wrappedValue.cameras.enumerated()), id: \.element.id) { index, camera in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("카메라 \(index + 1)")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("이 카메라 삭제", role: .destructive) {
                        studio.deleteCamera(deviceId, camera.id)
                    }
                    .font(.caption)
                }
                Picker("종류", selection: cameraRole(camera.id)) {
                    ForEach(BridgeCameraRole.allCases) { role in
                        Text(role.title).tag(role)
                    }
                }
                TextField("카메라 블루투스 맥 주소", text: cameraMac(camera.id))
                    .autocorrectionDisabled()
                Text(slotLine(camera.id))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                BridgeCameraPresets(deviceId: deviceId, camera: camera)
            }
        }
        if device.wrappedValue.cameras.count < 4 {
            Button("카메라 추가") { studio.addCamera(deviceId) }
        }
        Button(findingCameras ? "카메라 찾는 중" : "주변 카메라 찾기") {
            findingCameras = true
            Task {
                await studio.scanCameras(deviceId)
                findingCameras = false
            }
        }
        .disabled(findingCameras || device.wrappedValue.host.isEmpty)
        Text("기판이 주변 고프로와 액션 5 프로를 같은 목록으로 읽습니다. 있는 칸에 맥 주소와 붙음 또는 붙지 않음이 바로 나오고, 칸이 모자라면 4대까지 추가합니다.")
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

    private func cameraRole(_ id: UUID) -> Binding<BridgeCameraRole> {
        Binding(
            get: { device.wrappedValue.cameras.first(where: { $0.id == id })?.role ?? .gopro },
            set: { newValue in
                var slots = device.wrappedValue.cameras
                guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
                slots[index].role = newValue
                device.wrappedValue.cameras = slots
            }
        )
    }

    private func cameraMac(_ id: UUID) -> Binding<String> {
        Binding(
            get: { device.wrappedValue.cameras.first(where: { $0.id == id })?.mac ?? "" },
            set: { newValue in
                var slots = device.wrappedValue.cameras
                guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
                slots[index].mac = BoardMac.isFull(newValue) ? BoardMac.normalize(newValue) : newValue.uppercased()
                device.wrappedValue.cameras = slots
            }
        )
    }

    private func slotLine(_ id: UUID) -> String {
        guard let slot = device.wrappedValue.cameras.first(where: { $0.id == id }) else {
            return "맥 주소를 적지 않았습니다."
        }
        if let live = studio.bridgeLive[deviceId] {
            return live.attachment(for: slot)
        }
        return BoardMac.isFull(slot.mac) ? "아직 읽지 못했습니다." : "맥 주소를 적지 않았습니다."
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
        if device.cameras.isEmpty {
            Text("카메라 칸이 없습니다.")
        }
        ForEach(Array(device.cameras.enumerated()), id: \.element.id) { index, slot in
            let state = studio.bridgeLive[device.id]?.attachment(for: slot)
                ?? (BoardMac.isFull(slot.mac) ? "아직 읽지 못했습니다." : "맥 주소를 적지 않았습니다.")
            let mac = BoardMac.isFull(slot.mac) ? BoardMac.normalize(slot.mac) : "맥 없음"
            Text("\(index + 1). \(slot.role.title)  \(mac)  \(state)")
        }
    }
}

/// 이 카메라 칸의 설정을 한 화면에 모읍니다. 카메라에 있는 프리셋과 앱에 저장한 프리셋은 따로입니다.
struct BridgeCameraPresets: View {
    @EnvironmentObject private var studio: Studio
    var deviceId: UUID
    var camera: BridgeCameraSlot
    @State private var found: [CameraPresetItem] = []
    @State private var reading = false
    @State private var look = GoProCatalog.freshLook()
    @State private var pendingDelete: UUID?

    var body: some View {
        Text("카메라 설정")
            .font(.caption.weight(.semibold))
        Button(reading ? "읽는 중" : "카메라에 있는 프리셋 읽기") {
            reading = true
            Task {
                await readPresets()
                reading = false
            }
        }
        .disabled(reading || !BoardMac.isFull(camera.mac))
        .font(.caption)
        ForEach(found) { item in
            Button(item.title) {
                Task { await pick(item) }
            }
            .font(.caption)
        }
        ForEach(GoProCatalog.settings) { spec in
            Toggle(spec.title, isOn: enabled(spec))
                .font(.caption)
            Picker(spec.title, selection: option(spec)) {
                ForEach(spec.options) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .disabled(!(look.settings.first(where: { $0.settingId == spec.id })?.enabled ?? false))
            .font(.caption)
        }
        Button("이 설정을 프리셋으로 저장") {
            let name = "\(camera.role.title) 설정"
            studio.addActionPreset(deviceId: deviceId, cameraId: camera.id, name: name, look: look)
        }
        .font(.caption)
        ForEach(studio.userPresets(kind: .action, deviceId: deviceId, cameraId: camera.id)) { preset in
            HStack {
                Button(preset.name) {
                    look = preset.gopro
                    Task { await applySaved(preset) }
                }
                Button("삭제", role: .destructive) { pendingDelete = preset.id }
            }
            .font(.caption)
        }
        .alert("이 프리셋을 지울까요?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("삭제", role: .destructive) {
                if let id = pendingDelete { studio.deletePreset(id) }
                pendingDelete = nil
            }
            Button("취소", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("저장된 프로필에서 빠집니다. 카메라에 원래 있던 프리셋은 지우지 않습니다.")
        }
    }

    private func enabled(_ spec: GoProSettingSpec) -> Binding<Bool> {
        Binding(
            get: { look.settings.first(where: { $0.settingId == spec.id })?.enabled ?? false },
            set: { on in
                if let index = look.settings.firstIndex(where: { $0.settingId == spec.id }) {
                    look.settings[index].enabled = on
                }
            }
        )
    }

    private func option(_ spec: GoProSettingSpec) -> Binding<Int> {
        Binding(
            get: { look.settings.first(where: { $0.settingId == spec.id })?.option ?? spec.options[0].value },
            set: { value in
                if let index = look.settings.firstIndex(where: { $0.settingId == spec.id }) {
                    look.settings[index].option = value
                }
            }
        )
    }

    private func readPresets() async {
        guard let device = studio.profile.devices.first(where: { $0.id == deviceId }) else { return }
        do {
            if device.kind == .gopro {
                let text = try await GoProClient.presetList(device)
                found = CameraPresetText.parse(text)
            } else {
                found = try await C3Client.cameraPresets(device, mac: camera.mac)
            }
            if found.isEmpty {
                studio.note("\(camera.role.title) 에서 읽을 프리셋이 없습니다.")
            }
        } catch {
            studio.note(error.localizedDescription)
        }
    }

    private func pick(_ item: CameraPresetItem) async {
        guard let device = studio.profile.devices.first(where: { $0.id == deviceId }) else { return }
        do {
            if device.kind == .gopro {
                _ = try await GoProClient.loadPreset(device, id: item.id)
            } else {
                _ = try await C3Client.loadCameraPreset(device, mac: camera.mac, id: item.id)
            }
            studio.note("\(camera.role.title) 프리셋 \(item.title) 을 불렀습니다.")
        } catch {
            studio.note(error.localizedDescription)
        }
    }

    private func applySaved(_ preset: ShootPreset) async {
        guard let device = studio.profile.devices.first(where: { $0.id == deviceId }) else { return }
        let line = await GroupFire.apply(preset, to: device)
        studio.note(line.isEmpty ? "보낼 설정이 없습니다. 체크한 뒤 저장하세요." : line)
    }
}
