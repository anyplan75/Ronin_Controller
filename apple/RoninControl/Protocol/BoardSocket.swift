import Foundation

/// 기판마다 고르는 연결입니다. 기본은 같은 와이파이 망입니다. USB는 펌웨어와 점검이고 촬영 경로가 아닙니다.
enum BoardLane: String, Codable, CaseIterable, Identifiable {
    case lan
    case poe
    case ap
    case usb

    var id: String { rawValue }

    init(stored: String) {
        switch stored {
        case "lan", "wifi": self = .lan
        case "poe": self = .poe
        case "ap": self = .ap
        case "usb": self = .usb
        default: self = .lan
        }
    }

    var title: String {
        switch self {
        case .lan: return "같은 와이파이"
        case .poe: return "PoE"
        case .ap: return "기판 핫스팟"
        case .usb: return "USB 점검"
        }
    }

    var detail: String {
        switch self {
        case .lan: return "192.168.10.151:81"
        case .poe: return "192.168.10.150:81"
        case .ap: return "Ronin-Olimex · 192.168.4.1:81"
        case .usb: return "플래시와 시리얼. 촬영 명령은 나가지 않습니다."
        }
    }

    /// C3 제어 소켓입니다. PoE는 올리멕스만 씁니다.
    var c3Detail: String {
        switch self {
        case .lan: return "192.168.10.152:82"
        case .ap: return "Ronin-C3 · 192.168.4.1:82"
        case .usb, .poe: return "USB는 펌웨어와 점검입니다. 촬영 명령은 나가지 않습니다."
        }
    }

    var host: String {
        switch self {
        case .lan: return "192.168.10.151"
        case .poe: return "192.168.10.150"
        case .ap: return "192.168.4.1"
        case .usb: return ""
        }
    }

    var port: Int { 81 }

    var c3Host: String {
        switch self {
        case .lan: return "192.168.10.152"
        case .ap: return "192.168.4.1"
        default: return ""
        }
    }

    var c3Port: Int { 82 }

    var shoots: Bool { self != .usb }

    static let c3Choices: [BoardLane] = [.lan, .ap, .usb]

    var socketURL: URL {
        URL(string: "ws://\(host):\(port)")!
    }
}

enum BoardLinkState: Equatable {
    case offline
    case connecting
    case online
}

/// 기판이 웹소켓으로 보내 준 카메라입니다. 메시지가 오기 전에는 만들지 않습니다.
struct BoardCamera: Identifiable, Equatable {
    var id: String
    var name: String
    var kind: String
    var ble: String
}

/// 기판 웹소켓입니다. 열림 알림이 오기 전에는 온라인으로 두지 않습니다.
final class BoardSocket: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published private(set) var state: BoardLinkState = .offline
    @Published var lane: BoardLane = .lan
    @Published private(set) var tallyNote = ""
    @Published private(set) var cameras: [BoardCamera] = []
    @Published private(set) var detail = "오프라인"
    @Published private(set) var yaw: Double?
    @Published private(set) var pitch: Double?
    @Published private(set) var reportedRecording: Int?
    /// 기판이 알려 준 주소입니다. 없으면 고른 길의 기본 주소를 씁니다.
    @Published var reportedHost = ""
    @Published var reportedPort = 81

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var toldOffline = false

    var endpoint: String {
        let host = reportedHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty { return "\(lane.host):\(lane.port)" }
        return "\(host):\(reportedPort)"
    }

    func connect() {
        if !lane.shoots {
            disconnect(quiet: true)
            detail = "USB는 펌웨어와 점검용입니다. 촬영 명령은 나가지 않습니다."
            return
        }
        disconnect(quiet: true)
        generation += 1
        let token = generation
        state = .connecting
        detail = "\(endpoint) 에 붙는 중"
        toldOffline = false
        let socket = endpointURL()
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: socket)
        self.task = task
        task.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.generation == token, self.state == .connecting else { return }
            self.fail("기판이 81번 문을 열지 않았습니다.")
        }
    }

    func disconnect(quiet: Bool = false) {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        clearLive()
        state = .offline
        if !quiet {
            detail = "오프라인"
        }
    }

    /// 소켓이 열린 뒤에만 보냅니다. 실패하면 false이고, 연결됨으로 바꾸지 않습니다.
    func send(_ payload: [String: Any]) async -> Bool {
        guard state == .online, let task else { return false }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        do {
            try await task.send(.string(text))
            return state == .online
        } catch {
            fail("명령을 보내지 못했습니다.")
            return false
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard webSocketTask === task else { return }
        state = .online
        detail = "연결됨 \(endpoint)"
        toldOffline = false
        listen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard webSocketTask === task else { return }
        fail("기판 연결이 끊겼습니다.")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        if state == .connecting || error != nil {
            fail("기판에 닿지 못했습니다.")
        }
    }

    private func listen() {
        guard let task, state == .online else { return }
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.ingest(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.ingest(text)
                        }
                    @unknown default:
                        break
                    }
                    self.listen()
                case .failure:
                    self.fail("기판 연결이 끊겼습니다.")
                }
            }
        }
    }

    private func ingest(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let rows = object["cameras"] as? [[String: Any]] {
            cameras = rows.compactMap { row in
                let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty else { return nil }
                let id = (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let kind = (row["kind"] as? String) ?? ""
                let ble = (row["ble"] as? String) ?? BoardSocket.ble(for: kind)
                return BoardCamera(id: (id?.isEmpty == false ? id! : name), name: name, kind: kind, ble: ble)
            }
        }
        if let ronin = object["ronin"] as? [String: Any] {
            yaw = ronin["yaw"] as? Double
            pitch = ronin["pitch"] as? Double
        }
        if let count = object["recording"] as? Int {
            reportedRecording = count
        }
        if let tally = object["tally"] as? [String: Any], let note = tally["note"] as? String {
            tallyNote = note
        }
        if let host = object["host"] as? String {
            let clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                reportedHost = clean
                if let port = object["port"] as? Int, port > 0 {
                    reportedPort = port
                }
                detail = "연결됨 \(endpoint)"
            }
        }
    }

    private func fail(_ text: String) {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        clearLive()
        state = .offline
        detail = text
        if !toldOffline {
            toldOffline = true
        }
    }

    private func clearLive() {
        cameras = []
        yaw = nil
        pitch = nil
        reportedRecording = nil
    }

    private func endpointURL() -> URL {
        let host = reportedHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty { return lane.socketURL }
        return URL(string: "ws://\(host):\(reportedPort)") ?? lane.socketURL
    }

    static func ble(for kind: String) -> String {
        let text = kind.lowercased()
        if text.contains("osmo") || text.contains("dji") { return "FFF0" }
        if text.contains("insta") { return "CE80" }
        return "FEA6"
    }
}

