import Combine
import Foundation

struct ClockSample: Sendable {
    var millis: UInt32
    var mid: Date
}

/// 아이폰이 지금 연결한 뒤 보여 주는 결과입니다. 새 찾기 방식은 만들지 않습니다.
enum PhoneSeek {
    case unreachable
    case nonePairing
    case cameras([NearbyGoPro])
}

enum GroupFire {
    static func clock(_ device: DeviceRecord) async -> (UUID, ClockSample)? {
        let start = Date()
        do {
            let millis = try await RoninClient.clock(device)
            let end = Date()
            let mid = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            return (device.id, ClockSample(millis: millis, mid: mid))
        } catch {
            return nil
        }
    }

    static func ronin(
        _ device: DeviceRecord,
        startRecording: Bool,
        when: Date,
        sample: ClockSample?,
        lead: Int
    ) async -> String {
        let action = startRecording ? "start" : "stop"
        do {
            if let sample {
                let delta = Int(when.timeIntervalSince(sample.mid) * 1000)
                let at = delta >= 0 ? sample.millis &+ UInt32(delta) : sample.millis &- UInt32(-delta)
                let text = try await RoninClient.syncRecord(device, action: action, atMs: at, delayMs: nil)
                return "\(device.name) 기판 시계에 맞춤 \(text)"
            }
            let text = try await RoninClient.syncRecord(device, action: action, atMs: nil, delayMs: lead)
            return "\(device.name) 시계를 못 읽어 delay_ms 로 보냄 \(text)"
        } catch {
            return "\(device.name) \(error.localizedDescription)"
        }
    }

    static func bridge(_ device: DeviceRecord, startRecording: Bool) async -> [String] {
        let slots = device.cameras.filter { BoardMac.isFull($0.mac) }
        if slots.isEmpty {
            return ["\(device.name) 카메라 맥 주소가 없습니다."]
        }
        if device.baseURLText.isEmpty {
            return ["\(device.name) 와이파이와 직접 연결 모두 대답이 없습니다."]
        }
        var lines: [String] = []
        for slot in slots {
            let who = "\(slot.role.title) \(BoardMac.normalize(slot.mac))"
            do {
                let text = try await C3Client.shutter(device, mac: slot.mac, start: startRecording)
                lines.append("\(device.name) \(who) \(text)")
            } catch {
                lines.append("\(device.name) \(who) \(error.localizedDescription)")
            }
        }
        return lines
    }

    static func gopro(_ device: DeviceRecord, startRecording: Bool, when: Date) async -> String {
        await wait(until: when)
        do {
            let text = try await GoProClient.shutter(device, start: startRecording)
            return "\(device.name) 고프로 셔터 \(text.isEmpty ? "보냄" : text)"
        } catch {
            return "\(device.name) \(error.localizedDescription)"
        }
    }

    static func wait(until when: Date) async {
        let seconds = when.timeIntervalSinceNow
        if seconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }
}

@MainActor
final class Studio: ObservableObject {
    @Published var profile: StudioProfile {
        didSet { save() }
    }
    @Published var log: [String] = []
    @Published var shotNames: [String] = RoninCatalog.shots
    @Published var roninLive: [UUID: RoninStatus] = [:]
    @Published var goproLive: [UUID: GoProLive] = [:]
    @Published var goproSession: [UUID: String] = [:]
    @Published var bridgeLive: [UUID: BridgeBoardLive] = [:]
    @Published var bridgePhase: [UUID: String] = [:]
    /// 와이파이 연결과 기판 직접 연결을 따로 둡니다. 숫자 주소는 프로필에 덮어쓰지 않습니다.
    @Published var bridgeLinks: [UUID: BridgeLinks] = [:]
    let boardSocket = BoardSocket()
    let radio = OsmoRadio()
    private let c3 = C3Link()
    let frameOK = DjiRFrame.selfCheck()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init() {
        if let data = UserDefaults.standard.data(forKey: StudioProfile.storageKey),
           let saved = try? JSONDecoder().decode(StudioProfile.self, from: data) {
            profile = saved
        } else {
            profile = StudioProfile.makeNew()
        }
        if !frameOK {
            note("프레임 검사가 실패했습니다. 오즈모 명령 형식이 공식 예시와 다릅니다.")
        }
        applyFixedRoninAddress()
        if let lane = BoardLane(rawValue: profile.boardLane) {
            boardSocket.lane = lane
        }
        Task { await bootBoards() }
        Task { await maintainGoProSessions() }
    }

    func note(_ text: String) {
        log.insert("\(Self.stamp.string(from: Date()))  \(text)", at: 0)
        if log.count > 40 {
            log.removeLast(log.count - 40)
        }
    }

    var roninC3: C3BoardRecord? {
        profile.c3Boards.first { $0.duty == .ronin }
    }

    /// 올리멕스 ESP32-PoE 를 스튜디오 기판으로 등록합니다. 액션 카메라는 이 기판 블루투스입니다.
    func registerOlimex() {
        if profile.olimexRegistered {
            note("올리멕스 ESP32-PoE 는 이미 등록되어 있습니다.")
            return
        }
        profile.olimexRegistered = true
        if !profile.devices.contains(where: { $0.kind == .ronin }) {
            let device = DeviceRecord(
                id: UUID(),
                name: "올리멕스 ESP32-PoE",
                kind: .ronin,
                osmoModel: .unknown,
                host: BoardLane.poe.host,
                port: BoardLane.poe.port,
                bleIdentifier: "",
                enabled: true,
                pairedOnce: false
            )
            profile.devices.append(device)
            profile.groupIds.append(device.id)
        }
        note("올리멕스 ESP32-PoE 를 등록했습니다. PoE 또는 와이파이 웹소켓, 액션 카메라, 화면의 나머지를 이 기판이 맡습니다.")
    }

