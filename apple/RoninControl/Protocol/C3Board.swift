import Darwin
import Foundation
import Network

/// 꽂혀 있는 ESP32-C3 기판의 와이파이 맥 주소입니다. 비밀번호는 여기 없습니다.
enum BoardMac {
    static let pluggedIn = "9C:CC:01:7B:CC:A4"
    static let serviceType = "_ronin-c3._tcp"

    static func isFull(_ raw: String) -> Bool {
        raw.uppercased().filter(\.isHexDigit).count == 12
    }

    static func same(_ left: String, _ right: String) -> Bool {
        let a = left.uppercased().filter(\.isHexDigit)
        let b = right.uppercased().filter(\.isHexDigit)
        return a.count == 12 && a == b
    }

    /// 12글자가 모이면 `AA:BB:CC:DD:EE:FF` 로 맞춥니다. 적는 중이면 그대로 둡니다.
    static func normalize(_ raw: String) -> String {
        let hex = raw.uppercased().filter(\.isHexDigit)
        guard hex.count == 12 else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return stride(from: 0, to: 12, by: 2).map { index in
            let start = hex.index(hex.startIndex, offsetBy: index)
            let end = hex.index(start, offsetBy: 2)
            return String(hex[start..<end])
        }.joined(separator: ":")
    }
}

/// 기판이 직접 여는 연결입니다. 집 공유기 없이 이 주소로 카메라 명령을 보냅니다. 비밀번호는 없습니다.
enum DirectBoard {
    static let ssid = "Ronin-C3"
    static let host = "192.168.100.200"
    static let port = 80
}

/// 와이파이로 붙은 길과, 기판이 직접 연 길을 한 줄씩 나눕니다.
struct BridgeLinks: Equatable, Sendable {
    var wifiUp: Bool
    var wifiSsid: String
    var wifiHost: String
    var wifiPort: Int
    var directUp: Bool
    var directSsid: String
    var directHost: String

    var commandHost: String {
        if directUp, !directHost.isEmpty { return directHost }
        if wifiUp, !wifiHost.isEmpty { return wifiHost }
        return ""
    }

    var commandPort: Int {
        if wifiUp, wifiPort > 0 { return wifiPort }
        return DirectBoard.port
    }

    var wifiLine: String {
        if wifiUp {
            let name = (wifiSsid.isEmpty || wifiSsid == "없음") ? "집 망" : wifiSsid
            return "기판 와이파이  \(name)  \(wifiHost)"
        }
        return "기판 와이파이  붙지 않음"
    }

    var directLine: String {
        let name = directSsid.isEmpty ? DirectBoard.ssid : directSsid
        let host = directHost.isEmpty ? DirectBoard.host : directHost
        if directUp {
            return "기판 직접 연결  \(name)  \(host)"
        }
        return "기판 직접 연결  \(name)  이 기기는 아직 붙어 있지 않습니다"
    }
}

/// 기판 상태 페이지에서 읽은 카메라 붙음입니다. 촬영 명령을 보내지 않고 글만 읽습니다.
struct BridgeBoardLive: Equatable, Sendable {
    var ssid: String
    var ip: String
    var boardMac: String
    /// 맥 주소(콜론 포함)마다 "붙음" 또는 "등록됨, 연결 끊김" 입니다.
    var slots: [String: String]
    /// 기판이 직접 연 연결의 이름과 주소입니다. 와이파이 주소와 섞지 않습니다.
    var directSsid: String = ""
    var directIp: String = ""

    func attachment(for slot: BridgeCameraSlot) -> String {
        guard BoardMac.isFull(slot.mac) else { return "맥 주소를 적지 않았습니다." }
        return slots[BoardMac.normalize(slot.mac)] ?? "붙지 않음"
    }

