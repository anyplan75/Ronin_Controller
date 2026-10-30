import Foundation

// 장치에 저장하는 프로필입니다. 주소는 여기 들어 있고, 비밀번호는 넣지 않습니다.
// 저장 열쇠 앞에 [로닌컨트롤]_ 을 붙여 다른 프로젝트와 섞이지 않게 합니다.

enum DeviceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ronin
    case gopro
    /// 오즈모 액션 5 프로. 앱은 이미 둔 C3 중계 기판으로만 붙습니다. 고프로가 아닙니다.
    case goproAction5
    /// 고프로와 액션 5 프로가 붙는 ESP32-C3 입니다. 앱은 기판 맥 주소로 바로 연결합니다.
    case goproBridge
    case osmoAction
    case osmoNoAPI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ronin: return "로닌 기판 · CAN"
        case .gopro: return "고프로 · 와이파이"
        case .goproAction5: return "오즈모 액션 5 프로 · 블루투스"
        case .goproBridge: return "C3 중계 · 고프로 · 액션 5 프로"
        case .osmoAction: return "오즈모 액션 · 블루투스"
        case .osmoNoAPI: return "제어 API 없음"
        }
    }

    var usesHTTP: Bool { self == .ronin || self == .goproBridge || isGoProFamily }

    /// 고프로 HERO는 카메라 와이파이입니다. 오즈모 액션 5 프로는 여기 넣지 않습니다.
    var isDirectGoPro: Bool { self == .gopro }

    /// 둘 다 Open GoPro HTTP 경로를 쓰지만, 붙는 장치가 다릅니다.
    var isGoProFamily: Bool { self == .gopro || self == .goproAction5 }

    /// 고프로 HERO 와이파이만 미리보기 스트림이 있습니다.
    /// 오즈모 액션 5 프로의 C3 중계, 다른 오즈모, 로닌 기판은 그림 미리보기를 주지 않습니다.
    var supportsLiveView: Bool { self == .gopro }

    var defaultPort: Int {
        switch self {
        case .ronin, .goproAction5, .goproBridge: return 80
        case .gopro: return 8080
        default: return 0
        }
    }
}

enum OsmoModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case action4
    case action5Pro
    case action6
    case osmo360
    case pocket
    case mobile
    case nano
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .action4: return "오즈모 액션 4"
        case .action5Pro: return "오즈모 액션 5 프로"
        case .action6: return "오즈모 액션 6"
        case .osmo360: return "오즈모 360"
        case .pocket: return "오즈모 포켓"
        case .mobile: return "오즈모 모바일"
        case .nano: return "오즈모 나노"
        case .unknown: return "아직 모름"
        }
    }

    var supportsRSDK: Bool {
        switch self {
        case .action4, .action5Pro, .action6, .osmo360: return true
        default: return false
        }
    }

    /// 공식 모드 전환 예시와 같은 바이트 순서입니다.
    /// 액션 4 예시는 0xFF330000 (바이트 00 00 33 FF) 입니다.
    /// 녹화 예제 코드만 0x33FF0000 으로 적혀 있어, 그 값은 쓰지 않습니다.
    var commandDeviceId: UInt32? {
        switch self {
        case .action4: return 0xFF330000
        case .action5Pro: return 0xFF440000
        case .action6: return 0xFF550000
        case .osmo360: return 0xFF660000
        default: return nil
        }
    }

    /// 폰 블루투스의 오즈모 액션입니다. 액션 5 프로는 C3 중계 줄이라 여기 넣지 않습니다.
    static let actionModels: [OsmoModel] = [.action4, .action6]

    static func choices(for kind: DeviceKind, model: OsmoModel) -> [OsmoModel] {
        switch kind {
        case .osmoAction:
            if model == .osmo360 { return [.osmo360] }
            if model == .action5Pro { return [.action5Pro] + actionModels }
            return actionModels
        case .osmoNoAPI:
            return [.pocket, .mobile, .nano, .unknown]
        default:
            return []
        }
    }
}