    /// C3 를 하나 등록합니다. 고른 일만 하고, 액션 카메라는 맡지 않습니다.
    func registerC3(_ job: C3Job) {
        if job == .ronin, roninC3 != nil {
            note("로닌 제어 C3 는 한 대만 등록합니다.")
            return
        }
        let board = C3BoardRecord(
            id: UUID(),
            name: job == .ronin ? "C3 로닌" : "C3 울란지 VL120BI",
            job: job.rawValue
        )
        profile.c3Boards.append(board)
        note("\(board.name) 을 등록했습니다. 이 C3 는 \(job.title)만 합니다.")
    }

    func deleteC3(_ id: UUID) {
        profile.c3Boards.removeAll { $0.id == id }
        note("C3 를 목록에서 뺐습니다.")
    }

    func addDevice(_ product: DeviceProduct) {
        guard profile.devices.count < StudioProfile.maxDevices else {
            note("장치는 8대까지입니다.")
            return
        }
        let index = profile.devices.count + 1
        let knownMac = BoardMac.pluggedIn
        let boardAlready = profile.devices.contains { $0.kind == .goproBridge && BoardMac.same($0.boardMac, knownMac) }
        let device = DeviceRecord(
            id: UUID(),
            name: product.kind == .goproBridge ? "C3 중계 \(index)" : "\(product.label) \(index)",
            kind: product.kind,
            osmoModel: product.osmoModel,
            host: product.kind == .ronin ? RoninBoard.host : (product.kind == .gopro ? "10.5.5.9" : ""),
            port: product.kind.defaultPort,
            bleIdentifier: "",
            enabled: true,
            pairedOnce: false,
            boardMac: product.kind == .goproBridge && !boardAlready ? knownMac : "",
            cameras: []
        )
        profile.devices.append(device)
        profile.groupIds.append(device.id)
        if device.kind == .goproBridge {
            let id = device.id
            note("\(device.name) 을 목록에 넣었습니다. 카메라 칸은 따로 추가합니다.")
            Task { await connectBoard(id, reportMiss: false) }
        }
    }

    func deleteDevice(_ id: UUID) {
        let name = profile.devices.first(where: { $0.id == id })?.name ?? "장치"
        profile.devices.removeAll { $0.id == id }
        profile.groupIds.removeAll { $0 == id }
        for key in profile.shootGroups.keys {
            profile.shootGroups[key]?.removeAll { $0 == id }
        }
        profile.stageSpots.removeAll { $0.deviceId == id }
        for index in profile.presets.indices {
            profile.presets[index].deviceIds.removeAll { $0 == id }
        }
        bridgeLive[id] = nil
        bridgePhase[id] = nil
        bridgeLinks[id] = nil
        note("\(name) 을 목록과 저장된 프로필에서 뺐습니다.")
    }

    /// 이 기판의 카메라 칸을 하나 넣습니다. 최대 4칸이고, 바로 프로필에 저장됩니다.
    func addCamera(_ deviceId: UUID) {
        guard let index = profile.devices.firstIndex(where: { $0.id == deviceId && $0.kind == .goproBridge }) else { return }
        guard profile.devices[index].cameras.count < 4 else {
            note("카메라는 한 기판에 4대까지입니다.")
            return
        }
        profile.devices[index].cameras.append(BridgeCameraSlot())
        let count = profile.devices[index].cameras.count
        note("\(profile.devices[index].name) 에 카메라 \(count)칸을 넣고 저장했습니다.")
    }

    /// 이 카메라 칸만 지웁니다. 기판은 남고, 저장된 프로필에서도 빠집니다.
    func deleteCamera(_ deviceId: UUID, _ cameraId: UUID) {
        guard let index = profile.devices.firstIndex(where: { $0.id == deviceId && $0.kind == .goproBridge }) else { return }
        let before = profile.devices[index].cameras.count
        profile.devices[index].cameras.removeAll { $0.id == cameraId }
        guard profile.devices[index].cameras.count != before else { return }
        note("\(profile.devices[index].name) 의 카메라 칸을 목록과 저장된 프로필에서 뺐습니다.")
    }

    func addRoninPreset(for device: DeviceRecord, look: RoninLook) {
        let count = profile.presets.filter { $0.kind == .ronin }.count + 1
        let preset = ShootPreset(
            id: UUID(),
            name: "\(device.name) 프리셋 \(count)",
            note: "",
            deviceIds: [device.id],
            ronin: look,
            gopro: GoProCatalog.freshLook(),
            osmo: OsmoLook(mode: nil),
            connections: [],
            kind: .ronin
        )
        profile.presets.append(preset)
        note("\(preset.name) 을 저장했습니다. 기판에 있는 동작은 그대로입니다.")
    }

    func addActionPreset(deviceId: UUID, cameraId: UUID?, name: String, look: GoProLook) {
        let preset = ShootPreset(
            id: UUID(),
            name: name.isEmpty ? "카메라 설정 \(profile.presets.filter { $0.kind == .action }.count + 1)" : name,
            note: "",
            deviceIds: [deviceId],
            ronin: RoninLook(shot: "", timeScale: 1, sendMove: false, yaw: 0, roll: 0, pitch: 0, seconds: 1, absolute: true),
            gopro: look,
            osmo: OsmoLook(mode: nil),
            connections: [],
            kind: .action,
            cameraId: cameraId
        )
        profile.presets.append(preset)
        note("\(preset.name) 을 저장했습니다.")
    }

    func userPresets(kind: PresetKind, deviceId: UUID, cameraId: UUID? = nil) -> [ShootPreset] {
        profile.presets.filter { preset in
            preset.kind == kind && preset.deviceIds.contains(deviceId) && preset.cameraId == cameraId
        }
    }

    func deletePreset(_ id: UUID) {
        guard let preset = profile.presets.first(where: { $0.id == id }) else { return }
        profile.presets.removeAll { $0.id == id }
        note("\(preset.name) 을 저장된 프로필에서 뺐습니다.")
    }

