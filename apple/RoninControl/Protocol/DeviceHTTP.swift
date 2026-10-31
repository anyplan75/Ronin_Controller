import Foundation

enum CallError: LocalizedError {
    case noAddress
    case badURL
    case http(Int, String)
    case ble(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .noAddress:
            return "주소가 비어 있습니다."
        case .badURL:
            return "주소 형식이 잘못되었습니다."
        case .http(let code, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "HTTP \(code) \(trimmed)"
        case .ble(let message), .unavailable(let message):
            return message
        }
    }
}

struct CallOutcome: Equatable, Sendable {
    var ok: Bool
    var text: String
    var practice: Bool
}

enum LocalHTTP {
    static func url(host: String, port: Int, path: String, query: [String: String] = [:]) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, port > 0 else { return nil }
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = trimmed
        parts.port = port
        parts.path = path.hasPrefix("/") ? path : "/" + path
        if !query.isEmpty {
            parts.queryItems = query.keys.sorted().map { URLQueryItem(name: $0, value: query[$0]) }
        }
        return parts.url
    }

    static func get(_ url: URL, timeout: TimeInterval = 4) async throws -> (Int, String) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        if code >= 400 {
            throw CallError.http(code, text)
        }
        return (code, text)
    }
}

struct RoninStatus: Codable, Equatable, Sendable {
    var ip: String?
    var ethLink: Bool?
    var twai: String?
    var yaw: Double?
    var roll: Double?
    var pitch: Double?
    var attitudeValid: Bool?
    var camRecording: Bool?
    var syncArmed: Bool?
    var syncWaitMs: Int?
    var syncResult: String?
    var shot: String?
    var shotBusy: Bool?
    var sonyWifi: Bool?
    var sonyRecording: Bool?
    var sonyError: String?
    var txFails: Int?
    var millis: UInt32?

    enum CodingKeys: String, CodingKey {
        case ip
        case ethLink = "eth_link"
        case twai, yaw, roll, pitch
        case attitudeValid = "attitude_valid"
        case camRecording = "cam_recording"
        case syncArmed = "sync_armed"
        case syncWaitMs = "sync_wait_ms"
        case syncResult = "sync_result"
        case shot
        case shotBusy = "shot_busy"
        case sonyWifi = "sony_wifi"
        case sonyRecording = "sony_recording"
        case sonyError = "sony_error"
        case txFails = "tx_fails"
        case millis
    }
}

enum RoninClient {
    static func status(_ device: DeviceRecord) async throws -> RoninStatus {
        let text = try await send(device, path: "/status", timeout: 2.5).text
        guard let data = text.data(using: .utf8) else { throw CallError.http(200, text) }
        return try JSONDecoder().decode(RoninStatus.self, from: data)
    }

    static func clock(_ device: DeviceRecord) async throws -> UInt32 {
        let text = try await send(device, path: "/sync/clock", timeout: 2).text
        struct Body: Decodable { var millis: UInt32 }
        guard let data = text.data(using: .utf8) else { throw CallError.http(200, text) }
        return try JSONDecoder().decode(Body.self, from: data).millis
    }

    static func syncRecord(_ device: DeviceRecord, action: String, atMs: UInt32?, delayMs: Int?) async throws -> String {
        var query = ["action": action]
        if let atMs {
            query["at_ms"] = String(atMs)
        } else if let delayMs {
            query["delay_ms"] = String(delayMs)
        }
        return try await send(device, path: "/sync/record", query: query).text
    }

    static func command(_ device: DeviceRecord, path: String, query: [String: String] = [:]) async throws -> String {
        try await send(device, path: path, query: query).text
    }

    private static func send(
        _ device: DeviceRecord,
        path: String,
        query: [String: String] = [:],
        timeout: TimeInterval = 4
    ) async throws -> CallOutcome {
        guard let url = LocalHTTP.url(host: device.host, port: device.port, path: path, query: query) else {
            throw CallError.noAddress
        }
        let (_, text) = try await LocalHTTP.get(url, timeout: timeout)
        return CallOutcome(ok: true, text: text, practice: false)
    }
}

struct GoProLive: Equatable, Sendable {
    var encoding: Bool?
    var remainingVideo: Int?
    var remainingPhotos: Int?
    var busy: Bool?
    var sdRemaining: Int?
    var settings: [Int: Int]
    var presetList: String
    var error: String
    /// 액션 5 프로 중계 기판이 적어 주는 블루투스 세션 글입니다. 직접 연결 고프로는 비어 있습니다.
    var relayBle: String
    /// 카메라가 알려 준 모델 이름입니다. 없으면 비어 있습니다.
    var modelName: String = ""
    /// 미디어 모드 HDMI 비트입니다. 상태가 없으면 nil입니다.
    var hdmiOut: Bool? = nil
    /// USB로 카메라를 제어 중이면 참입니다. 케이블만 꽂힌 것은 출력이 아닙니다.
    var usbOut: Bool? = nil
}