/// 장치 추가 메뉴에 나오는 항목입니다. 제어 API가 없는 기종은 넣지 않습니다.
enum DeviceProduct: String, CaseIterable, Identifiable, Sendable {
    case ronin
    case goproWifi
    case goproBridge
    case action5Bluetooth
    case osmoActionBluetooth
    case osmo360Bluetooth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ronin: return "로닌 기판 · CAN"
        case .goproWifi: return "고프로 · 와이파이"
        case .goproBridge: return "C3 중계 · 고프로 · 액션 5 프로"
        case .action5Bluetooth: return "오즈모 액션 5 프로 · 블루투스"
        case .osmoActionBluetooth: return "오즈모 액션 · 블루투스"
        case .osmo360Bluetooth: return "오즈모 360 · 블루투스"
        }
    }

    var kind: DeviceKind {
        switch self {
        case .ronin: return .ronin
        case .goproWifi: return .gopro
        case .goproBridge: return .goproBridge
        case .action5Bluetooth: return .goproAction5
        case .osmoActionBluetooth, .osmo360Bluetooth: return .osmoAction
        }
    }

    var osmoModel: OsmoModel {
        switch self {
        case .osmo360Bluetooth: return .osmo360
        case .osmoActionBluetooth: return .action4
        default: return .unknown
        }
    }

    /// 새로 넣는 장치만 여기 있습니다. 고프로 와이파이와 단독 액션 5 프로는 더 이상 만들지 않습니다.
    static let addMenu: [DeviceProduct] = [.ronin, .goproBridge, .osmoActionBluetooth, .osmo360Bluetooth]

    static func matching(_ device: DeviceRecord) -> DeviceProduct? {
        switch device.kind {
        case .ronin: return .ronin
        case .gopro: return .goproWifi
        case .goproBridge: return .goproBridge
        case .goproAction5: return .action5Bluetooth
        case .osmoAction: return device.osmoModel == .osmo360 ? .osmo360Bluetooth : .osmoActionBluetooth
        case .osmoNoAPI: return nil
        }
    }
}

/// 한 기판에 붙는 카메라입니다. 고프로 또는 액션 5 프로이고, 최대 4칸입니다.
enum BridgeCameraRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case gopro
    case action5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gopro: return "고프로"
        case .action5: return "액션 5 프로"
        }
    }
}

struct BridgeCameraSlot: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var role: BridgeCameraRole
    var mac: String

    init(id: UUID = UUID(), role: BridgeCameraRole = .gopro, mac: String = "") {
        self.id = id
        self.role = role
        self.mac = mac
    }

    /// 한 기판은 4대를 넘기지 않습니다. 비어 있는 칸을 다시 만들지 않습니다.
    static func capped(_ slots: [BridgeCameraSlot]) -> [BridgeCameraSlot] {
        Array(slots.prefix(4))
    }

    enum CodingKeys: String, CodingKey {
        case id, slot, role, mac
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try box.decodeIfPresent(BridgeCameraRole.self, forKey: .role) ?? .gopro
        mac = try box.decodeIfPresent(String.self, forKey: .mac) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(id, forKey: .id)
        try box.encode(role, forKey: .role)
        try box.encode(mac, forKey: .mac)
    }
}