    func rememberConnections(in presetId: UUID) {
        guard let index = profile.presets.firstIndex(where: { $0.id == presetId }) else { return }
        profile.presets[index].connections = profile.devices
        note("\(profile.presets[index].name) 에 지금 주소를 저장했습니다.")
    }

    func restoreConnections(from presetId: UUID) {
        guard let preset = profile.presets.first(where: { $0.id == presetId }) else { return }
        var added = 0
        for snapshot in preset.connections where !profile.devices.contains(where: { $0.id == snapshot.id }) {
            guard profile.devices.count < StudioProfile.maxDevices else {
                note("8대를 넘어 더 가져오지 못했습니다.")
                break
            }
            profile.devices.append(snapshot)
            if !profile.groupIds.contains(snapshot.id) {
                profile.groupIds.append(snapshot.id)
            }
            added += 1
        }
        note(added == 0 ? "가져올 새 주소가 없습니다." : "프리셋에서 주소 \(added)개를 가져왔습니다.")
    }

    var grouped: [DeviceRecord] {
        profile.devices.filter { $0.enabled && profile.groupIds.contains($0.id) }
    }

    /// 아직 자리가 없는 장치를 무대 앞쪽에 나눠 둡니다. 이미 둔 자리는 건드리지 않습니다.
    func ensureStageSpots() {
        var spots = profile.stageSpots
        var changed = spots.contains { spot in
            !profile.devices.contains { $0.id == spot.deviceId }
        }
        spots.removeAll { spot in !profile.devices.contains { $0.id == spot.deviceId } }
        let count = max(profile.devices.count, 1)
        for (index, device) in profile.devices.enumerated() where !spots.contains(where: { $0.deviceId == device.id }) {
            let placed = StageRoom.place(index: index, count: count)
            spots.append(StageSpot(deviceId: device.id, x: placed.x, y: placed.y, z: placed.z, aimYaw: 0))
            changed = true
        }
        if changed {
            profile.stageSpots = spots
        }
    }

    func stageSpot(for deviceId: UUID) -> StageSpot {
        if let found = profile.stageSpots.first(where: { $0.deviceId == deviceId }) {
            return found
        }
        let index = profile.devices.firstIndex { $0.id == deviceId } ?? 0
        let placed = StageRoom.place(index: index, count: max(profile.devices.count, 1))
        return StageSpot(deviceId: deviceId, x: placed.x, y: placed.y, z: placed.z, aimYaw: 0)
    }

    func moveStage(
        deviceId: UUID,
        x: Double? = nil,
        y: Double? = nil,
        z: Double? = nil,
        aimYaw: Double? = nil,
        homeYaw: Double? = nil,
        homePitch: Double? = nil
    ) {
        var spot = stageSpot(for: deviceId)
        if let x { spot.x = min(StageRoom.width * 0.48, max(-StageRoom.width * 0.48, x)) }
        if let y { spot.y = min(StageRoom.length - 0.4, max(0.4, y)) }
        if let z { spot.z = min(StageRoom.height - 0.3, max(0.2, z)) }
        if let aimYaw { spot.aimYaw = min(180, max(-180, aimYaw)) }
        if let homeYaw { spot.homeYaw = RoninTravel.clampYaw(homeYaw) }
        if let homePitch { spot.homePitch = RoninTravel.clampPitch(homePitch) }
        if let index = profile.stageSpots.firstIndex(where: { $0.deviceId == deviceId }) {
            profile.stageSpots[index] = spot
        } else {
            profile.stageSpots.append(spot)
        }
    }

    /// 무대에 적는 녹화 표시만 갱신합니다. 샷 목록은 다시 받지 않습니다.
    func refreshMarks() async {
        guard !profile.practice else { return }
        for device in profile.devices where device.enabled && !device.baseURLText.isEmpty {
            switch device.kind {
            case .ronin:
                if let status = try? await RoninClient.status(device) {
                    roninLive[device.id] = status
                }
            case .gopro, .goproAction5:
                if let live = try? await GoProClient.state(device) {
                    rememberGoPro(device, live)
                }
            case .goproBridge:
                await pullBoard(device)
            case .osmoAction, .osmoNoAPI:
                break
            }
        }
    }

    func refresh() async {
        guard !profile.practice else { return }
        for device in profile.devices where device.enabled {
            switch device.kind {
            case .ronin:
                if let status = try? await RoninClient.status(device) {
                    roninLive[device.id] = status
                }
                if let names = try? await shotList(device), !names.isEmpty {
                    shotNames = names
                }
            case .gopro, .goproAction5:
                if let live = try? await GoProClient.state(device) {
                    rememberGoPro(device, live)
                }
            case .goproBridge:
                await refreshBoard(device.id)
            case .osmoAction, .osmoNoAPI:
                break
            }
        }
    }

    func together(start: Bool) async {
        await fieldRecord(group: "all", start: start)
    }

    /// 고른 카메라 한 대만 촬영합니다. 같은 기판의 다른 칸에는 보내지 않습니다.
    func bridgeSlot(_ device: DeviceRecord, cameraId: UUID, start: Bool) async {
        guard let slot = device.cameras.first(where: { $0.id == cameraId }) else {
            note("고른 카메라를 찾지 못했습니다.")
            return
        }
        if profile.practice {
            note("연습: \(device.name) \(slot.role.title) \(start ? "촬영" : "정지")")
            return
        }
        guard profile.olimexRegistered else {
            note("액션 카메라는 올리멕스 기판에서만 녹화합니다. C3 는 그 일을 맡지 않습니다.")
            return
        }
        let ble = slot.role == .action5 ? "FFF0" : "FEA6"
        let ok = await boardSocket.send([
            "op": "record-one",
            "id": cameraId.uuidString,
            "name": slot.advertisedName.isEmpty ? slot.role.title : slot.advertisedName,
            "ble": ble,
            "start": start,
        ])
        if ok {
            note("\(slot.role.title) \(start ? "녹화" : "정지")를 올리멕스 소켓으로 보냈습니다.")
        } else {
            noteOffline("올리멕스가 오프라인입니다. 이 카메라 녹화를 보내지 않았습니다.")
        }
    }