    static func read(_ page: String) -> BridgeBoardLive {
        var ssid = ""
        var ip = ""
        var board = ""
        var directSsid = ""
        var directIp = ""
        var slots: [String: String] = [:]
        for raw in page.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if let value = Self.value(line, prefix: "DIRECT_SSID:") {
                directSsid = value
                continue
            }
            if let value = Self.value(line, prefix: "DIRECT_IP:") {
                directIp = value
                continue
            }
            if let value = Self.value(line, prefix: "SSID:") {
                ssid = value
                continue
            }
            if let value = Self.value(line, prefix: "IP:") {
                ip = value
                continue
            }
            if let value = Self.value(line, prefix: "MAC:") {
                board = BoardMac.normalize(value)
                continue
            }
            guard let mac = Self.firstMac(line) else { continue }
            if line.contains("등록됨, 연결 끊김") {
                slots[mac] = "등록됨, 연결 끊김"
            } else if line.contains("연결됨") {
                slots[mac] = "붙음"
            }
        }
        return BridgeBoardLive(
            ssid: ssid,
            ip: ip,
            boardMac: board,
            slots: slots,
            directSsid: directSsid,
            directIp: directIp
        )
    }

    private static func value(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    private static func firstMac(_ line: String) -> String? {
        let token = line.split(separator: " ").first.map(String.init) ?? line
        guard BoardMac.isFull(token) else { return nil }
        return BoardMac.normalize(token)
    }
}

enum C3Client {
    static func status(host: String, port: Int) async throws -> BridgeBoardLive {
        guard let url = LocalHTTP.url(host: host, port: port, path: "/") else {
            throw CallError.noAddress
        }
        let (_, text) = try await LocalHTTP.get(url, timeout: 2)
        return BridgeBoardLive.read(text)
    }

    static func status(_ device: DeviceRecord) async throws -> BridgeBoardLive {
        try await status(host: device.host, port: device.port)
    }

