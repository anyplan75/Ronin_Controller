import Foundation

/// 올리멕스 ESP32-PoE 한 장에 붙는 길입니다. PoE는 192.168.0.150, 와이파이는 192.168.0.151, 문은 81번 웹소켓입니다.
enum BoardLane: String, Codable, CaseIterable, Identifiable {
    case poe
    case wifi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .poe: return "PoE 이더넷"
        case .wifi: return "와이파이"
        }
    }

    var host: String {
        switch self {
        case .poe: return "192.168.0.150"
        case .wifi: return "192.168.0.151"
        }
    }

    var port: Int { 81 }

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
    @Published var lane: BoardLane = .poe
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