    func bridgeRecord(_ device: DeviceRecord, start: Bool) async {
        await fieldRecord(group: "all", start: start)
    }

    func apply(_ preset: ShootPreset) async {
        if !preset.deviceIds.isEmpty {
            profile.groupIds = preset.deviceIds
        }
        let targets = profile.targets(for: preset)
        guard !targets.isEmpty else {
            note("적용할 장치가 없습니다.")
            return
        }
        if profile.practice {
            note("연습: \(preset.name) 을 적용하는 척만 했습니다. \(targets.map(\.name).joined(separator: ", "))")
            return
        }
        var lines: [String] = []
        await withTaskGroup(of: String.self) { group in
            for device in targets {
                let door = commandDoor(device)
                group.addTask { await GroupFire.apply(preset, to: door) }
            }
            for await line in group where !line.isEmpty { lines.append(line) }
        }
        if lines.isEmpty {
            note("\(preset.name): 보낼 설정이 없습니다.")
        }
        lines.forEach(note)
        let osmoModes = targets.filter { $0.kind == .osmoAction }
        if let mode = preset.osmo.mode {
            for device in osmoModes {
                note((await radio.setMode(device, mode: mode)).text)
            }
        }
        await refresh()
    }

    /// 휠이 가리키는 각도로 옮깁니다. 손을 떼도 그 각도에 남고, 중앙으로 되돌리지 않습니다.
    func roninPlace(_ device: DeviceRecord, yaw: Double, pitch: Double) async {
        if profile.practice { return }
        if let board = roninC3 {
            noteOffline("\(board.name) 은 로닌만 담당합니다. 이 C3 연결이 없어 팬과 틸트를 보내지 않았습니다.")
            return
        }
        guard profile.olimexRegistered else {
            noteOffline("로닌은 올리멕스 기판 또는 로닌 담당 C3 가 있을 때 움직입니다.")
            return
        }
        let ok = await boardSocket.send([
            "op": "ronin",
            "id": device.id.uuidString,
            "path": "/move",
            "yaw": RoninTravel.clampYaw(yaw),
            "pitch": RoninTravel.clampPitch(pitch),
        ])
        if !ok {
            noteOffline("\(device.name) 기판이 오프라인입니다. 팬과 틸트를 보내지 않았습니다.")
        }
    }

    /// 오른쪽 휠의 위아래입니다. 성공 기록은 남기지 않습니다. 좌우는 아직 보내지 않습니다.
    func roninZoom(_ device: DeviceRecord, path: String) async {
        if profile.practice { return }
        if roninC3 != nil || !profile.olimexRegistered { return }
        _ = await boardSocket.send([
            "op": "ronin",
            "id": device.id.uuidString,
            "path": path,
        ])
    }

    /// 스틱을 누르고 있는 동안 팬·틸트 속도를 다시 보냅니다. 성공 기록은 남기지 않습니다.
    func roninSpeed(_ device: DeviceRecord, yaw: Double, pitch: Double) async {
        if profile.practice { return }
        if roninC3 != nil || !profile.olimexRegistered { return }
        _ = await boardSocket.send([
            "op": "ronin",
            "id": device.id.uuidString,
            "path": "/speed",
            "yaw": yaw,
            "pitch": pitch,
        ])
    }

    /// 휠을 누르는 동안만 보냅니다. 성공 기록은 남기지 않아 로그가 넘치지 않습니다.
    func roninHold(_ device: DeviceRecord, path: String?) async {
        if profile.practice { return }
        if roninC3 != nil || !profile.olimexRegistered { return }
        _ = await boardSocket.send([
            "op": "ronin",
            "id": device.id.uuidString,
            "path": path ?? "/stop",
        ])
    }

    /// 고른 로닌 한 대에만 이 프리셋의 짐벌 동작을 보냅니다.
    func applyRoninLook(_ preset: ShootPreset, to device: DeviceRecord) async {
        if profile.practice {
            note("연습: \(device.name) \(preset.name)")
            return
        }
        let line = await GroupFire.apply(preset, to: device)
        if line.isEmpty {
            note("\(preset.name): 이 로닌에 보낼 짐벌 설정이 없습니다.")
        } else {
            note(line)
        }
    }

    func ronin(_ device: DeviceRecord, path: String, query: [String: String] = [:]) async {
        if profile.practice {
            note("연습: \(device.name) \(path)")
            return
        }
        if let board = roninC3 {
            noteOffline("\(board.name) 은 로닌만 담당합니다. 이 C3 연결이 없어 \(path) 를 보내지 않았습니다.")
            return
        }
        guard profile.olimexRegistered else {
            noteOffline("로닌 명령은 올리멕스 기판 또는 로닌 담당 C3 가 있을 때 보냅니다.")
            return
        }
        var payload: [String: Any] = [
            "op": "ronin",
            "id": device.id.uuidString,
            "path": path,
        ]
        if !query.isEmpty {
            payload["query"] = query
        }
        let ok = await boardSocket.send(payload)
        if ok {
            note("\(device.name) \(path) 를 기판 소켓으로 보냈습니다.")
        } else {
            noteOffline("\(device.name) 기판이 오프라인입니다. \(path) 를 보내지 않았습니다.")
        }
    }