    /// 기판이 한 대와만 이야기하므로, 부르는 쪽에서 카메라를 순서대로 보냅니다.
    static func shutter(_ device: DeviceRecord, mac: String, start: Bool) async throws -> String {
        let clean = BoardMac.normalize(mac)
        guard BoardMac.isFull(clean) else {
            throw CallError.unavailable("카메라 맥 주소가 아닙니다.")
        }
        guard let url = LocalHTTP.url(host: device.host, port: device.port, path: "/shutter", query: [
            "mac": clean,
            "action": start ? "start" : "stop",
        ]) else {
            throw CallError.noAddress
        }
        let (_, text) = try await LocalHTTP.get(url, timeout: 20)
        struct Body: Decodable { var detail: String? }
        if let data = text.data(using: .utf8),
           let body = try? JSONDecoder().decode(Body.self, from: data),
           let detail = body.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
           !detail.isEmpty {
            return detail
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "보냄" : trimmed
    }

    /// 기판이 주변에서 들은 고프로 맥 주소입니다. 아이폰은 이 번호를 직접 읽지 못합니다.
    static func nearbyGoPros(_ device: DeviceRecord) async throws -> [NearbyGoPro] {
        guard let startURL = LocalHTTP.url(host: device.host, port: device.port, path: "/scan", query: ["start": "1"]),
              let url = LocalHTTP.url(host: device.host, port: device.port, path: "/scan") else {
            throw CallError.noAddress
        }
        _ = try await LocalHTTP.get(startURL, timeout: 2)
        struct Body: Decodable {
            var pending: Bool?
            var cameras: [NearbyGoPro]?
            var detail: String?
        }
        for _ in 0..<10 {
            let (_, text) = try await LocalHTTP.get(url, timeout: 2)
            guard let data = text.data(using: .utf8),
                  let body = try? JSONDecoder().decode(Body.self, from: data) else {
                throw CallError.unavailable("기판이 카메라 목록을 주지 않았습니다.")
            }
            if body.pending == true {
                try await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            if let detail = body.detail, !detail.isEmpty, (body.cameras ?? []).isEmpty {
                throw CallError.unavailable(detail)
            }
            return body.cameras ?? []
        }
        throw CallError.unavailable("주변 카메라 찾기가 끝나지 않았습니다.")
    }

    static func cameraPresets(_ device: DeviceRecord, mac: String) async throws -> [CameraPresetItem] {
        let clean = BoardMac.normalize(mac)
        guard let url = LocalHTTP.url(host: device.host, port: device.port, path: "/presets", query: ["mac": clean]) else {
            throw CallError.noAddress
        }
        let (_, text) = try await LocalHTTP.get(url, timeout: 12)
        return CameraPresetText.parse(text)
    }

    static func loadCameraPreset(_ device: DeviceRecord, mac: String, id: Int) async throws -> String {
        let clean = BoardMac.normalize(mac)
        guard let url = LocalHTTP.url(host: device.host, port: device.port, path: "/preset/load", query: [
            "mac": clean,
            "id": String(id),
        ]) else { throw CallError.noAddress }
        return try await LocalHTTP.get(url, timeout: 12).1
    }

    static func setSetting(_ device: DeviceRecord, mac: String, setting: Int, option: Int) async throws -> String {
        let clean = BoardMac.normalize(mac)
        guard let url = LocalHTTP.url(host: device.host, port: device.port, path: "/setting", query: [
            "mac": clean,
            "setting": String(setting),
            "option": String(option),
        ]) else { throw CallError.noAddress }
        return try await LocalHTTP.get(url, timeout: 12).1
    }
}

struct NearbyGoPro: Decodable, Sendable {
    var mac: String
    var name: String?
    /// 기판이 그 카메라와 이미 블루투스로 붙어 있으면 true 입니다. 광고만 들리면 false 입니다.
    var attached: Bool?
}

struct CameraPresetItem: Identifiable, Sendable, Equatable {
    var id: Int
    var title: String
}

enum CameraPresetText {
    static func title(id: Int, titleId: Int, name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let names = [
            0: "액티비티", 1: "표준", 2: "시네마틱", 3: "사진", 4: "라이브 버스트",
            5: "버스트", 6: "야간", 7: "타임워프", 8: "타임랩스", 9: "나이트 랩스",
            10: "비디오", 11: "슬로 모션", 14: "파노라마", 35: "액션",
        ]
        if let known = names[titleId] { return known }
        return "프리셋 \(id)"
    }

    static func parse(_ text: String) -> [CameraPresetItem] {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let root = json as? [String: Any], let presets = root["presets"] as? [[String: Any]] {
            return presets.compactMap { item in
                guard let id = item["id"] as? Int else { return nil }
                let titleId = item["titleId"] as? Int ?? -1
                let name = item["name"] as? String ?? ""
                return CameraPresetItem(id: id, title: title(id: id, titleId: titleId, name: name))
            }
        }
        guard let root = json as? [String: Any],
              let groups = root["presetGroupArray"] as? [[String: Any]] else { return [] }
        var items: [CameraPresetItem] = []
        for group in groups {
            let presets = group["presets"] as? [[String: Any]] ?? []
            for preset in presets {
                guard let id = preset["id"] as? Int else { continue }
                let name = (preset["title"] as? String) ?? (preset["customName"] as? String) ?? ""
                let titleId = preset["title"] as? Int ?? -1
                items.append(CameraPresetItem(id: id, title: title(id: id, titleId: titleId, name: name)))
            }
        }
        return items
    }
}

/// 기판이 알리는 이름을 듣고, 맥 주소가 맞으면 바로 숫자 주소를 받습니다.
@MainActor
final class C3Link {
    var onFound: ((String, String, Int) -> Void)?
    var onPhase: ((String) -> Void)?

    private var browser: NWBrowser?
    private var resolvers: [String: C3Resolver] = [:]
    /// 이름 알림으로 들은 기판입니다. 상태 페이지가 대답하기 전에는 맥 주소를 확정하지 않습니다.
    private var heard: [String: (host: String, port: Int)] = [:]

    func start() {
        guard browser == nil else { return }
        onPhase?("기판을 찾는 중입니다.")
        let browser = NWBrowser(for: .bonjour(type: BoardMac.serviceType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.apply(state)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.apply(results)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// 이미 들은 기판이 있으면 바로 돌려주고, 없으면 알림이 올 때까지 잠깐 듣습니다.
    func listen() async -> [(mac: String, host: String, port: Int)] {
        let started = Date()
        while heard.isEmpty && Date().timeIntervalSince(started) < 4 {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return heard.map { (mac: $0.key, host: $0.value.host, port: $0.value.port) }
    }

    private func apply(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            onPhase?("기판을 찾는 중입니다.")
        case .waiting:
            onPhase?("로컬 네트워크를 허용하면 기판을 바로 찾습니다.")
        case .failed:
            onPhase?("기판 찾기를 시작하지 못했습니다.")
        case .cancelled, .setup:
            break
        @unknown default:
            break
        }
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        var live = Set<String>()
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            live.insert(trimmed)
            let hinted = mac(from: result) ?? mac(inName: trimmed)
            guard resolvers[trimmed] == nil else { continue }
            let resolver = C3Resolver(name: trimmed, type: type, domain: domain, hintedMac: hinted)
            resolvers[trimmed] = resolver
            resolver.onAddress = { [weak self] mac, host, port in
                Task { @MainActor in
                    self?.resolvers[trimmed] = nil
                    guard BoardMac.isFull(mac), !host.isEmpty, port > 0 else { return }
                    let clean = BoardMac.normalize(mac)
                    self?.heard[clean] = (host, port)
                    self?.onFound?(clean, host, port)
                }
            }
            resolver.onFail = { [weak self] in
                Task { @MainActor in
                    self?.resolvers[trimmed] = nil
                }
            }
            resolver.start()
        }
        for key in resolvers.keys where !live.contains(key) {
            resolvers[key]?.stop()
            resolvers[key] = nil
        }
    }

    private func mac(from result: NWBrowser.Result) -> String? {
        guard case .bonjour(let record) = result.metadata, let raw = record["mac"], BoardMac.isFull(raw) else {
            return nil
        }
        return BoardMac.normalize(raw)
    }

    private func mac(inName name: String) -> String? {
        BoardMac.isFull(name) ? BoardMac.normalize(name) : nil
    }
}

/// 알림 이름을 숫자 주소로 바꿉니다. 맥 주소가 없으면 기판으로 받지 않습니다.
private final class C3Resolver: NSObject, NetServiceDelegate {
    let service: NetService
    let hintedMac: String?
    var onAddress: ((String, String, Int) -> Void)?
    var onFail: (() -> Void)?
    private var finished = false

    init(name: String, type: String, domain: String, hintedMac: String?) {
        let typeText = type.hasSuffix(".") ? type : type + "."
        let domainText = domain.isEmpty ? "local." : (domain.hasSuffix(".") ? domain : domain + ".")
        service = NetService(domain: domainText, type: typeText, name: name)
        self.hintedMac = hintedMac
        super.init()
        service.delegate = self
    }

    func start() {
        service.resolve(withTimeout: 5)
    }

    func stop() {
        service.stop()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard !finished, sender.port > 0 else { return }
        finished = true
        let mac = txtMac(sender) ?? hintedMac ?? ""
        guard BoardMac.isFull(mac) else {
            onFail?()
            return
        }
        if let host = Self.ipv4(sender) {
            onAddress?(mac, host, sender.port)
            return
        }
        var host = sender.hostName ?? ""
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else {
            onFail?()
            return
        }
        onAddress?(mac, host, sender.port)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard !finished else { return }
        finished = true
        _ = errorDict
        onFail?()
    }

    private func txtMac(_ sender: NetService) -> String? {
        guard let data = sender.txtRecordData() else { return nil }
        let table = NetService.dictionary(fromTXTRecord: data)
        guard let raw = table["mac"], let text = String(data: raw, encoding: .utf8), BoardMac.isFull(text) else {
            return nil
        }
        return BoardMac.normalize(text)
    }

    private static func ipv4(_ sender: NetService) -> String? {
        guard let addresses = sender.addresses else { return nil }
        for data in addresses {
            if let host = ipv4Address(data), host != "0.0.0.0" {
                return host
            }
        }
        return nil
    }

    private static func ipv4Address(_ data: Data) -> String? {
        guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
        let family: UInt8 = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            return base.loadUnaligned(as: sockaddr.self).sa_family
        }
        guard family == UInt8(AF_INET) else { return nil }
        var address = sockaddr_in()
        withUnsafeMutableBytes(of: &address) { dest in
            data.copyBytes(to: dest.bindMemory(to: UInt8.self), count: MemoryLayout<sockaddr_in>.size)
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
    }
}