/// C3 한 대의 웹소켓입니다. 로닌이나 조명 명령의 성공은 ack 가 true 일 때만입니다.
final class C3JobSocket: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published private(set) var state: BoardLinkState = .offline
    @Published private(set) var boardId: UUID?
    @Published private(set) var detail = "오프라인"
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var waiter: ((Bool, String) -> Void)?

    func connect(_ board: C3BoardRecord) {
        guard board.link.shoots, !board.link.c3Host.isEmpty else {
            disconnect()
            detail = "USB는 펌웨어와 점검입니다."
            return
        }
        disconnect()
        generation += 1
        let token = generation
        boardId = board.id
        state = .connecting
        let host = board.socketHost
        detail = "\(host):\(board.link.c3Port) 에 붙는 중"
        let url = URL(string: "ws://\(host):\(board.link.c3Port)")!
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.generation == token, self.state == .connecting else { return }
            self.fail("C3 가 82번 문을 열지 않았습니다.")
        }
    }

    func disconnect() {
        generation += 1
        finish(ack: false, reason: "연결이 끊겼습니다.")
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = .offline
        boardId = nil
        detail = "오프라인"
    }

    /// 열린 소켓으로만 보냅니다. 기판이 ack true 를 주기 전에는 성공으로 보지 않습니다.
    func command(_ payload: [String: Any]) async -> (sent: Bool, ack: Bool, reason: String) {
        guard state == .online, let task else {
            return (false, false, "C3 가 오프라인입니다. 명령을 보내지 않았습니다.")
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return (false, false, "명령을 만들지 못했습니다.")
        }
        do {
            try await task.send(.string(text))
        } catch {
            fail("명령을 보내지 못했습니다.")
            return (false, false, "명령을 보내지 못했습니다.")
        }
        return await withCheckedContinuation { continuation in
            waiter = { ack, reason in
                continuation.resume(returning: (true, ack, reason))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.waiter != nil else { return }
                self.finish(ack: false, reason: "C3 가 응답하지 않았습니다. 성공으로 두지 않습니다.")
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard webSocketTask === task else { return }
        state = .online
        detail = "연결됨"
        listen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard webSocketTask === task else { return }
        fail("C3 연결이 끊겼습니다.")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        if state != .offline {
            fail("C3 에 닿지 못했습니다.")
        }
    }

    private func listen() {
        guard let task, state == .online else { return }
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let message):
                    let text: String?
                    switch message {
                    case .string(let value): text = value
                    case .data(let data): text = String(data: data, encoding: .utf8)
                    @unknown default: text = nil
                    }
                    if let text { self.ingest(text) }
                    self.listen()
                case .failure:
                    self.fail("C3 연결이 끊겼습니다.")
                }
            }
        }
    }

    private func ingest(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let ack = object["ack"] as? Bool {
            let reason = (object["reason"] as? String) ?? (ack ? "응답을 받았습니다." : "기판이 실패라고 답했습니다.")
            finish(ack: ack, reason: reason)
        }
    }

    private func finish(ack: Bool, reason: String) {
        let pending = waiter
        waiter = nil
        pending?(ack, reason)
    }

    private func fail(_ text: String) {
        finish(ack: false, reason: text)
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = .offline
        detail = text
    }
}