    /// 모두 녹화이거나 A·B·C 묶음 녹화입니다. 소켓이 열려 있을 때만 보냅니다.
    func fieldRecord(group: String, start: Bool) async {
        let label = group == "all" ? "모두" : group
        if profile.practice {
            note("연습: \(label) \(start ? "녹화" : "정지"). 기판에 보내지 않았습니다.")
            return
        }
        guard profile.olimexRegistered else {
            note("액션 카메라 녹화는 올리멕스 기판만 합니다. 먼저 올리멕스를 등록하세요.")
            return
        }
        let ids: [String]
        if group == "all" {
            ids = profile.devices.map(\.id.uuidString)
        } else {
            ids = (profile.shootGroups[group] ?? []).map(\.uuidString)
            if ids.isEmpty {
                note("\(label) 묶음이 비어 있습니다. 명령을 보내지 않았습니다.")
                return
            }
        }
        let ok = await boardSocket.send([
            "op": "record",
            "group": group,
            "start": start,
            "ids": ids,
        ])
        if ok {
            note("\(label) \(start ? "녹화" : "정지")를 기판 소켓으로 보냈습니다.")
        } else {
            noteOffline("기판이 오프라인입니다. \(label) \(start ? "녹화" : "정지")를 보내지 않았습니다.")
        }
    }

    /// 액션 카메라 한 대의 녹화입니다. 올리멕스 웹소켓으로만 보냅니다.
    func olimexCamera(_ camera: BoardCamera, start: Bool) async {
        guard profile.olimexRegistered else {
            note("액션 카메라는 올리멕스 기판에 있습니다. 먼저 등록하세요.")
            return
        }
        let ok = await boardSocket.send([
            "op": "record-one",
            "id": camera.id,
            "name": camera.name,
            "kind": camera.kind,
            "ble": camera.ble,
            "start": start,
        ])
        if ok {
            note("\(camera.name) \(start ? "녹화" : "정지")를 올리멕스 소켓으로 보냈습니다.")
        } else {
            noteOffline("올리멕스가 오프라인입니다. \(camera.name) 녹화를 보내지 않았습니다.")
        }
    }

    /// 조명 C3 만 받는 명령입니다. 연결이 없으면 보내지 않고, 연결됨으로 바꾸지 않습니다.
    func setLight(_ id: UUID, brightness: Int, kelvin: Int, on: Bool) async {
        guard let board = profile.c3Boards.first(where: { $0.id == id && $0.duty == .light }) else {
            note("조명 담당 C3 를 찾지 못했습니다.")
            return
        }
        note("\(board.name) 은 조명만 담당합니다. 연결이 없어 밝기 \(brightness), 색온도 \(kelvin)K, \(on ? "켜기" : "끄기")를 보내지 않았습니다.")
    }

    func sendCameraSetting(id: String, kind: String, ble: String, setting: String, value: String) async {
        if profile.practice {
            note("연습: 카메라 설정을 보내지 않았습니다.")
            return
        }
        guard profile.olimexRegistered else {
            note("카메라 설정은 올리멕스 기판으로만 보냅니다. 먼저 등록하세요.")
            return
        }
        let ok = await boardSocket.send([
            "op": "camera",
            "id": id,
            "kind": kind,
            "ble": ble,
            "setting": setting,
            "value": value,
        ])
        if ok {
            note("카메라 설정을 기판 소켓으로 보냈습니다.")
        } else {
            noteOffline("기판이 오프라인입니다. 카메라 설정을 보내지 않았습니다.")
        }
    }

    func chooseLane(_ lane: BoardLane) {
        profile.boardLane = lane.rawValue
        boardSocket.lane = lane
        if boardSocket.state != .offline {
            boardSocket.disconnect()
            note("길을 바꿔 오프라인입니다. 지금 연결을 다시 누르세요.")
        }
    }

    func toggleShootGroup(_ name: String, deviceId: UUID) {
        var list = profile.shootGroups[name] ?? []
        if list.contains(deviceId) {
            list.removeAll { $0 == deviceId }
        } else {
            list.append(deviceId)
        }
        profile.shootGroups[name] = list
    }

    func memberOf(_ name: String, deviceId: UUID) -> Bool {
        profile.shootGroups[name]?.contains(deviceId) == true
    }

    private var lastOfflineNote = Date.distantPast

    private func noteOffline(_ text: String) {
        if Date().timeIntervalSince(lastOfflineNote) < 2 { return }
        lastOfflineNote = Date()
        note(text)
    }

    func sonyConnect(_ device: DeviceRecord, ssid: String, password: String, host: String) async {
        if profile.practice {
            note("연습: 소니 연결은 보내지 않았습니다.")
            return
        }
        do {
            _ = try await RoninClient.command(device, path: "/sony/connect", query: [
                "ssid": ssid,
                "pass": password,
                "host": host,
            ])
            note("\(device.name) 소니 연결 요청을 보냈습니다. 비밀번호는 기판에만 저장됩니다.")
        } catch {
            note("\(device.name) 소니 \(error.localizedDescription)")
        }
    }

    /// 고프로가 알려 준 모델이 있으면 그 세대를 프로필 사진으로 기억합니다.
    private func rememberGoPro(_ device: DeviceRecord, _ live: GoProLive) {
        goproLive[device.id] = live
        guard device.kind == .gopro, let face = ProductFace.from(modelName: live.modelName) else { return }
        guard let index = profile.devices.firstIndex(where: { $0.id == device.id }) else { return }
        if profile.devices[index].productFace != face {
            profile.devices[index].productFace = face
        }
    }

    func gopro(_ device: DeviceRecord, _ work: @escaping (DeviceRecord) async throws -> String, label: String) async {
        if profile.practice {
            note("연습: \(device.name) \(label)")
            return
        }
        do {
            let text = try await work(device)
            var live = goproLive[device.id] ?? GoProLive(
                encoding: nil, remainingVideo: nil, remainingPhotos: nil, busy: nil,
                sdRemaining: nil, settings: [:], presetList: "", error: "", relayBle: ""
            )
            if label == "프리셋 목록" {
                live.presetList = text
                goproLive[device.id] = live
            }
            note("\(device.name) \(label) \(text.isEmpty ? "보냄" : text)")
        } catch {
            note("\(device.name) \(error.localizedDescription)")
        }
    }

    func exportProfile() throws -> Data {
        try JSONEncoder().encode(profile)
    }