// 고프로 가족은 Open GoPro HTTP만 사용합니다.
// 직접 연결은 카메라(보통 10.5.5.9:8080)이고, 액션 5 프로는 별도 중계 기판입니다.
// HM-10 서비스 FFE0/FFE1 과 4바이트 셔터 쓰기는 쓰지 않습니다.
enum GoProClient {
    static func state(_ device: DeviceRecord) async throws -> GoProLive {
        let text = try await get(device, path: "/gopro/camera/state")
        var live = parseState(text)
        if let info = try? await get(device, path: "/gopro/camera/info", timeout: 3) {
            live.modelName = modelName(info)
        }
        return live
    }

    static func shutter(_ device: DeviceRecord, start: Bool) async throws -> String {
        try await get(device, path: "/gopro/camera/shutter/\(start ? "start" : "stop")")
    }

    static func keepAlive(_ device: DeviceRecord) async throws -> String {
        try await get(device, path: "/gopro/camera/keep_alive")
    }

    /// 액션 5 프로 중계 기판에, 이미 잡아 둔 Open GoPro BLE 세션을 다시 붙이라고 합니다.
    static func pairRelay(_ device: DeviceRecord) async throws -> String {
        try await get(device, path: "/pair", timeout: 25)
    }

    /// 비밀번호는 중계 기판에만 전달합니다. 이 함수의 결과를 기록에 그대로 남기지 마세요.
    static func saveRelayWifi(_ device: DeviceRecord, ssid: String, password: String) async throws -> String {
        try await get(device, path: "/wifi", query: ["ssid": ssid, "pass": password], timeout: 8)
    }

    static func setSetting(_ device: DeviceRecord, setting: Int, option: Int) async throws -> String {
        try await get(device, path: "/gopro/camera/setting", query: [
            "setting": String(setting),
            "option": String(option),
        ])
    }

    static func loadPreset(_ device: DeviceRecord, id: Int) async throws -> String {
        try await get(device, path: "/gopro/camera/presets/load", query: ["id": String(id)])
    }

    static func presetList(_ device: DeviceRecord) async throws -> String {
        try await get(device, path: "/gopro/camera/presets/get")
    }

    static func digitalZoom(_ device: DeviceRecord, percent: Int) async throws -> String {
        let clamped = min(100, max(0, percent))
        return try await get(device, path: "/gopro/camera/digital_zoom", query: ["percent": String(clamped)])
    }

    static func webcam(_ device: DeviceRecord, start: Bool) async throws -> String {
        try await get(device, path: "/gopro/webcam/\(start ? "start" : "stop")")
    }

    /// 카메라 자신의 미리보기 스트림을 켜거나 끕니다. 그림 파일을 받아 오지는 않습니다.
    static func previewStream(_ device: DeviceRecord, start: Bool) async throws -> String {
        guard device.kind.supportsLiveView else {
            throw CallError.unavailable("이 장치는 미리보기 그림을 주지 않습니다.")
        }
        return try await get(device, path: "/gopro/camera/stream/\(start ? "start" : "stop")", timeout: 6)
    }

    private static func get(
        _ device: DeviceRecord,
        path: String,
        query: [String: String] = [:],
        timeout: TimeInterval = 4
    ) async throws -> String {
        guard let url = LocalHTTP.url(host: device.host, port: device.port, path: path, query: query) else {
            throw CallError.noAddress
        }
        return try await LocalHTTP.get(url, timeout: timeout).1
    }

    static func parseState(_ text: String) -> GoProLive {
        var live = GoProLive(
            encoding: nil, remainingVideo: nil, remainingPhotos: nil, busy: nil,
            sdRemaining: nil, settings: [:], presetList: "", error: "", relayBle: ""
        )
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            live.error = text
            return live
        }
        if let relay = json["relay_ble"] as? String {
            live.relayBle = relay
        }
        let status = json["status"] as? [String: Any] ?? [:]
        let settings = json["settings"] as? [String: Any] ?? [:]
        live.encoding = boolish(status["10"])
        live.busy = boolish(status["8"])
        live.remainingVideo = intish(status["35"])
        live.remainingPhotos = intish(status["34"])
        live.sdRemaining = intish(status["54"])
        live.hdmiOut = hdmiSending(intish(status["110"]))
        live.usbOut = usbSending(intish(status["116"]))
        for (key, value) in settings {
            if let id = Int(key), let option = intish(value) {
                live.settings[id] = option
            }
        }
        return live
    }

    /// 표시 모듈 상태 110번의 HDMI 비트입니다. 2·3·6·7이면 HDMI를 내보냅니다.
    static func hdmiSending(_ value: Int?) -> Bool? {
        guard let value else { return nil }
        return value == 2 || value == 3 || value == 6 || value == 7
    }

    /// USB 제어 116번이 1이면 USB로 카메라를 다루고 있습니다.
    static func usbSending(_ value: Int?) -> Bool? {
        guard let value else { return nil }
        return value == 1
    }

    static func modelName(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        if let name = json["model_name"] as? String { return name }
        if let info = json["info"] as? [String: Any], let name = info["model_name"] as? String { return name }
        return ""
    }

    private static func intish(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func boolish(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = intish(value) { return value != 0 }
        return nil
    }
}
