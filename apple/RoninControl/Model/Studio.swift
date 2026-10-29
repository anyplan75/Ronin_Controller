import Combine
import Foundation

struct ClockSample: Sendable {
    var millis: UInt32
    var mid: Date
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
            return ["\(device.name) 기판에 아직 붙지 않았습니다."]
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
        Task { await bootBoards() }
        Task { await maintainGoProSessions() }
    }

    func note(_ text: String) {
        log.insert("\(Self.stamp.string(from: Date()))  \(text)", at: 0)
        if log.count > 40 {
            log.removeLast(log.count - 40)
        }
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
            host: product.kind == .gopro ? "10.5.5.9" : "",
            port: product.kind.defaultPort,
            bleIdentifier: "",
            enabled: true,
            pairedOnce: false,
            boardMac: product.kind == .goproBridge && !boardAlready ? knownMac : "",
            cameras: product.kind == .goproBridge ? BridgeCameraSlot.emptyFour() : []
        )
        profile.devices.append(device)
        profile.groupIds.append(device.id)
    }

    func deleteDevice(_ id: UUID) {
        profile.devices.removeAll { $0.id == id }
        profile.groupIds.removeAll { $0 == id }
        profile.stageSpots.removeAll { $0.deviceId == id }
        for index in profile.presets.indices {
            profile.presets[index].deviceIds.removeAll { $0 == id }
        }
    }

    func addPreset() {
        let preset = ShootPreset(
            id: UUID(),
            name: "프리셋 \(profile.presets.count + 1)",
            note: "",
            deviceIds: profile.groupIds,
            ronin: RoninLook(shot: "wide", timeScale: 1, sendMove: false, yaw: 0, roll: 0, pitch: 0, seconds: 1.5, absolute: true),
            gopro: GoProCatalog.freshLook(),
            osmo: OsmoLook(mode: nil),
            connections: profile.devices
        )
        profile.presets.append(preset)
    }

    func deletePreset(_ id: UUID) {
        profile.presets.removeAll { $0.id == id }
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
        if let homeYaw { spot.homeYaw = min(180, max(-180, homeYaw)) }
        if let homePitch { spot.homePitch = min(180, max(-180, homePitch)) }
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
                    goproLive[device.id] = live
                }
            case .goproBridge:
                if !device.host.isEmpty {
                    await pullBoard(device)
                }
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
                    goproLive[device.id] = live
                }
            case .goproBridge:
                await refreshBoard(device.id)
            case .osmoAction, .osmoNoAPI:
                break
            }
        }
    }

    func together(start: Bool) async {
        let devices = grouped
        guard !devices.isEmpty else {
            note("선택된 장치가 없습니다.")
            return
        }
        if profile.practice {
            note("연습: 함께 \(start ? "시작" : "정지"). \(devices.map(\.name).joined(separator: ", ")). 장치에 보내지 않았습니다.")
            return
        }
        let lead = min(10000, max(0, profile.leadMs))
        let ronins = devices.filter { $0.kind == .ronin }
        var samples: [UUID: ClockSample] = [:]
        await withTaskGroup(of: (UUID, ClockSample)?.self) { group in
            for device in ronins {
                group.addTask { await GroupFire.clock(device) }
            }
            for await item in group {
                if let item { samples[item.0] = item.1 }
            }
        }
        let when = Date().addingTimeInterval(Double(max(lead, 50)) / 1000)
        var lines: [String] = []
        await withTaskGroup(of: String.self) { group in
            for device in ronins {
                let sample = samples[device.id]
                group.addTask {
                    await GroupFire.ronin(device, startRecording: start, when: when, sample: sample, lead: lead)
                }
            }
            for device in devices where device.kind.isGoProFamily {
                group.addTask { await GroupFire.gopro(device, startRecording: start, when: when) }
            }
            for await line in group { lines.append(line) }
        }
        lines.forEach(note)
        let osmos = devices.filter { $0.kind == .osmoAction }
        if osmos.count > 1 {
            note("오즈모가 여러 대이면 블루투스 명령이 한 대씩 나가 시작이 조금 어긋날 수 있습니다.")
        }
        for device in osmos {
            await GroupFire.wait(until: when)
            note((await radio.record(device, start: start)).text)
        }
        let bridges = devices.filter { $0.kind == .goproBridge }
        if bridges.contains(where: { $0.cameras.filter { BoardMac.isFull($0.mac) }.count > 1 }) {
            note("C3 기판은 블루투스를 한 대씩만 쓰므로 카메라가 순서대로 출발합니다.")
        }
        for device in bridges {
            await GroupFire.wait(until: when)
            let lines = await GroupFire.bridge(device, startRecording: start)
            lines.forEach(note)
            await pullBoard(device)
        }
        for device in devices where device.kind == .osmoNoAPI {
            note("\(device.name): 공개된 제어 API가 없어 함께 \(start ? "시작" : "정지")에서 빠졌습니다.")
        }
    }

    func bridgeRecord(_ device: DeviceRecord, start: Bool) async {
        if profile.practice {
            note("연습: \(device.name) \(start ? "시작" : "정지")")
            return
        }
        let lines = await GroupFire.bridge(device, startRecording: start)
        lines.forEach(note)
        if !device.host.isEmpty {
            await pullBoard(device)
        }
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
                group.addTask { await GroupFire.apply(preset, to: device) }
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

    /// 휠을 누르는 동안만 보냅니다. 성공 기록은 남기지 않아 로그가 넘치지 않습니다.
    func roninHold(_ device: DeviceRecord, path: String?) async {
        if profile.practice { return }
        do {
            if let path {
                _ = try await RoninClient.command(device, path: path, query: ["speed": "30"])
            } else {
                _ = try await RoninClient.command(device, path: "/stop")
            }
        } catch {
            note("\(device.name) \(error.localizedDescription)")
        }
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
        do {
            let text = try await RoninClient.command(device, path: path, query: query)
            note("\(device.name) \(path) \(text)")
        } catch {
            note("\(device.name) \(error.localizedDescription)")
        }
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
            ensureKnownBoard()
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

    /// 꽂힌 기판이 목록에 없으면 맥 주소로 넣고, 찾는 즉시 붙습니다.
    private func bootBoards() async {
        ensureKnownBoard()
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
        await watchBoards()
    }

    private func ensureKnownBoard() {
        let mac = BoardMac.pluggedIn
        if profile.devices.contains(where: { $0.kind == .goproBridge && BoardMac.same($0.boardMac, mac) }) {
            return
        }
        if let index = profile.devices.firstIndex(where: { $0.kind == .goproBridge && !BoardMac.isFull($0.boardMac) }) {
            profile.devices[index].boardMac = mac
            profile.devices[index].port = 80
            profile.devices[index].cameras = BridgeCameraSlot.padded(profile.devices[index].cameras)
            bridgePhase[profile.devices[index].id] = "기판을 찾는 중입니다."
            note("꽂힌 C3 기판 \(mac) 을 등록하고 바로 연결합니다.")
            return
        }
        guard profile.devices.count < StudioProfile.maxDevices else {
            note("C3 기판을 넣을 자리가 없습니다. 장치는 8대까지입니다.")
            return
        }
        let device = DeviceRecord(
            id: UUID(),
            name: "C3 중계",
            kind: .goproBridge,
            osmoModel: .unknown,
            host: "",
            port: 80,
            bleIdentifier: "",
            enabled: true,
            pairedOnce: false,
            boardMac: mac,
            cameras: BridgeCameraSlot.emptyFour()
        )
        profile.devices.append(device)
        if !profile.groupIds.contains(device.id) {
            profile.groupIds.append(device.id)
        }
        bridgePhase[device.id] = "기판을 찾는 중입니다."
        note("꽂힌 C3 기판 \(mac) 을 등록하고 바로 연결합니다.")
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
            if bridgePhase[device.id] == "기판에 붙었습니다." { continue }
            bridgePhase[device.id] = text
        }
    }

    /// 같은 망에서 기판을 찾고, 그 기판이 대답한 맥 주소만 넣습니다.
    func scanBoard(_ id: UUID) async {
        guard profile.devices.contains(where: { $0.id == id && $0.kind == .goproBridge }) else { return }
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
            profile.devices[index].boardMac = BoardMac.pluggedIn
            profile.devices[index].host = item.host
            profile.devices[index].port = item.port
            bridgeLive[id] = live
            bridgePhase[id] = "기판이 대답했습니다."
            note("기판이 대답해서 맥 주소 \(BoardMac.pluggedIn) 를 넣었습니다.")
            return
        }
        bridgePhase[id] = "기판이 대답하지 않았습니다."
        note("같은 망에서 그 기판의 대답을 듣지 못했습니다.")
    }

    /// 기판이 주변 고프로의 블루투스 맥 주소를 읽어 빈 칸부터 채웁니다.
    func scanCameras(_ id: UUID) async {
        guard let index = profile.devices.firstIndex(where: { $0.id == id && $0.kind == .goproBridge }) else { return }
        let device = profile.devices[index]
        guard !device.host.isEmpty else {
            bridgePhase[id] = "기판이 아직 대답하지 않았습니다."
            note("기판이 아직 대답하지 않았습니다.")
            return
        }
        do {
            let found = try await C3Client.nearbyGoPros(device).filter { BoardMac.isFull($0.mac) }
            guard !found.isEmpty else {
                note("주변에서 고프로를 찾지 못했습니다.")
                return
            }
            var slots = BridgeCameraSlot.padded(device.cameras)
            let take = min(4, found.count)
            for slotIndex in 0..<take {
                let item = found[slotIndex]
                slots[slotIndex].mac = BoardMac.normalize(item.mac)
                let name = (item.name ?? "").lowercased()
                slots[slotIndex].role = (name.contains("action") || name.contains("osmo")) ? .action5 : .gopro
            }
            profile.devices[index].cameras = slots
            note("주변 고프로 \(take)대의 맥 주소를 칸에 넣었습니다.")
            await pullBoard(profile.devices[index])
        } catch {
            note("\(device.name) \(error.localizedDescription)")
        }
    }

    func refreshBoard(_ id: UUID) async {
        guard let device = profile.devices.first(where: { $0.id == id }), device.kind == .goproBridge else { return }
        if device.host.isEmpty {
            if bridgePhase[id] != "기판에 붙었습니다." {
                bridgePhase[id] = bridgePhase[id] ?? "기판을 찾는 중입니다."
            }
            return
        }
        await pullBoard(device)
    }

    private func pullBoard(_ device: DeviceRecord) async {
        guard !device.host.isEmpty else { return }
        do {
            let live = try await C3Client.status(device)
            bridgeLive[device.id] = live
            if BoardMac.isFull(live.boardMac), BoardMac.isFull(device.boardMac), !BoardMac.same(live.boardMac, device.boardMac) {
                bridgePhase[device.id] = "다른 기판이 대답했습니다."
            } else {
                bridgePhase[device.id] = "기판에 붙었습니다."
            }
        } catch {
            bridgePhase[device.id] = "기판에 닿지 않았습니다."
        }
    }

    private func watchBoards() async {
        while !Task.isCancelled {
            if !profile.practice {
                let boards = profile.devices.filter { $0.enabled && $0.kind == .goproBridge && !$0.host.isEmpty }
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
            return ""
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
