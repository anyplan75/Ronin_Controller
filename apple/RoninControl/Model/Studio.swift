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
    /// 이름 붙인 장소 설정 목록입니다. 지금 화면 프로필과 따로 둡니다.
    @Published var venues: VenueBook {
        didSet { saveVenues() }
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
    /// OLED·RMSID·S3 동시 연결. 하나 고른다고 다른 보드를 끊지 않습니다.
    let c3Bag = C3SocketBag()
    /// 호환용 — 지정 보드 소켓. 없으면 빈 UUID 소켓(연결 전).
    func c3Socket(for id: UUID) -> C3JobSocket { c3Bag.socket(for: id) }
    func c3Socket(for board: C3BoardRecord) -> C3JobSocket { c3Bag.socket(for: board.id) }
    /// 화면이 지금 보여주는 팬·틸트·줌입니다. 컴패니언 저장이 이 값을 넣습니다.
    @Published var ptzLive: [UUID: PtzScene.Aim] = [:]
    /// 장면 부르기가 화면 슬라이더를 따라가게 하는 번호입니다.
    @Published var ptzRecallTick = 0
    /// 시작·재확인 때 슬롯별 WS hello 응답. key=oled/rmsid/s3, false=망 무응답.
    @Published var boardLanAlive: [String: Bool] = [:]
    private let sceneDoor = PtzSceneDoor()
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
        if let data = UserDefaults.standard.data(forKey: VenueBook.storageKey),
           let saved = try? JSONDecoder().decode(VenueBook.self, from: data) {
            venues = saved
        } else {
            venues = .empty()
        }
        if !frameOK {
            note("프레임 검사가 실패했습니다. 오즈모 명령 형식이 공식 예시와 다릅니다.")
        }
        dropSeparateRoninBoards()
        let lane = BoardLane(stored: profile.boardLane)
        boardSocket.lane = lane
        if !profile.olimexLanHost.isEmpty {
            boardSocket.reportedHost = profile.olimexLanHost
            boardSocket.reportedPort = 81
        }
        Task { await bootBoards() }
        Task { await maintainGoProSessions() }
        sceneDoor.onRequest = { [weak self] method, target, body in
            await self?.handlePtzDoor(method: method, target: target, body: body) ?? "{\"ok\":false,\"reason\":\"앱이 없습니다.\"}"
        }
        sceneDoor.start()
    }

    func note(_ text: String) {
        log.insert("\(Self.stamp.string(from: Date()))  \(text)", at: 0)
        if log.count > 40 {
            log.removeLast(log.count - 40)
        }
    }

    var roninC3: C3BoardRecord? {
        let ronins = profile.c3Boards.filter { $0.duty == .ronin }
        if let live = ronins.first(where: { c3Bag.state(for: $0.id) == .online }) {
            return live
        }
        return profile.c3Boards.first { $0.boardSlot == .oled }
            ?? profile.c3Boards.first { $0.boardSlot == .rmsid }
            ?? profile.c3Boards.first { $0.duty == .ronin }
    }

    /// 올리멕스 ESP32-PoE 를 스튜디오 기판으로 등록합니다. 액션 카메라는 이 기판 블루투스입니다.
    func registerOlimex() {
        if profile.olimexRegistered {
            note("올리멕스 ESP32-PoE 는 이미 등록되어 있습니다.")
            return
        }
        profile.olimexRegistered = true
        if profile.olimexName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profile.olimexName = "올리멕스 · 고프로·액션5"
        }
        note("올리멕스 ESP32-PoE 를 등록했습니다. 고프로·액션5는 이 기판, 로닌은 OLED/RMSID C3, 조명은 S3 가 맡습니다.")
    }

    /// 예전 등록 창용. 슬롯 없이 job만 고르면 기본 슬롯으로 맞춥니다.
    func registerC3(_ job: C3Job) {
        registerBoardSlot(job == .light ? .s3 : .oled)
    }

    /// 슬롯 하나로 등록하거나 갱신합니다. MAC·고정 IP로 구분합니다.
    func registerBoardSlot(_ slot: C3Slot) {
        let id = upsertKnownSlot(slot)
        sortBoardRoles()
        if let board = profile.c3Boards.first(where: { $0.id == id }) {
            note("\(board.listTitle) 자리를 잡았습니다. \(slot.defaultHost) · \(slot.knownWifiMac)")
        }
    }

    /// OLED→RS2, RMSID→SC, S3→울란지 자리를 맞추고, 구 C3 중복을 뺍니다.
    func syncBoardRoles(quiet: Bool = false) {
        var keep: [UUID] = []
        for slot in C3Slot.allCases {
            keep.append(upsertKnownSlot(slot))
        }
        let knownMacs = Set(C3Slot.allCases.map { BoardMac.normalize($0.knownWifiMac) })
        let knownHosts = Set(C3Slot.allCases.map(\.defaultHost))
        let before = profile.c3Boards.count
        profile.c3Boards.removeAll { board in
            if keep.contains(board.id) { return false }
            let mac = BoardMac.normalize(board.wifiMac)
            if BoardMac.isFull(mac), knownMacs.contains(mac) { return true }
            let host = board.lanHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if knownHosts.contains(host) { return true }
            if board.slot.isEmpty { return true }
            return false
        }
        sortBoardRoles()
        guard !quiet else { return }
        let dropped = before - profile.c3Boards.count
        if dropped > 0 {
            note("보드 자리: OLED·RS2, RMSID·SC, S3·울란지. 중복 \(dropped)개를 뺐습니다.")
        } else {
            note("보드 자리: OLED·RS2, RMSID·SC, S3·울란지.")
        }
    }

    /// 앱을 열면 알려진 세 자리를 목록에 두고, 살아 있는 호스트는 WS hello 로 맞춥니다.
    func ensureBoardRolesOnLaunch() async {
        syncBoardRoles(quiet: true)
        await refreshBoardLanAlive()
        // OLED·RMSID·S3 를 한꺼번에 붙입니다. 예전엔 한 소켓이라 하나만 살아 있었습니다.
        reconnectAllC3()
    }

    /// OLED=.152 / S3=.153 / RMSID=.154 WS hello 를 다시 찍어 망 응답을 표시합니다.
    func refreshBoardLanAlive() async {
        var live: [String] = []
        var dead: [String] = []
        var next: [String: Bool] = [:]
        for slot in C3Slot.allCases {
            if let hello = await BoardHello.probe(host: slot.defaultHost) {
                applyBoardHello(
                    boardId: nil,
                    slot: hello.slot.isEmpty ? slot.rawValue : hello.slot,
                    wifi: hello.wifiMac,
                    host: hello.host.isEmpty ? slot.defaultHost : hello.host
                )
                next[slot.rawValue] = true
                live.append("\(slot.boardTitle) \(hello.host.isEmpty ? slot.defaultHost : hello.host)")
            } else {
                next[slot.rawValue] = false
                dead.append("\(slot.boardTitle) \(slot.defaultHost):82")
            }
        }
        boardLanAlive = next
        sortBoardRoles()
        if live.isEmpty {
            note("보드 자리 3대를 목록에 두었습니다. 망에서 응답한 보드는 아직 없습니다. (\(dead.joined(separator: ", ")))")
        } else if dead.isEmpty {
            note("망에서 응답: \(live.joined(separator: ", ")). 목록에 OLED·RMSID·S3 자리를 맞췄습니다.")
        } else {
            note("망 응답 \(live.joined(separator: ", ")). 무응답 \(dead.joined(separator: ", ")). 로닌은 OLED/RMSID 가 살아 있어야 붙습니다.")
        }
    }

    @discardableResult
    private func upsertKnownSlot(_ slot: C3Slot) -> UUID {
        let mac = BoardMac.normalize(slot.knownWifiMac)
        if let index = profile.c3Boards.firstIndex(where: { BoardMac.same($0.wifiMac, mac) })
            ?? profile.c3Boards.firstIndex(where: { $0.boardSlot == slot })
            ?? profile.c3Boards.firstIndex(where: {
                $0.lanHost.trimmingCharacters(in: .whitespacesAndNewlines) == slot.defaultHost
            }) {
            profile.c3Boards[index].slot = slot.rawValue
            profile.c3Boards[index].job = slot.job.rawValue
            profile.c3Boards[index].wifiMac = mac
            profile.c3Boards[index].lanHost = slot.defaultHost
            profile.c3Boards[index].linkMode = BoardLane.lan.rawValue
            if profile.c3Boards[index].name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || profile.c3Boards[index].name.hasPrefix("C3 ")
                || profile.c3Boards[index].name == "C3 로닌"
                || profile.c3Boards[index].name == "C3 울란지 조명" {
                profile.c3Boards[index].name = slot.listTitle
            }
            return profile.c3Boards[index].id
        }
        let board = C3BoardRecord(
            id: UUID(),
            name: slot.listTitle,
            job: slot.job.rawValue,
            slot: slot.rawValue,
            lanHost: slot.defaultHost,
            wifiMac: mac
        )
        profile.c3Boards.append(board)
        return board.id
    }

    private func sortBoardRoles() {
        let order: [C3Slot?] = [.oled, .rmsid, .s3, nil]
        profile.c3Boards.sort { left, right in
            let li = order.firstIndex(of: left.boardSlot) ?? order.count
            let ri = order.firstIndex(of: right.boardSlot) ?? order.count
            return li < ri
        }
    }

    /// 웹소켓 hello 의 슬롯·MAC·주소로 해당 보드를 맞춥니다.
    func applyBoardHello(boardId: UUID?, slot: String, wifi: String, host: String) {
        let inferred = C3Slot.from(text: slot)
            ?? C3Slot.from(mac: wifi)
            ?? C3Slot.from(host: host)
        guard let inferred else {
            if let boardId {
                rememberC3(boardId, wifi: wifi, hotspot: "")
            }
            return
        }
        let id = upsertKnownSlot(inferred)
        if let index = profile.c3Boards.firstIndex(where: { $0.id == id }) {
            if !host.isEmpty { profile.c3Boards[index].lanHost = host }
            if BoardMac.isFull(wifi) { profile.c3Boards[index].wifiMac = BoardMac.normalize(wifi) }
            profile.c3Boards[index].slot = inferred.rawValue
            profile.c3Boards[index].job = inferred.job.rawValue
        }
        if let boardId, boardId != id {
            profile.c3Boards.removeAll { $0.id == boardId && $0.boardSlot == nil }
        }
        sortBoardRoles()
    }

    var olimexTitle: String {
        let name = profile.olimexName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "올리멕스 · 고프로·액션5" : name
    }

    func renameOlimex(_ name: String) {
        profile.olimexName = name
    }

    func renameC3(_ id: UUID, _ name: String) {
        guard let index = profile.c3Boards.firstIndex(where: { $0.id == id }) else { return }
        profile.c3Boards[index].name = name
    }

    func renamePtz(_ id: UUID, _ name: String) {
        guard let index = profile.ptzCameras.firstIndex(where: { $0.id == id }) else { return }
        profile.ptzCameras[index].name = name
    }

    func rememberOlimex(wifi: String, ethernet: String, hotspot: String) {
        if !wifi.isEmpty, profile.olimexWifiMac != wifi { profile.olimexWifiMac = wifi }
        if !ethernet.isEmpty, profile.olimexEthMac != ethernet { profile.olimexEthMac = ethernet }
        if !hotspot.isEmpty, profile.olimexApMac != hotspot { profile.olimexApMac = hotspot }
    }

    func rememberC3(_ id: UUID, wifi: String, hotspot: String) {
        guard let index = profile.c3Boards.firstIndex(where: { $0.id == id }) else { return }
        if !wifi.isEmpty {
            let mac = BoardMac.normalize(wifi)
            profile.c3Boards[index].wifiMac = mac
            if let slot = C3Slot.from(mac: mac) {
                profile.c3Boards[index].slot = slot.rawValue
                profile.c3Boards[index].job = slot.job.rawValue
                if profile.c3Boards[index].lanHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    profile.c3Boards[index].lanHost = slot.defaultHost
                }
                if profile.c3Boards[index].name.hasPrefix("C3 ")
                    || profile.c3Boards[index].name == "C3 로닌"
                    || profile.c3Boards[index].name == "C3 울란지 조명" {
                    profile.c3Boards[index].name = slot.listTitle
                }
            }
        }
        if !hotspot.isEmpty { profile.c3Boards[index].apMac = hotspot }
    }

    func rememberPtzMac(_ id: UUID, _ mac: String) {
        guard !mac.isEmpty, let index = profile.ptzCameras.firstIndex(where: { $0.id == id }) else { return }
        if profile.ptzCameras[index].mac != mac { profile.ptzCameras[index].mac = mac }
    }

    func rememberPtzEndpoint(_ id: UUID, _ endpoint: String) {
        guard !endpoint.isEmpty, let index = profile.ptzCameras.firstIndex(where: { $0.id == id }) else { return }
        if profile.ptzCameras[index].endpoint != endpoint {
            profile.ptzCameras[index].endpoint = endpoint
        }
    }

    /// 블루투스 처음 설정이 알려 준 집 망 주소로 웹소켓을 엽니다.
    func adoptLan(_ kind: SeenBoard.Kind, host: String, port: Int, radios: BoardRadios = BoardRadios(), name: String = "") {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .olimex:
            profile.olimexRegistered = true
            profile.olimexLanHost = host
            profile.boardLane = BoardLane.lan.rawValue
            if !cleanName.isEmpty { profile.olimexName = cleanName }
            rememberOlimex(wifi: radios.wifi, ethernet: radios.ethernet, hotspot: radios.hotspot)
            boardSocket.lane = .lan
            boardSocket.reportedHost = host
            boardSocket.reportedPort = port
            boardSocket.connect()
            note("\(olimexTitle) 가 \(host):\(port) 로 집 망에 붙었다고 답했습니다. 그 주소의 웹소켓을 엽니다.")
        case .c3:
            profile.lastC3Host = host
            if !cleanName.isEmpty { profile.lastC3Name = cleanName }
            let slot = radios.resolvedSlot
                ?? C3Slot.from(mac: radios.wifi)
                ?? C3Slot.from(host: host)
                ?? C3Slot.from(bleName: cleanName)
                ?? (cleanName.lowercased().contains("light") || cleanName.lowercased().contains("ulanzi") ? .s3 : nil)
            if let slot {
                let id = upsertKnownSlot(slot)
                if let index = profile.c3Boards.firstIndex(where: { $0.id == id }) {
                    profile.c3Boards[index].lanHost = host
                    profile.c3Boards[index].linkMode = BoardLane.lan.rawValue
                    rememberC3(id, wifi: radios.wifi, hotspot: radios.hotspot)
                    note("\(profile.c3Boards[index].listTitle) 주소를 \(host):\(port) 로 저장했습니다.")
                }
                sortBoardRoles()
            } else if let index = profile.c3Boards.firstIndex(where: { BoardMac.same($0.wifiMac, radios.wifi) && BoardMac.isFull(radios.wifi) })
                ?? profile.c3Boards.firstIndex(where: { $0.lanHost == host }) {
                profile.c3Boards[index].lanHost = host
                profile.c3Boards[index].linkMode = BoardLane.lan.rawValue
                if !cleanName.isEmpty { profile.c3Boards[index].name = cleanName }
                rememberC3(profile.c3Boards[index].id, wifi: radios.wifi, hotspot: radios.hotspot)
                note("\(profile.c3Boards[index].listTitle) 주소를 \(host):\(port) 로 저장했습니다.")
            } else {
                note("C3 \(cleanName.isEmpty ? "" : cleanName) 가 \(host):\(port) 로 붙었다고 답했습니다. 「보드 자리 맞추기」로 OLED/RMSID/S3 를 등록하세요.")
            }
        }
    }

    func addPtz(host: String, username: String, password: String, name: String = "", onvifPort: Int = 2000, viscaPort: Int = 1259, mac: String = "") {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.hasPrefix("192.168.10."), clean.split(separator: ".").count == 4 else {
            note("PTZ 주소는 192.168.10.x 만 됩니다.")
            return
        }
        let onvif = (1...65535).contains(onvifPort) ? onvifPort : 2000
        let visca = (1...65535).contains(viscaPort) ? viscaPort : 1259
        let endpoint = "http://\(clean):\(onvif)/onvif/device_service"
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = title.isEmpty ? "PTZ \(clean)" : title
        if let index = profile.ptzCameras.firstIndex(where: { $0.host == clean }) {
            FieldSecret.save(password, account: profile.ptzCameras[index].id.uuidString)
            profile.ptzCameras[index].endpoint = endpoint
            profile.ptzCameras[index].onvifPort = onvif
            profile.ptzCameras[index].viscaPort = visca
            profile.ptzCameras[index].name = display
            if !mac.isEmpty { profile.ptzCameras[index].mac = mac }
            if !username.isEmpty { profile.ptzCameras[index].username = username }
            note("\(display) 설정을 바로 저장했습니다. ONVIF \(onvif), Visca \(visca).")
            return
        }
        let camera = PtzRecord(id: UUID(), name: display, host: clean, username: username, endpoint: endpoint, mac: mac, onvifPort: onvif, viscaPort: visca)
        profile.ptzCameras.append(camera)
        FieldSecret.save(password, account: camera.id.uuidString)
        let index = profile.ptzCameras.count
        moveStage(deviceId: camera.id, x: -3 + Double(index) * 1.4, y: 6, z: 1.6)
        note("\(display) 을 바로 등록했습니다. ONVIF \(onvif), Visca \(visca). 찾기를 기다리지 않습니다.")
    }

    func rememberPtzAim(_ id: UUID, pan: Double, tilt: Double, zoom: Double) {
        ptzLive[id] = PtzScene.Aim(pan: pan, tilt: tilt, zoom: zoom)
    }

    func renamePtzScene(_ cameraId: UUID, number: Int, name: String) {
        guard var scene = scene(cameraId, number) else { return }
        scene.name = name.isEmpty ? "장면 \(number)" : name
        write(scene, cameraId: cameraId)
    }

    func savePtzScene(_ cameraId: UUID, number: Int, pan: Double, tilt: Double, zoom: Double) async {
        guard var scene = scene(cameraId, number), let camera = profile.ptzCameras.first(where: { $0.id == cameraId }) else { return }
        scene.pan = pan
        scene.tilt = tilt
        scene.zoom = zoom
        scene.saved = true
        write(scene, cameraId: cameraId)
        let stored = await Visca.memory(host: camera.host, port: UInt16(camera.viscaPort), number: number, recall: false)
        note("\(camera.name) \(scene.stableId) 에 팬 \(Int(pan))°, 틸트 \(Int(tilt))°, 줌 \(Int(zoom * 100))% 를 넣었습니다.\(stored ? " 카메라도 그 번호를 받았습니다." : "")")
    }

    func recallPtzScene(_ cameraId: UUID, number: Int) async -> String {
        guard let scene = scene(cameraId, number), let camera = profile.ptzCameras.first(where: { $0.id == cameraId }) else {
            return "그 장면이 없습니다."
        }
        guard scene.saved else {
            let text = "\(scene.stableId) 은 아직 저장되지 않았습니다."
            note(text)
            return text
        }
        rememberPtzAim(cameraId, pan: scene.pan, tilt: scene.tilt, zoom: scene.zoom)
        ptzRecallTick += 1
        let password = FieldSecret.load(account: camera.id.uuidString)
        let moved = await Onvif.move(
            host: camera.host,
            endpoint: camera.endpoint,
            user: camera.username,
            password: password,
            pan: scene.pan,
            tilt: scene.tilt,
            zoom: scene.zoom,
            viscaPort: camera.viscaPort
        )
        if moved.0.contains("받았습니다") {
            if !moved.1.isEmpty { rememberPtzEndpoint(camera.id, moved.1) }
            note(moved.0)
            return moved.0
        }
        if await Visca.memory(host: camera.host, port: UInt16(camera.viscaPort), number: number, recall: true) {
            let text = "\(camera.host) Visca가 \(scene.stableId) 을 불러왔습니다."
            note(text)
            return text
        }
        note(moved.0)
        return moved.0
    }

    /// 이동형 프리셋(경로) 최대 개수 — UI3.
    static let maxTravelPresets = 20

    /// 이동형 경로에 정지 장면 한 칸을 붙입니다.
    func appendPtzMoveStep(_ cameraId: UUID, sceneNumber: Int, dwellSeconds: Double = 2, pathId: UUID? = nil) {
        guard let index = profile.ptzCameras.firstIndex(where: { $0.id == cameraId }) else { return }
        var paths = profile.ptzCameras[index].movePaths
        if paths.isEmpty {
            paths = [PtzMovePath(name: "경로 1", steps: [])]
        }
        let pathIndex: Int = {
            if let pathId, let found = paths.firstIndex(where: { $0.id == pathId }) { return found }
            return 0
        }()
        paths[pathIndex].steps.append(PtzMoveStep(sceneNumber: sceneNumber, dwellSeconds: dwellSeconds))
        profile.ptzCameras[index].movePaths = paths
        note("\(profile.ptzCameras[index].name) \(paths[pathIndex].name)에 장면 \(sceneNumber) 을 넣었습니다.")
    }

    /// 뮤직뱅크형 이동 경로를 하나 더 만듭니다(최대 20).
    @discardableResult
    func addPtzMovePath(_ cameraId: UUID, name: String = "") -> PtzMovePath? {
        guard let index = profile.ptzCameras.firstIndex(where: { $0.id == cameraId }) else { return nil }
        if profile.ptzCameras[index].movePaths.count >= Self.maxTravelPresets {
            note("이동형 프리셋은 최대 \(Self.maxTravelPresets)개입니다.")
            return nil
        }
        let n = profile.ptzCameras[index].movePaths.count + 1
        let path = PtzMovePath(name: name.isEmpty ? "경로 \(n)" : name, steps: [])
        profile.ptzCameras[index].movePaths.append(path)
        note("\(profile.ptzCameras[index].name)에 \(path.name) 을 추가했습니다.")
        return path
    }

    func clearPtzMovePath(_ cameraId: UUID, pathId: UUID? = nil) {
        guard let index = profile.ptzCameras.firstIndex(where: { $0.id == cameraId }) else { return }
        if let pathId, let p = profile.ptzCameras[index].movePaths.firstIndex(where: { $0.id == pathId }) {
            profile.ptzCameras[index].movePaths[p].steps = []
            note("\(profile.ptzCameras[index].name) \(profile.ptzCameras[index].movePaths[p].name) 을 비웠습니다.")
            return
        }
        profile.ptzCameras[index].movePaths = [PtzMovePath(name: "경로 1", steps: [])]
        note("\(profile.ptzCameras[index].name) 이동 경로를 비웠습니다.")
    }

    func deletePtzMovePath(_ cameraId: UUID, pathId: UUID) {
        guard let index = profile.ptzCameras.firstIndex(where: { $0.id == cameraId }) else { return }
        profile.ptzCameras[index].movePaths.removeAll { $0.id == pathId }
        if profile.ptzCameras[index].movePaths.isEmpty {
            profile.ptzCameras[index].movePaths = [PtzMovePath(name: "경로 1", steps: [])]
        }
        note("이동형 프리셋을 지웠습니다.")
    }

    /// 이동형 프리셋 Recall. Stop 은 호출 쪽에서 Task 를 취소합니다.
    func recallPtzMovePath(_ cameraId: UUID, path: PtzMovePath) async {
        guard !path.steps.isEmpty else {
            note("이동 경로가 비어 있습니다.")
            return
        }
        note("\(path.name) 시퀀스 \(path.steps.count)칸을 부릅니다.")
        for step in path.steps {
            if Task.isCancelled { break }
            _ = await recallPtzScene(cameraId, number: step.sceneNumber)
            let wait = max(0.3, step.dwellSeconds)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        if !Task.isCancelled {
            note("\(path.name) 시퀀스를 끝냈습니다.")
        }
    }

    func handlePtzDoor(method: String, target: String, body: String) async -> String {
        let pieces = target.split(separator: "?", maxSplits: 1).map(String.init)
        let path = pieces.first ?? "/"
        let query = pieces.count > 1 ? pieces[1] : ""
        let host = query.split(separator: "&").compactMap { item -> String? in
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, pair[0] == "host" else { return nil }
            return pair[1].removingPercentEncoding ?? pair[1]
        }.first
        guard let camera = ptzCamera(host: host) else {
            return "{\"ok\":false,\"reason\":\"PTZ가 없습니다.\"}"
        }
        if method == "GET" && (path == "/v1/ptz/scenes" || path == "/ptz/scenes") {
            let rows = PtzScene.ten(camera.scenes).map { sceneJSON($0, host: camera.host) }.joined(separator: ",")
            return "{\"ok\":true,\"host\":\"\(camera.host)\",\"scenes\":[\(rows)]}"
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "v1" || parts[0] == "ptz" else {
            return "{\"ok\":false,\"reason\":\"주소를 모르겠습니다.\"}"
        }
        let numberIndex = parts[0] == "v1" ? 3 : 2
        guard parts.count > numberIndex, let number = Int(parts[numberIndex]), (1...10).contains(number) else {
            return "{\"ok\":false,\"reason\":\"장면 번호는 1부터 10입니다.\"}"
        }
        let action = parts.count > numberIndex + 1 ? parts[numberIndex + 1] : "recall"
        if method == "POST" && action == "name" {
            let name = jsonString(body, key: "name") ?? "장면 \(number)"
            renamePtzScene(camera.id, number: number, name: name)
        } else if method == "POST" && action == "save" {
            let aim = ptzLive[camera.id] ?? PtzScene.Aim()
            await savePtzScene(camera.id, number: number, pan: aim.pan, tilt: aim.tilt, zoom: aim.zoom)
        } else if method == "POST" || method == "GET" {
            let moved = await recallPtzScene(camera.id, number: number)
            guard let scene = scene(camera.id, number) else {
                return "{\"ok\":false,\"reason\":\"장면을 읽지 못했습니다.\"}"
            }
            let ok = moved.contains("받았습니다") || moved.contains("불러왔습니다")
            let reason = moved.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"ok\":\(ok),\"reason\":\"\(reason)\",\"scene\":\(sceneJSON(scene, host: camera.host))}"
        } else {
            return "{\"ok\":false,\"reason\":\"그 명령은 받지 않습니다.\"}"
        }
        guard let scene = scene(camera.id, number) else {
            return "{\"ok\":false,\"reason\":\"장면을 읽지 못했습니다.\"}"
        }
        return "{\"ok\":true,\"scene\":\(sceneJSON(scene, host: camera.host))}"
    }

    private func ptzCamera(host: String?) -> PtzRecord? {
        if let host, !host.isEmpty {
            return profile.ptzCameras.first { $0.host == host }
        }
        return profile.ptzCameras.first
    }

    private func scene(_ cameraId: UUID, _ number: Int) -> PtzScene? {
        guard let camera = profile.ptzCameras.first(where: { $0.id == cameraId }) else { return nil }
        return PtzScene.ten(camera.scenes).first { $0.number == number }
    }

    private func write(_ scene: PtzScene, cameraId: UUID) {
        guard let index = profile.ptzCameras.firstIndex(where: { $0.id == cameraId }) else { return }
        var rows = PtzScene.ten(profile.ptzCameras[index].scenes)
        rows[scene.number - 1] = scene
        profile.ptzCameras[index].scenes = rows
    }

    private func sceneJSON(_ scene: PtzScene, host: String) -> String {
        let name = scene.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"id\":\"\(scene.stableId)\",\"number\":\(scene.number),\"name\":\"\(name)\",\"pan\":\(scene.pan),\"tilt\":\(scene.tilt),\"zoom\":\(scene.zoom),\"saved\":\(scene.saved),\"host\":\"\(host)\"}"
    }

    private func jsonString(_ body: String, key: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String else { return nil }
        return value
    }

    func deletePtz(_ id: UUID) {
        profile.ptzCameras.removeAll { $0.id == id }
        profile.stageSpots.removeAll { $0.deviceId == id }
        FieldSecret.save("", account: id.uuidString)
        note("PTZ 를 목록에서 뺐습니다.")
    }

    func deleteC3(_ id: UUID) {
        profile.c3Boards.removeAll { $0.id == id }
        note("C3 를 목록에서 뺐습니다.")
    }

    func addDevice(_ product: DeviceProduct) {
        if product.kind == .ronin {
            note("로닌은 따로 있는 기판이 아닙니다. C3 를 로닌 제어로 등록하세요.")
            return
        }
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
                break
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
                break
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

    /// 고른 로닌 보드(없으면 OLED→RMSID 순). 팬·틸트는 이 보드 WS로만 나갑니다.
    func roninBoard(_ boardId: UUID? = nil) -> C3BoardRecord? {
        if let boardId, let board = profile.c3Boards.first(where: { $0.id == boardId && $0.duty == .ronin }) {
            return board
        }
        return roninC3
    }

    /// RS2 줌(다이얼). speed +줌인 / -줌아웃 / 0멈춤. SC 보드는 자리만(거부 안내).
    func zoomRonin(speed: Int, boardId: UUID? = nil, quiet: Bool = false) async {
        guard let board = roninBoard(boardId) else {
            noteOffline("줌은 로닌용 OLED C3(RS2) 가 블루투스로 보냅니다. 보드 자리를 먼저 맞추세요.")
            return
        }
        if board.boardSlot == .rmsid {
            if !quiet {
                note("SC 줌은 아직 없습니다. 자리만 두었고, 지금은 RS2 줌만 씁니다.")
            }
            return
        }
        guard board.link.shoots else {
            noteOffline("\(board.listTitle) 은 USB 점검입니다. 줌을 보내지 않았습니다.")
            return
        }
        if !(await c3Socket(for: board).ensureOnline(board)) {
            if !quiet { note("\(board.listTitle) 에 붙지 못했습니다. \(board.socketHost):82") }
            return
        }
        let payload: [String: Any] = ["op": "ronin", "action": "zoom", "speed": speed]
        let result = await c3Socket(for: board).command(payload, timeout: quiet ? 1.5 : 4)
        if quiet && result.ack { return }
        note(result.sent ? result.reason : "\(board.listTitle) 에 줌을 보내지 않았습니다. \(result.reason)")
    }

    /// 화면의 팬·틸트입니다. 오프라인이면 붙인 뒤 바로 명령을 보냅니다. 「지금 연결」을 다시 누르지 않습니다.
    /// - pan: 좌우(팬). 예전 인자 이름 yaw 는 호환용이며 팬으로 보냅니다.
    /// - roll: 요(롤 모터). 팬과 다릅니다.
    func nudgeRonin(yaw: Double, pitch: Double, quiet: Bool = false, home: Bool = false, boardId: UUID? = nil, roll: Double = 0) async {
        guard let board = roninBoard(boardId) else {
            noteOffline("짐벌은 로닌용 OLED/RMSID C3 가 블루투스로 움직입니다. 보드 자리를 먼저 맞추세요.")
            return
        }
        guard board.link.shoots else {
            noteOffline("\(board.listTitle) 은 USB 점검입니다. 팬과 틸트를 보내지 않았습니다.")
            return
        }
        if !(await c3Socket(for: board).ensureOnline(board)) {
            if !quiet { note("\(board.listTitle) 에 붙지 못했습니다. \(board.socketHost):82") }
            return
        }
        var payload: [String: Any] = ["op": "ronin", "pan": yaw, "yaw": yaw, "pitch": pitch]
        if roll != 0 { payload["roll"] = roll }
        if home { payload["home"] = true }
        // 연속 팬·틸트는 짧은 대기(fw 1.0.58: DUML notify ≤280ms). 큐가 쌓이지 않게 합니다.
        let result = await c3Socket(for: board).command(payload, timeout: home ? 4 : (quiet ? 0.7 : 2))
        if result.ack, !c3Socket(for: board).pairedName.isEmpty {
            rememberGimbalName(board.id, c3Socket(for: board).pairedName)
        }
        if quiet && result.ack { return }
        if result.ack {
            if home {
                note("\(board.listTitle) 이 로닌 제자리를 블루투스로 보냈다고 답했습니다.")
            } else if roll != 0 && yaw == 0 && pitch == 0 {
                note("\(board.listTitle) 이 요 \(Int(roll))° 를 블루투스로 받았다고 답했습니다.")
            } else {
                note("\(board.listTitle) 이 팬 \(Int(yaw))°, 틸트 \(Int(pitch))° 를 블루투스로 받았다고 답했습니다.")
            }
        } else {
            // quiet 여도 「붙은 로닌 없음」은 무조건 알립니다. 조용한 실패가 무반응처럼 보였습니다.
            let hard = result.reason.contains("붙은 로닌") || result.reason.contains("붙지 못") || !result.sent
            if !quiet || hard {
                note(result.sent ? result.reason : "\(board.listTitle) 에 팬과 틸트를 보내지 않았습니다. \(result.reason)")
            }
        }
    }

    /// 요(롤 모터)만 보냅니다. 팬·틸트와 다른 축입니다.
    func nudgeRoninYaw(roll: Double, boardId: UUID? = nil, quiet: Bool = false) async {
        guard let board = roninBoard(boardId) else {
            noteOffline("요는 로닌용 C3 가 블루투스로 보냅니다. 보드 자리를 먼저 맞추세요.")
            return
        }
        guard board.link.shoots else {
            noteOffline("\(board.listTitle) 은 USB 점검입니다. 요를 보내지 않았습니다.")
            return
        }
        if !(await c3Socket(for: board).ensureOnline(board)) {
            if !quiet { note("\(board.listTitle) 에 붙지 못했습니다. \(board.socketHost):82") }
            return
        }
        let payload: [String: Any] = ["op": "ronin", "action": "yaw", "roll": roll, "yaw": roll]
        let result = await c3Socket(for: board).command(payload, timeout: quiet ? 1.5 : 4)
        if quiet && result.ack { return }
        note(result.sent ? result.reason : "\(board.listTitle) 에 요를 보내지 않았습니다. \(result.reason)")
    }

    /// C3 가 주변 로닌 블루투스 이름을 읽습니다.
    func scanRoninGimbals(_ boardId: UUID? = nil) async {
        guard let board = roninBoard(boardId) else {
            noteOffline("로닌용 OLED/RMSID C3 를 먼저 등록하세요.")
            return
        }
        if !(await c3Socket(for: board).ensureOnline(board)) {
            note("\(board.listTitle) 에 붙지 못했습니다. \(board.socketHost):82")
            return
        }
        let result = await c3Socket(for: board).command(["op": "scan"], timeout: 10)
        note(result.sent ? result.reason : "로닌 스캔을 보내지 못했습니다. \(result.reason)")
    }

    /// 고른 로닌 이름으로 C3 블루투스를 붙입니다.
    func pairRoninGimbal(name: String, id: String = "", boardId: UUID? = nil) async {
        guard let board = roninBoard(boardId) else {
            noteOffline("로닌용 OLED/RMSID C3 를 먼저 등록하세요.")
            return
        }
        if !(await c3Socket(for: board).ensureOnline(board)) {
            note("\(board.listTitle) 에 붙지 못했습니다. \(board.socketHost):82")
            return
        }
        var payload: [String: Any] = ["op": "pair", "name": name]
        if !id.isEmpty { payload["id"] = id }
        let result = await c3Socket(for: board).command(payload, timeout: 15)
        if result.ack {
            rememberGimbalName(board.id, c3Socket(for: board).pairedName.isEmpty ? name : c3Socket(for: board).pairedName)
        }
        note(result.sent ? result.reason : "로닌 붙이기를 보내지 못했습니다. \(result.reason)")
    }

    func rememberGimbalName(_ id: UUID, _ name: String) {
        guard !name.isEmpty, let index = profile.c3Boards.firstIndex(where: { $0.id == id }) else { return }
        if profile.c3Boards[index].gimbalName != name {
            profile.c3Boards[index].gimbalName = name
        }
    }

    /// 휠이 가리키는 각도로 옮깁니다. 손을 떼도 그 각도에 남고, 중앙으로 되돌리지 않습니다.
    func roninPlace(_ device: DeviceRecord, yaw: Double, pitch: Double) async {
        if profile.practice { return }
        _ = device
        await nudgeRonin(yaw: yaw, pitch: pitch)
    }

    /// 오른쪽 휠의 위아래입니다. 성공 기록은 남기지 않습니다. 좌우는 아직 보내지 않습니다.
    func roninZoom(_ device: DeviceRecord, path: String) async {
        if profile.practice { return }
        _ = (device, path)
    }

    /// 스틱을 누르고 있는 동안 팬·틸트 속도를 다시 보냅니다. 성공 기록은 남기지 않습니다.
    func roninSpeed(_ device: DeviceRecord, yaw: Double, pitch: Double) async {
        if profile.practice { return }
        _ = (device, yaw, pitch)
    }

    /// 휠을 누르는 동안만 보냅니다. 성공 기록은 남기지 않아 로그가 넘치지 않습니다.
    func roninHold(_ device: DeviceRecord, path: String?) async {
        if profile.practice { return }
        _ = (device, path)
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
        _ = (device, query)
        if let board = roninC3 {
            noteOffline("\(board.name) 은 로닌만 담당합니다. 이 C3 연결이 없어 \(path) 를 보내지 않았습니다.")
            return
        }
        noteOffline("짐벌은 로닌 제어로 고른 C3 가 움직입니다. 그 C3 를 먼저 등록하세요.")
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
        guard boardSocket.state == .online else {
            noteOffline("올리멕스가 오프라인입니다. \(label) 녹화를 보내지 않았습니다.")
            return
        }
        let ids = group == "all" ? boardSocket.cameras.map(\.id) : (profile.cameraGroups[group] ?? [])
        if ids.isEmpty {
            note(group == "all" ? "스캔된 카메라가 없습니다. 모두 녹화를 보내지 않았습니다." : "\(label) 묶음이 비어 있습니다. 카메라 줄의 \(label) 을 먼저 누르세요.")
            return
        }
        let ok = await boardSocket.send([
            "op": "record",
            "group": group,
            "start": start,
            "ids": ids,
            "tally": start,
        ])
        if ok {
            note("\(label) \(start ? "녹화" : "정지") \(ids.count)대를 큐에 넣었습니다. 대별 빨간 테두리는 기판 BLE 답(tally.note)이 온 뒤에만 바뀝니다.")
        } else {
            noteOffline("기판이 오프라인입니다. \(label) \(start ? "녹화" : "정지")를 보내지 않았습니다.")
        }
    }

    func toggleCameraGroup(_ name: String, _ cameraId: String) {
        var list = profile.cameraGroups[name] ?? []
        if list.contains(cameraId) {
            list.removeAll { $0 == cameraId }
        } else {
            list.append(cameraId)
        }
        profile.cameraGroups[name] = list
        note("\(name) 묶음은 지금 \(list.count)대입니다.")
    }

    func cameraInGroup(_ name: String, _ cameraId: String) -> Bool {
        profile.cameraGroups[name]?.contains(cameraId) == true
    }

    /// 액션 카메라 한 대 녹화입니다. 소켓 쓰기가 아니라 기판 tally.note(BLE) 성공일 때만 true.
    @discardableResult
    func olimexCamera(_ camera: BoardCamera, start: Bool) async -> Bool {
        guard profile.olimexRegistered else {
            note("액션 카메라는 올리멕스 기판에 있습니다. 먼저 등록하세요.")
            return false
        }
        guard boardSocket.state == .online else {
            noteOffline("올리멕스가 오프라인입니다. \(camera.name) 녹화를 보내지 않았습니다.")
            return false
        }
        let result = await boardSocket.sendAwaitingTally([
            "op": "record-one",
            "id": camera.id,
            "name": camera.name,
            "kind": camera.kind,
            "ble": camera.ble.isEmpty ? BoardSocket.ble(for: camera.kind) : camera.ble,
            "start": start,
            "tally": start,
        ], matching: camera.name, timeout: 18)
        if !result.sent {
            noteOffline("올리멕스가 오프라인입니다. \(camera.name) 녹화를 보내지 않았습니다.")
            return false
        }
        if result.ok {
            note(result.note.isEmpty
                 ? "\(camera.name) \(start ? "녹화" : "정지") · 기판이 BLE 상태 0으로 받았습니다."
                 : result.note)
            return true
        }
        note(result.note.isEmpty
             ? "\(camera.name) \(start ? "녹화" : "정지") · 기판 BLE 답이 없어 녹화로 두지 않습니다."
             : result.note)
        return false
    }

    /// 조명 C3 가 주변 울란지 이름을 읽습니다.
    func scanUlanziLights(_ id: UUID) async {
        guard let board = profile.c3Boards.first(where: { $0.id == id && $0.duty == .light }) else {
            note("조명 담당 S3 를 찾지 못했습니다.")
            return
        }
        if !(await c3Socket(for: board).ensureOnline(board)) {
            note("\(board.listTitle) 에 붙지 못했습니다. \(board.socketHost):82")
            return
        }
        let result = await c3Socket(for: board).command(["op": "light", "action": "scan"], timeout: 12)
        note(result.sent ? result.reason : "울란지 스캔을 보내지 못했습니다. \(result.reason)")
    }

    /// 고른 울란지 이름으로 C3 블루투스를 붙입니다.
    func pairUlanziLight(_ id: UUID, name: String, id lightId: String = "") async {
        guard let board = profile.c3Boards.first(where: { $0.id == id && $0.duty == .light }) else {
            note("조명 담당 S3 를 찾지 못했습니다.")
            return
        }
        if !(await c3Socket(for: board).ensureOnline(board)) {
            note("\(board.listTitle) 에 붙지 못했습니다. \(board.socketHost):82")
            return
        }
        var payload: [String: Any] = ["op": "light", "action": "pair", "name": name]
        if !lightId.isEmpty { payload["id"] = lightId }
        let result = await c3Socket(for: board).command(payload, timeout: 18)
        if result.ack {
            rememberGimbalName(board.id, c3Socket(for: board).pairedName.isEmpty ? name : c3Socket(for: board).pairedName)
        }
        note(result.sent ? result.reason : "울란지 붙이기를 보내지 못했습니다. \(result.reason)")
    }

    /// 울란지 한 대(칸 index). 묶음이 아닙니다. 오프라인이면 붙인 뒤 바로 보냅니다.
    func setLight(_ id: UUID, index: Int, brightness: Int, kelvin: Int, on: Bool, quiet: Bool = false) async {
        guard let board = profile.c3Boards.first(where: { $0.id == id && $0.duty == .light }) else {
            if !quiet { note("조명 담당 S3 를 찾지 못했습니다.") }
            return
        }
        guard board.link.shoots else {
            if !quiet { note("\(board.listTitle) 은 USB 점검입니다. 조명을 보내지 않았습니다.") }
            return
        }
        if !(await c3Socket(for: board).ensureOnline(board)) {
            if !quiet { note("\(board.listTitle) 에 붙지 못했습니다. \(board.socketHost):82") }
            return
        }
        let payload: [String: Any] = [
            "op": "light",
            "index": index,
            "brightness": brightness,
            "kelvin": kelvin,
            "on": on,
        ]
        // 슬라이더(quiet)는 ack 대기 없이 바로 보냅니다. 펌웨어가 최신값만 남깁니다.
        if quiet {
            _ = await c3Socket(for: board).fire(payload)
            return
        }
        let result = await c3Socket(for: board).command(payload, timeout: 4)
        if result.ack {
            note(result.reason.isEmpty
                 ? "\(board.listTitle) 칸\(index) 밝기 \(brightness), \(kelvin)K 를 받았다고 답했습니다."
                 : result.reason)
        } else {
            note(result.reason)
        }
    }

    /// 저장된 울란지 모두(선택). 개별 UI가 기본이고, 이 버튼만 묶음입니다.
    func setAllLights(_ id: UUID, brightness: Int, kelvin: Int, on: Bool) async {
        guard let board = profile.c3Boards.first(where: { $0.id == id && $0.duty == .light }) else {
            note("조명 담당 S3 를 찾지 못했습니다.")
            return
        }
        if !(await c3Socket(for: board).ensureOnline(board)) {
            note("\(board.listTitle) 에 붙지 못했습니다. \(board.socketHost):82")
            return
        }
        let result = await c3Socket(for: board).command([
            "op": "light",
            "action": "all",
            "brightness": brightness,
            "kelvin": kelvin,
            "on": on,
        ], timeout: 18)
        note(result.sent ? result.reason : "묶음 조명을 보내지 못했습니다. \(result.reason)")
    }

    func sendCameraSetting(id: String, name: String, kind: String, ble: String, setting: String, value: String) async {
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
            "name": name,
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
        boardSocket.disconnect()
        if lane == .usb {
            note("올리멕스 USB는 펌웨어와 시리얼 점검입니다. 촬영 명령은 나가지 않습니다.")
        } else {
            note("올리멕스 연결을 \(lane.title) 로 바꿨습니다.")
            reconnectOlimex(quiet: true)
        }
    }

    /// 고른 길의 주소로 바로 웹소켓을 엽니다. 다른 길의 주소를 섞지 않습니다.
    func reconnectOlimex(quiet: Bool = false) {
        guard profile.olimexRegistered else {
            if !quiet { note("먼저 올리멕스 ESP32-PoE 를 등록하세요.") }
            return
        }
        switch boardSocket.lane {
        case .usb:
            if !quiet { note("올리멕스 USB는 펌웨어와 시리얼 점검입니다. 촬영 명령은 나가지 않습니다.") }
            return
        case .poe:
            boardSocket.reportedHost = "192.168.10.150"
            boardSocket.reportedPort = 81
        case .ap:
            boardSocket.reportedHost = "192.168.4.1"
            boardSocket.reportedPort = 81
        case .lan:
            var saved = profile.olimexLanHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if saved.isEmpty || saved == "192.168.10.204" { saved = "192.168.10.151" }
            boardSocket.reportedHost = saved.hasPrefix("192.168.10.") ? saved : "192.168.10.151"
            boardSocket.reportedPort = 81
        }
        boardSocket.connect()
    }

    func reconnectC3(_ id: UUID? = nil) {
        let board = profile.c3Boards.first { $0.id == id } ?? profile.c3Boards.first { $0.duty == .ronin && $0.link.shoots } ?? profile.c3Boards.first { $0.link.shoots }
        guard let board else { return }
        guard board.link.shoots else { return }
        let host = board.socketHost
        if let slot = board.boardSlot, boardLanAlive[slot.rawValue] == false, board.link == .lan {
            note("\(board.listTitle) \(host):82 가 망에서 무응답이었습니다. 연결을 다시 시도합니다. 전원·와이파이·펌(맥미니)을 확인하세요.")
        } else {
            note("\(board.listTitle) \(host):82 에 붙습니다.")
        }
        c3Bag.socket(for: board.id).connect(board)
    }

    /// 등록된 C3 전부를 동시에 붙입니다(하나 때문에 다른 쪽을 끊지 않음).
    func reconnectAllC3() {
        let boards = profile.c3Boards.filter { $0.link.shoots }
        guard !boards.isEmpty else { return }
        note("C3 \(boards.count)대를 동시에 붙입니다.")
        c3Bag.connectAll(boards)
    }

    /// 로닌·조명 탭에서 망 무응답일 때 다시 찍습니다.
    func recheckC3Lan() {
        Task { await refreshBoardLanAlive() }
    }

    func chooseC3Mode(_ id: UUID, _ lane: BoardLane) {
        guard let index = profile.c3Boards.firstIndex(where: { $0.id == id }) else { return }
        let stored: BoardLane = lane == .poe ? .lan : lane
        profile.c3Boards[index].linkMode = stored.rawValue
        c3Bag.disconnect(id)
        note("\(profile.c3Boards[index].name) 연결을 \(stored.title) 로 바꿨습니다. 명령을 보내면 그때 붙습니다.")
    }

    /// 고른 카메라를 온에어로 표시합니다. 앞 화면 글자는 기판 응답을 받은 뒤에만 적습니다.
    func tally(_ camera: BoardCamera, on: Bool) async {
        if profile.practice {
            note("연습: \(camera.name) 탈리를 보내지 않았습니다.")
            return
        }
        guard profile.olimexRegistered, boardSocket.lane.shoots else {
            noteOffline("탈리는 올리멕스가 같은 망, PoE, 핫스팟으로 붙어 있을 때만 보냅니다.")
            return
        }
        let ok = await boardSocket.send([
            "op": "tally",
            "id": camera.id,
            "name": camera.name,
            "kind": camera.kind,
            "ble": camera.ble,
            "on": on,
        ])
        if ok {
            note("\(camera.name) 탈리 \(on ? "켜기" : "끄기")를 보냈습니다. 앞 화면 글자는 랩스에서만 되고, 기판이 결과를 주면 그 글을 따릅니다.")
        } else {
            noteOffline("올리멕스가 오프라인입니다. 탈리를 보내지 않았습니다.")
        }
    }

    func setHomeAim(_ id: UUID, yaw: Double, pitch: Double) {
        moveStage(deviceId: id, homeYaw: yaw, homePitch: pitch)
        note("기본 시선을 팬 \(Int(yaw))°, 틸트 \(Int(pitch))° 에 고정했습니다. 이후 시선은 이 방향에서의 절대각입니다.")
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

    /// 지금 보드·무대·PTZ·카메라·로닌 설정을 장소 이름으로 저장합니다.
    func saveVenue(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            note("장소 이름을 넣으세요.")
            return
        }
        if let index = venues.places.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            venues.places[index].profile = profile
            venues.places[index].updatedAt = Date()
            venues.places[index].name = name
            venues.currentId = venues.places[index].id
            note("장소 \(name) 설정을 덮어 저장했습니다.")
            return
        }
        let place = VenuePlace(id: UUID(), name: name, updatedAt: Date(), profile: profile)
        venues.places.insert(place, at: 0)
        venues.currentId = place.id
        note("장소 \(name) 을 새로 저장했습니다.")
    }

    /// 고른 장소의 현재 설정을 같은 이름으로 다시 저장합니다.
    func saveCurrentVenue() {
        guard let id = venues.currentId,
              let index = venues.places.firstIndex(where: { $0.id == id }) else {
            note("먼저 장소 이름으로 저장하세요.")
            return
        }
        venues.places[index].profile = profile
        venues.places[index].updatedAt = Date()
        note("장소 \(venues.places[index].name) 을 다시 저장했습니다.")
    }

    /// 목록에서 장소를 골라 불러옵니다. 보드 소켓은 다시 엽니다.
    func loadVenue(_ id: UUID) {
        guard let place = venues.places.first(where: { $0.id == id }) else {
            note("그 장소를 찾지 못했습니다.")
            return
        }
        boardSocket.disconnect(quiet: true)
        c3Bag.disconnectAll()
        venues.currentId = place.id
        profile = place.profile
        let lane = BoardLane(stored: profile.boardLane)
        boardSocket.lane = lane
        dropSeparateRoninBoards()
        reconnectOlimex(quiet: true)
        reconnectC3()
        note("장소 \(place.name) 을 불러왔습니다. 올리멕스 \(profile.olimexRegistered ? "등록" : "없음"), C3 \(profile.c3Boards.count)대, PTZ \(profile.ptzCameras.count)대.")
    }

    func renameVenue(_ id: UUID, _ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = venues.places.firstIndex(where: { $0.id == id }) else { return }
        venues.places[index].name = name
        note("장소 이름을 \(name) 으로 바꿨습니다.")
    }

    func deleteVenue(_ id: UUID) {
        guard let index = venues.places.firstIndex(where: { $0.id == id }) else { return }
        let name = venues.places[index].name
        venues.places.remove(at: index)
        if venues.currentId == id { venues.currentId = nil }
        note("장소 \(name) 을 목록에서 지웠습니다.")
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
        Task { await keepFieldLinks() }
        await watchBoards()
    }

    /// 등록된 올리멕스와 C3 가 오래 오프라인이면 다시 엽니다. 소켓 안의 softDrop 재연결이 우선입니다.
    private func keepFieldLinks() async {
        while !Task.isCancelled {
            if profile.olimexRegistered && boardSocket.state == .offline && boardSocket.lane.shoots {
                reconnectOlimex(quiet: true)
            }
            // 보드마다 독립 소켓. 오프라인인 것만 다시 붙입니다(다른 보드를 끊지 않음).
            for board in profile.c3Boards where board.link.shoots {
                if c3Bag.state(for: board.id) == .offline {
                    reconnectC3(board.id)
                }
            }
            try? await Task.sleep(nanoseconds: 12_000_000_000)
        }
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

    /// 예전 프로필의 로닌 기판은 연결 대상이 아닙니다. 목록에서 빼고 주소를 다시 쓰지 않습니다.
    private func dropSeparateRoninBoards() {
        let gone = Set(profile.devices.filter { $0.kind == .ronin }.map(\.id))
        guard !gone.isEmpty else { return }
        profile.devices.removeAll { gone.contains($0.id) }
        profile.groupIds.removeAll { gone.contains($0) }
        profile.stageSpots.removeAll { gone.contains($0.deviceId) }
        profile.shootGroups = profile.shootGroups.mapValues { $0.filter { !gone.contains($0) } }
        note("로닌은 따로 있는 기판이 아닙니다. 목록에서 뺐습니다. 짐벌은 로닌 제어로 고른 C3 가 맡습니다.")
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

    private func saveVenues() {
        if let data = try? JSONEncoder().encode(venues) {
            UserDefaults.standard.set(data, forKey: VenueBook.storageKey)
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