struct DeviceRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var kind: DeviceKind
    var osmoModel: OsmoModel
    var host: String
    var port: Int
    var bleIdentifier: String
    var enabled: Bool
    var pairedOnce: Bool
    /// C3 기판의 와이파이 맥 주소입니다. 다른 장치는 비워 둡니다.
    var boardMac: String
    /// 이 기판에 블루투스로 붙는 카메라입니다.
    var cameras: [BridgeCameraSlot]

    init(
        id: UUID,
        name: String,
        kind: DeviceKind,
        osmoModel: OsmoModel,
        host: String,
        port: Int,
        bleIdentifier: String,
        enabled: Bool,
        pairedOnce: Bool,
        boardMac: String = "",
        cameras: [BridgeCameraSlot] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.osmoModel = osmoModel
        self.host = host
        self.port = port
        self.bleIdentifier = bleIdentifier
        self.enabled = enabled
        self.pairedOnce = pairedOnce
        self.boardMac = boardMac
        self.cameras = kind == .goproBridge ? BridgeCameraSlot.capped(cameras) : cameras
    }

    /// 목록과 메뉴에 쓰는 이름입니다. 제품과 연결을 같이 적습니다.
    var linkLabel: String {
        switch kind {
        case .ronin: return "로닌 기판 · CAN"
        case .gopro: return "고프로 · 와이파이"
        case .goproAction5: return "오즈모 액션 5 프로 · 블루투스"
        case .goproBridge: return "C3 중계 · 고프로 · 액션 5 프로"
        case .osmoAction:
            return osmoModel == .osmo360 ? "오즈모 360 · 블루투스" : "오즈모 액션 · 블루투스"
        case .osmoNoAPI:
            return "제어 API 없음"
        }
    }

    var baseURLText: String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, port > 0 else { return "" }
        return "http://\(trimmed):\(port)"
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, osmoModel, host, port, bleIdentifier, enabled, pairedOnce, boardMac, cameras
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UUID.self, forKey: .id)
        name = try box.decode(String.self, forKey: .name)
        kind = try box.decode(DeviceKind.self, forKey: .kind)
        osmoModel = try box.decode(OsmoModel.self, forKey: .osmoModel)
        host = try box.decode(String.self, forKey: .host)
        port = try box.decode(Int.self, forKey: .port)
        bleIdentifier = try box.decode(String.self, forKey: .bleIdentifier)
        enabled = try box.decode(Bool.self, forKey: .enabled)
        pairedOnce = try box.decode(Bool.self, forKey: .pairedOnce)
        boardMac = try box.decodeIfPresent(String.self, forKey: .boardMac) ?? ""
        let stored = try box.decodeIfPresent([BridgeCameraSlot].self, forKey: .cameras) ?? []
        cameras = kind == .goproBridge ? BridgeCameraSlot.capped(stored) : stored
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(id, forKey: .id)
        try box.encode(name, forKey: .name)
        try box.encode(kind, forKey: .kind)
        try box.encode(osmoModel, forKey: .osmoModel)
        try box.encode(host, forKey: .host)
        try box.encode(port, forKey: .port)
        try box.encode(bleIdentifier, forKey: .bleIdentifier)
        try box.encode(enabled, forKey: .enabled)
        try box.encode(pairedOnce, forKey: .pairedOnce)
        try box.encode(boardMac, forKey: .boardMac)
        try box.encode(cameras, forKey: .cameras)
    }
}

struct GoProSettingChoice: Codable, Equatable, Identifiable, Sendable {
    var settingId: Int
    var option: Int
    var enabled: Bool
    var id: Int { settingId }
}

struct RoninLook: Codable, Equatable, Sendable {
    var shot: String
    var timeScale: Double
    var sendMove: Bool
    var yaw: Double
    var roll: Double
    var pitch: Double
    var seconds: Double
    var absolute: Bool
}

struct GoProLook: Codable, Equatable, Sendable {
    var settings: [GoProSettingChoice]
    var loadPresetId: Int?
    var digitalZoomPercent: Int?
}

struct OsmoLook: Codable, Equatable, Sendable {
    var mode: Int?
}

enum PresetKind: String, Codable, Sendable {
    case ronin
    case action
    case shared
}

struct ShootPreset: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var note: String
    var deviceIds: [UUID]
    var ronin: RoninLook
    var gopro: GoProLook
    var osmo: OsmoLook
    /// 저장 당시의 직접 연결 주소입니다. 중계 컴퓨터 없이 다시 붙을 때 씁니다.
    var connections: [DeviceRecord]
    /// 없으면 예전 함께 프리셋입니다. 로닌 기판 동작과는 따로 둡니다.
    var kind: PresetKind?
    /// 중계 기판의 카메라 칸입니다. 로닌 프리셋에는 없습니다.
    var cameraId: UUID?

    init(
        id: UUID,
        name: String,
        note: String,
        deviceIds: [UUID],
        ronin: RoninLook,
        gopro: GoProLook,
        osmo: OsmoLook,
        connections: [DeviceRecord],
        kind: PresetKind? = nil,
        cameraId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.note = note
        self.deviceIds = deviceIds
        self.ronin = ronin
        self.gopro = gopro
        self.osmo = osmo
        self.connections = connections
        self.kind = kind
        self.cameraId = cameraId
    }
}

/// 무대 위 한 장치의 자리입니다. 단위는 미터, 방향은 도입니다.
/// 예전 프로필에는 이 목록이 없어도 읽힙니다.
struct StageSpot: Codable, Equatable, Sendable, Identifiable {
    var id: UUID { deviceId }
    var deviceId: UUID
    var x: Double
    var y: Double
    var z: Double
    /// 방에 둔 제자리 방향입니다. 도는 기준은 이 각도입니다.
    var aimYaw: Double
    /// 짐벌에 보내는 제자리 요·피치입니다. 없으면 0입니다.
    var homeYaw: Double
    var homePitch: Double

