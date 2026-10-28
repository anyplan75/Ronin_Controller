import Foundation

// 장치에 저장하는 프로필입니다. 주소는 여기 들어 있고, 비밀번호는 넣지 않습니다.
// 저장 열쇠 앞에 [로닌컨트롤]_ 을 붙여 다른 프로젝트와 섞이지 않게 합니다.

enum DeviceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case ronin
    case gopro
    /// 고프로 액션 5 프로. 앱은 별도 중계 기판의 HTTP만 부릅니다. 로닌 PoE가 아닙니다.
    case goproAction5
    case osmoAction
    case osmoNoAPI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ronin: return "로닌 기판"
        case .gopro: return "고프로 직접 연결"
        case .goproAction5: return "고프로 액션 5 프로"
        case .osmoAction: return "오즈모 액션·360"
        case .osmoNoAPI: return "오즈모 포켓·모바일·나노"
        }
    }

    var usesHTTP: Bool { self == .ronin || isGoProFamily }

    /// 액션 5 프로를 뺀 고프로는 카메라 와이파이로 직접 붙습니다.
    var isDirectGoPro: Bool { self == .gopro }

    /// 둘 다 Open GoPro HTTP 경로를 쓰지만, 붙는 장치가 다릅니다.
    var isGoProFamily: Bool { self == .gopro || self == .goproAction5 }

    var defaultPort: Int {
        switch self {
        case .ronin, .goproAction5: return 80
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

    static func choices(for kind: DeviceKind) -> [OsmoModel] {
        switch kind {
        case .osmoAction: return [.action5Pro, .action4, .action6, .osmo360]
        case .osmoNoAPI: return [.pocket, .mobile, .nano, .unknown]
        default: return []
        }
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

    var baseURLText: String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, port > 0 else { return "" }
        return "http://\(trimmed):\(port)"
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