    func importProfile(_ data: Data) {
        do {
            profile = try JSONDecoder().decode(StudioProfile.self, from: data)
            note("프로필을 가져왔습니다. 장치 \(profile.devices.count)대, 프리셋 \(profile.presets.count)개.")
        } catch {
            note("프로필을 읽지 못했습니다.")
        }
    }

    private func shotList(_ device: DeviceRecord) async throws -> [String] {
        let text = try await RoninClient.command(device, path: "/shots")
        struct Body: Decodable { var shots: [String] }
        guard let data = text.data(using: .utf8) else { return [] }
        return try JSONDecoder().decode(Body.self, from: data).shots
    }

    private func maintainGoProSessions() async {
        while !Task.isCancelled {
            let cameras = profile.devices.filter { $0.enabled && $0.kind.isGoProFamily && !$0.baseURLText.isEmpty }
            if !profile.practice && !cameras.isEmpty {
                await withTaskGroup(of: (UUID, String).self) { group in
                    for device in cameras {
                        group.addTask {
                            do {
                                _ = try await GoProClient.keepAlive(device)
                                let whereText = device.kind == .goproAction5 ? "중계 기판 세션" : "카메라 와이파이 세션"
                                return (device.id, "\(whereText) 유지 중")
                            } catch {
                                let hint = device.kind == .goproAction5
                                    ? "중계 기판에 붙지 못했습니다"
                                    : "카메라 와이파이에 붙지 못했습니다"
                                return (device.id, hint)
                            }
                        }
                    }
                    for await item in group {
                        goproSession[item.0] = item.1
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    /// 목록에 있는 기판만 붙습니다. 지운 기판은 다시 만들지 않습니다.
    private func bootBoards() async {
        c3.onFound = { [weak self] mac, host, port in
            Task { @MainActor in
                self?.adoptBoard(mac: mac, host: host, port: port)
            }
        }
        c3.onPhase = { [weak self] text in
            Task { @MainActor in
                self?.setBridgePhase(text)
            }
        }
        c3.start()
        await connectRegisteredBoards()
        await watchBoards()
    }

    private func adoptBoard(mac: String, host: String, port: Int) {
        guard let index = profile.devices.firstIndex(where: { $0.kind == .goproBridge && BoardMac.same($0.boardMac, mac) }) else {
            return
        }
        let id = profile.devices[index].id
        let changed = profile.devices[index].host != host || profile.devices[index].port != port
        if changed {
            profile.devices[index].host = host
            profile.devices[index].port = port
            note("\(profile.devices[index].name) \(BoardMac.normalize(mac)) 에 바로 붙었습니다.")
        }
        bridgePhase[id] = "기판에 붙었습니다."
        let device = profile.devices[index]
        Task { await pullBoard(device) }
    }

    private func setBridgePhase(_ text: String) {
        for device in profile.devices where device.kind == .goproBridge {
            if bridgeLinks[device.id]?.commandHost.isEmpty == false { continue }
            if bridgePhase[device.id]?.contains("붙었습니다") == true { continue }
            bridgePhase[device.id] = text
        }
    }

    /// 등록된 기판이 있으면 이름 알림을 기다리지 않고 바로 80번 문에 붙습니다.
    private func connectRegisteredBoards() async {
        for device in profile.devices where device.kind == .goproBridge && BoardMac.same(device.boardMac, BoardMac.pluggedIn) {
            await connectBoard(device.id, reportMiss: false)
        }
    }

    /// 같은 망에서 기판을 찾고, 그 기판이 대답한 맥 주소만 넣은 뒤 바로 붙습니다.
    func scanBoard(_ id: UUID) async {
        await connectBoard(id, reportMiss: true)
    }

    private func connectBoard(_ id: UUID, reportMiss: Bool) async {
        guard let device = profile.devices.first(where: { $0.id == id && $0.kind == .goproBridge }) else { return }
        await pullBoard(device)
        if bridgeLinks[id]?.commandHost.isEmpty == false { return }
        bridgePhase[id] = "기판을 찾는 중입니다."
        let found = await c3.listen()
        for item in found {
            guard var probe = profile.devices.first(where: { $0.id == id }) else { return }
            probe.host = item.host
            probe.port = item.port
            guard let live = try? await C3Client.status(probe), BoardMac.same(live.boardMac, BoardMac.pluggedIn) else {
                continue
            }
            guard let index = profile.devices.firstIndex(where: { $0.id == id }) else { return }
            let wasEmpty = profile.devices[index].host.isEmpty
            profile.devices[index].boardMac = BoardMac.pluggedIn
            profile.devices[index].host = item.host
            profile.devices[index].port = item.port
            if wasEmpty {
                note("\(profile.devices[index].name) \(BoardMac.pluggedIn) 와이파이에 바로 붙었습니다.")
            }
            await pullBoard(profile.devices[index])
            return
        }
        guard reportMiss else { return }
        if bridgeLinks[id]?.commandHost.isEmpty == false { return }
        bridgePhase[id] = "기판이 대답하지 않았습니다."
        note("와이파이와 직접 연결 모두 대답이 없습니다. 집 공유기가 없으면 이 기기를 Ronin-C3 에 붙이세요.")
    }

    private static func bridgeRole(_ name: String) -> BridgeCameraRole {
        if name.contains("action") || name.contains("osmo") || name.contains("oa5") || name.contains("ac5") {
            return .action5
        }
        return .gopro
    }

    /// 기판이 주변 고프로와 액션 5 프로의 블루투스 맥 주소를 읽어 칸에 넣습니다.
    func scanCameras(_ id: UUID) async {
        guard let index = profile.devices.firstIndex(where: { $0.id == id && $0.kind == .goproBridge }) else { return }
        let device = profile.devices[index]
        let door = commandDoor(device)
        guard !door.host.isEmpty else {
            bridgePhase[id] = "기판이 아직 대답하지 않았습니다."
            note("와이파이와 직접 연결 모두 대답이 없습니다. 집 공유기가 없으면 이 기기를 Ronin-C3 에 붙이세요.")
            return
        }
        do {
            let found = try await C3Client.nearbyGoPros(door).filter { BoardMac.isFull($0.mac) }
            guard !found.isEmpty else {
                note("주변에서 고프로나 액션 5 프로를 찾지 못했습니다.")
                return
            }
            var slots = BridgeCameraSlot.capped(device.cameras)
            let take = min(4, found.count)
            if slots.count < take {
                slots.append(contentsOf: (0..<(take - slots.count)).map { _ in BridgeCameraSlot() })
            }
            for slotIndex in 0..<take {
                let item = found[slotIndex]
                slots[slotIndex].mac = BoardMac.normalize(item.mac)
                let name = (item.name ?? "").lowercased()
                slots[slotIndex].role = Self.bridgeRole(name)
            }
            profile.devices[index].cameras = slots
            var live = bridgeLive[id] ?? BridgeBoardLive(ssid: "", ip: "", boardMac: BoardMac.normalize(device.boardMac), slots: [:])
            for slot in slots where BoardMac.isFull(slot.mac) {
                let key = BoardMac.normalize(slot.mac)
                if let match = found.first(where: { BoardMac.same($0.mac, key) }) {
                    live.slots[key] = match.attached == true ? "붙음" : "붙지 않음"
                } else if live.slots[key] == nil {
                    live.slots[key] = "붙지 않음"
                }
            }
            bridgeLive[id] = live
            note("주변 카메라 \(take)대를 칸에 넣고 붙음 여부를 바로 표시했습니다.")
            await pullBoard(profile.devices[index])
        } catch {
            note("\(device.name) \(error.localizedDescription)")
        }
    }

    /// 아이폰의 지금 연결입니다. 있는 찾기를 다시 부르고, 카메라가 광고한 이름만 돌려줍니다.
    func phoneSeek(_ id: UUID) async -> PhoneSeek {
        await scanBoard(id)
        guard let device = profile.devices.first(where: { $0.id == id && $0.kind == .goproBridge }) else {
            return .unreachable
        }
        let door = commandDoor(device)
        guard !door.host.isEmpty else { return .unreachable }
        do {
            let found = try await C3Client.nearbyGoPros(door)
            let named = found.compactMap { item -> NearbyGoPro? in
                let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty, BoardMac.isFull(item.mac) else { return nil }
                return item
            }
            if named.isEmpty { return .nonePairing }
            return .cameras(named)
        } catch {
            return .nonePairing
        }
    }

    /// 목록에 나온 이름을 누르면 그 카메라를 칸에 넣고, 기판이 블루투스로 붙습니다.
    func phoneJoin(_ id: UUID, _ item: NearbyGoPro) async {
        guard var device = profile.devices.first(where: { $0.id == id && $0.kind == .goproBridge }) else { return }
        let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, BoardMac.isFull(item.mac) else { return }
        let mac = BoardMac.normalize(item.mac)
        var slots = device.cameras.filter { BoardMac.isFull($0.mac) }
        if let index = slots.firstIndex(where: { BoardMac.same($0.mac, mac) }) {
            slots[index].advertisedName = name
            slots[index].role = Self.bridgeRole(name.lowercased())
        } else if slots.count < 4 {
            var slot = BridgeCameraSlot()
            slot.mac = mac
            slot.advertisedName = name
            slot.role = Self.bridgeRole(name.lowercased())
            slot.face = slot.role == .action5 ? .action5Pro : nil
            slots.append(slot)
        } else {
            note("카메라는 한 기판에 4대까지입니다.")
            return
        }
        guard let index = profile.devices.firstIndex(where: { $0.id == id }) else { return }
        profile.devices[index].cameras = slots
        device.cameras = slots
        let door = commandDoor(profile.devices[index])
        do {
            _ = try await C3Client.cameraPresets(door, mac: mac)
            note("\(name) 을 기판에 연결했습니다.")
        } catch {
            note("\(name) \(error.localizedDescription)")
        }
    }

    func refreshBoard(_ id: UUID) async {
        guard let device = profile.devices.first(where: { $0.id == id }), device.kind == .goproBridge else { return }
        await pullBoard(device)
    }

    /// 대답하는 연결로 명령을 보냅니다. 직접 연결 주소는 와이파이 주소 칸에 저장하지 않습니다.
    func commandDoor(_ device: DeviceRecord) -> DeviceRecord {
        guard device.kind == .goproBridge, let links = bridgeLinks[device.id], !links.commandHost.isEmpty else {
            return device
        }
        var copy = device
        copy.host = links.commandHost
        copy.port = links.commandPort
        return copy
    }

    func bridgeWifiLine(_ id: UUID) -> String {
        bridgeLinks[id]?.wifiLine ?? "기판 와이파이  아직 확인하지 않았습니다."
    }

    func bridgeDirectLine(_ id: UUID) -> String {
        bridgeLinks[id]?.directLine ?? "기판 직접 연결  아직 확인하지 않았습니다."
    }

    private struct BoardProbe: Sendable {
        var live: BridgeBoardLive?
        var wrongBoard: Bool
    }

    private nonisolated static func probeBoard(host: String, port: Int, expect: String) async -> BoardProbe {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, port > 0 else { return BoardProbe(live: nil, wrongBoard: false) }
        guard let live = try? await C3Client.status(host: trimmed, port: port) else {
            return BoardProbe(live: nil, wrongBoard: false)
        }
        guard BoardMac.isFull(live.boardMac) else { return BoardProbe(live: nil, wrongBoard: false) }
        if BoardMac.same(live.boardMac, expect) { return BoardProbe(live: live, wrongBoard: false) }
        return BoardProbe(live: nil, wrongBoard: true)
    }

    /// 로닌 기판은 항상 192.168.100.100 입니다. 다른 주소가 저장돼 있으면 그 주소로 바꿉니다.
    private func applyFixedRoninAddress() {
        var changed = false
        for index in profile.devices.indices where profile.devices[index].kind == .ronin {
            if profile.devices[index].host != RoninBoard.host || profile.devices[index].port != 80 {
                profile.devices[index].host = RoninBoard.host
                profile.devices[index].port = 80
                changed = true
            }
        }
        if changed {
            note("로닌 기판 주소를 192.168.100.100 으로 맞췄습니다.")
        }
    }

    private func pullBoard(_ device: DeviceRecord) async {
        let expect = BoardMac.isFull(device.boardMac) ? BoardMac.normalize(device.boardMac) : BoardMac.pluggedIn
        let port = device.port > 0 ? device.port : DirectBoard.port
        let saved = device.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let houseHost = saved == DirectBoard.host ? "" : saved
        async let wifiProbe = Self.probeBoard(host: houseHost, port: port, expect: expect)
        async let directProbe = Self.probeBoard(host: DirectBoard.host, port: DirectBoard.port, expect: expect)
        let wifi = await wifiProbe
        let direct = await directProbe
        let page = direct.live ?? wifi.live
        let houseName = page?.ssid ?? ""
        let onHouse = !houseName.isEmpty && houseName != "없음"
        let advertised = [direct.live?.directSsid, wifi.live?.directSsid]
            .compactMap { $0 }
            .first { !$0.isEmpty } ?? DirectBoard.ssid
        let wifiUp = wifi.live != nil || (direct.live != nil && onHouse)
        bridgeLinks[device.id] = BridgeLinks(
            wifiUp: wifiUp,
            wifiSsid: wifiUp ? (onHouse ? houseName : (wifi.live?.ssid ?? "")) : "",
            wifiHost: wifiUp ? (wifi.live != nil ? houseHost : DirectBoard.host) : "",
            wifiPort: port,
            directUp: direct.live != nil,
            directSsid: advertised,
            directHost: DirectBoard.host
        )
        if var live = page {
            for slot in device.cameras where BoardMac.isFull(slot.mac) {
                let key = BoardMac.normalize(slot.mac)
                if live.slots[key] == nil {
                    live.slots[key] = "붙지 않음"
                }
            }
            bridgeLive[device.id] = live
            bridgePhase[device.id] = wifi.live != nil ? "기판에 붙었습니다." : "직접 연결에 붙었습니다."
        } else if wifi.wrongBoard || direct.wrongBoard {
            bridgePhase[device.id] = "다른 기판이 대답했습니다."
        } else {
            bridgePhase[device.id] = "기판에 닿지 않았습니다."
        }
    }

    private func watchBoards() async {
        while !Task.isCancelled {
            if !profile.practice {
                let boards = profile.devices.filter { $0.enabled && $0.kind == .goproBridge }
                for device in boards {
                    await pullBoard(device)
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: StudioProfile.storageKey)
        }
    }
}

extension GroupFire {
    static func apply(_ preset: ShootPreset, to device: DeviceRecord) async -> String {
        switch device.kind {
        case .ronin:
            var parts: [String] = []
            if !preset.ronin.shot.isEmpty {
                let scale = min(4, max(0.25, preset.ronin.timeScale))
                let text = try? await RoninClient.command(device, path: "/shot/\(preset.ronin.shot)", query: [
                    "t": String(format: "%.2f", scale),
                ])
                parts.append(text ?? "샷 실패")
            }
            if preset.ronin.sendMove {
                let path = preset.ronin.absolute ? "/move" : "/relative"
                let text = try? await RoninClient.command(device, path: path, query: [
                    "yaw": String(preset.ronin.yaw),
                    "roll": String(preset.ronin.roll),
                    "pitch": String(preset.ronin.pitch),
                    "time": String(preset.ronin.seconds),
                ])
                parts.append(text ?? "이동 실패")
            }
            return parts.isEmpty ? "" : "\(device.name) \(parts.joined(separator: " "))"
        case .goproBridge:
            guard preset.kind == .action,
                  let cameraId = preset.cameraId,
                  let slot = device.cameras.first(where: { $0.id == cameraId }),
                  BoardMac.isFull(slot.mac) else { return "" }
            var parts: [String] = []
            for choice in preset.gopro.settings where choice.enabled {
                let text = try? await C3Client.setSetting(device, mac: slot.mac, setting: choice.settingId, option: choice.option)
                parts.append(text == nil ? "설정 \(choice.settingId) 실패" : "설정 \(choice.settingId)")
            }
            if let id = preset.gopro.loadPresetId {
                let text = try? await C3Client.loadCameraPreset(device, mac: slot.mac, id: id)
                parts.append(text == nil ? "카메라 프리셋 실패" : "카메라 프리셋 \(id)")
            }
            return parts.isEmpty ? "" : "\(device.name) \(parts.joined(separator: ", "))"
        case .gopro, .goproAction5:
            var parts: [String] = []
            for choice in preset.gopro.settings where choice.enabled {
                let text = try? await GoProClient.setSetting(device, setting: choice.settingId, option: choice.option)
                parts.append(text == nil ? "설정 \(choice.settingId) 실패" : "설정 \(choice.settingId)")
            }
            if device.kind == .gopro {
                if let id = preset.gopro.loadPresetId {
                    let text = try? await GoProClient.loadPreset(device, id: id)
                    parts.append(text == nil ? "프리셋 실패" : "카메라 프리셋 \(id)")
                }
                if let zoom = preset.gopro.digitalZoomPercent {
                    let text = try? await GoProClient.digitalZoom(device, percent: zoom)
                    parts.append(text == nil ? "줌 실패" : "디지털 줌")
                }
            } else if preset.gopro.loadPresetId != nil || preset.gopro.digitalZoomPercent != nil {
                parts.append("줌과 카메라 프리셋은 오즈모 액션 5 프로 중계에 없습니다")
            }
            return parts.isEmpty ? "" : "\(device.name) \(parts.joined(separator: ", "))"
        case .osmoAction, .osmoNoAPI:
            return ""
        }
    }
}