    init(deviceId: UUID, x: Double, y: Double, z: Double, aimYaw: Double, homeYaw: Double = 0, homePitch: Double = 0) {
        self.deviceId = deviceId
        self.x = x
        self.y = y
        self.z = z
        self.aimYaw = aimYaw
        self.homeYaw = homeYaw
        self.homePitch = homePitch
    }

    enum CodingKeys: String, CodingKey {
        case deviceId, x, y, z, aimYaw, homeYaw, homePitch
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try box.decode(UUID.self, forKey: .deviceId)
        x = try box.decode(Double.self, forKey: .x)
        y = try box.decode(Double.self, forKey: .y)
        z = try box.decode(Double.self, forKey: .z)
        aimYaw = try box.decode(Double.self, forKey: .aimYaw)
        homeYaw = try box.decodeIfPresent(Double.self, forKey: .homeYaw) ?? 0
        homePitch = try box.decodeIfPresent(Double.self, forKey: .homePitch) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(deviceId, forKey: .deviceId)
        try box.encode(x, forKey: .x)
        try box.encode(y, forKey: .y)
        try box.encode(z, forKey: .z)
        try box.encode(aimYaw, forKey: .aimYaw)
        try box.encode(homeYaw, forKey: .homeYaw)
        try box.encode(homePitch, forKey: .homePitch)
    }
}

struct StudioProfile: Codable, Equatable, Sendable {
    static let maxDevices = 8
    static let storageKey = "[로닌컨트롤]_profile"

    var version: Int
    var devices: [DeviceRecord]
    var presets: [ShootPreset]
    var groupIds: [UUID]
    var leadMs: Int
    var practice: Bool
    var senderId: UInt32
    var senderMac: [UInt8]
    var stageSpots: [StageSpot]

    init(
        version: Int,
        devices: [DeviceRecord],
        presets: [ShootPreset],
        groupIds: [UUID],
        leadMs: Int,
        practice: Bool,
        senderId: UInt32,
        senderMac: [UInt8],
        stageSpots: [StageSpot] = []
    ) {
        self.version = version
        self.devices = devices
        self.presets = presets
        self.groupIds = groupIds
        self.leadMs = leadMs
        self.practice = practice
        self.senderId = senderId
        self.senderMac = senderMac
        self.stageSpots = stageSpots
    }

    enum CodingKeys: String, CodingKey {
        case version, devices, presets, groupIds, leadMs, practice, senderId, senderMac, stageSpots
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        version = try box.decode(Int.self, forKey: .version)
        devices = try box.decode([DeviceRecord].self, forKey: .devices)
        presets = try box.decode([ShootPreset].self, forKey: .presets)
        groupIds = try box.decode([UUID].self, forKey: .groupIds)
        leadMs = try box.decode(Int.self, forKey: .leadMs)
        practice = try box.decode(Bool.self, forKey: .practice)
        senderId = try box.decode(UInt32.self, forKey: .senderId)
        senderMac = try box.decode([UInt8].self, forKey: .senderMac)
        stageSpots = try box.decodeIfPresent([StageSpot].self, forKey: .stageSpots) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(version, forKey: .version)
        try box.encode(devices, forKey: .devices)
        try box.encode(presets, forKey: .presets)
        try box.encode(groupIds, forKey: .groupIds)
        try box.encode(leadMs, forKey: .leadMs)
        try box.encode(practice, forKey: .practice)
        try box.encode(senderId, forKey: .senderId)
        try box.encode(senderMac, forKey: .senderMac)
        try box.encode(stageSpots, forKey: .stageSpots)
    }

    static func makeNew() -> StudioProfile {
        StudioProfile(
            version: 1,
            devices: [],
            presets: [],
            groupIds: [],
            leadMs: 300,
            practice: false,
            senderId: UInt32.random(in: 1...0x7FFF_FFFF),
            senderMac: (0..<6).map { _ in UInt8.random(in: 0...255) }
        )
    }

    func targets(for preset: ShootPreset) -> [DeviceRecord] {
        let enabled = devices.filter(\.enabled)
        if preset.deviceIds.isEmpty {
            return enabled
        }
        return enabled.filter { preset.deviceIds.contains($0.id) }
    }
}

enum RoninCatalog {
    static let shots = [
        "front", "wide", "tight", "verse", "chorus", "hero", "high", "hands",
        "reveal", "drop", "profile-l", "profile-r", "qtr-l", "qtr-r",
        "whip-l", "whip-r", "drift-l", "drift-r", "dutch-l", "dutch-r",
        "level", "sway", "push", "pull", "crash", "snap-wide", "snap-tight",
    ]

    static func title(_ shot: String) -> String {
        let names = [
            "front": "정면", "wide": "와이드", "tight": "타이트", "verse": "벌스",
            "chorus": "코러스", "hero": "히어로", "high": "하이", "hands": "손",
            "reveal": "리빌", "drop": "드롭", "profile-l": "옆 왼쪽", "profile-r": "옆 오른쪽",
            "qtr-l": "3/4 왼쪽", "qtr-r": "3/4 오른쪽", "whip-l": "휩 왼쪽", "whip-r": "휩 오른쪽",
            "drift-l": "드리프트 왼쪽", "drift-r": "드리프트 오른쪽",
            "dutch-l": "더치 왼쪽", "dutch-r": "더치 오른쪽", "level": "수평",
            "sway": "스웨이", "push": "푸시", "pull": "풀", "crash": "크래시",
            "snap-wide": "줌 와이드", "snap-tight": "줌 타이트",
        ]
        return names[shot] ?? shot
    }
}

enum OsmoCatalog {
    static let actionModes: [(Int, String)] = [
        (0x00, "슬로 모션"),
        (0x01, "비디오"),
        (0x02, "타임랩스"),
        (0x05, "사진"),
        (0x0A, "하이퍼랩스"),
        (0x1A, "라이브 스트림"),
        (0x23, "UVC 라이브"),
        (0x28, "슈퍼나이트"),
        (0x34, "피사체 추적"),
    ]

    static let osmo360Modes: [(Int, String)] = [
        (0x38, "360 영상"),
        (0x3A, "360 하이퍼랩스"),
        (0x3C, "셀피"),
        (0x3F, "360 사진"),
        (0x41, "부스트 영상"),
        (0x43, "보텍스"),
        (0x44, "360 슈퍼나이트"),
        (0x4A, "한 렌즈 슈퍼나이트"),
    ]

    static func writableModes(for model: OsmoModel) -> [(Int, String)] {
        model == .osmo360 ? actionModes + osmo360Modes : actionModes
    }

    static func resolutionName(_ value: Int) -> String {
        switch value {
        case 10: return "1080p"
        case 16: return "4K 16:9"
        case 45: return "2.7K 16:9"
        case 66: return "1080p 9:16"
        case 67: return "2.7K 9:16"
        case 95: return "2.7K 4:3"
        case 103: return "4K 4:3"
        case 109: return "4K 9:16"
        case 4: return "사진 L 또는 울트라 와이드"
        case 3: return "사진 M 또는 와이드"
        case 2: return "사진 스탠다드 12MP (360)"
        default: return "표에 없는 번호 \(value)"
        }
    }

    static func fpsName(_ value: Int) -> String {
        switch value {
        case 1: return "24"
        case 2: return "25"
        case 3: return "30"
        case 4: return "48"
        case 5: return "50"
        case 6: return "60"
        case 7: return "120"
        case 8: return "240"
        case 10: return "100"
        case 19: return "200"
        default: return "표에 없는 번호 \(value)"
        }
    }

    static func eisName(_ value: Int) -> String {
        switch value {
        case 0: return "끄기"
        case 1: return "RS"
        case 2: return "HS"
        case 3: return "RS+"
        case 4: return "HB"
        default: return "표에 없는 번호 \(value)"
        }
    }

    static func statusName(_ value: Int) -> String {
        switch value {
        case 0: return "화면 꺼짐"
        case 1: return "라이브 (녹화 전 포함)"
        case 2: return "재생"
        case 3: return "촬영 중"
        case 5: return "프리 레코드"
        default: return "표에 없는 번호 \(value)"
        }
    }

    static func modeName(_ value: Int) -> String {
        if let found = (actionModes + osmo360Modes).first(where: { $0.0 == value }) {
            return found.1
        }
        return "표에 없는 모드 \(value)"
    }
}
