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

    /// C3 제어 소켓입니다. PoE는 올리멕스만 씁니다. 실제 주소는 보드 슬롯 고정 IP를 씁니다.
    var c3Detail: String {
        switch self {
        case .lan: return "집 망 · 슬롯 고정 IP:82 (OLED .152 / S3 .153 / RMSID .154)"
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
    /// 기판이 대별 녹화 상태를 줄 때만 채웁니다. 없으면 nil 이고 앱이 tally.note 로 맞춥니다.
    var recording: Bool? = nil
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
    @Published private(set) var wifiMac = ""
    @Published private(set) var ethMac = ""
    @Published private(set) var apMac = ""
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var toldOffline = false
    private var keepAliveTimer: Timer?
    private var reconnectWork: DispatchWorkItem?
    private var offlineWork: DispatchWorkItem?
    private var wantConnected = false
    private var reconnectDelay: TimeInterval = 1
    /// 녹화·탈리 한 건의 ack/tally.note 를 기다리는 콜백입니다.
    private var tallyWaiter: ((Bool, String) -> Void)?
    private var tallyWaitName = ""

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
        if state == .online, task != nil {
            wantConnected = true
            detail = "연결됨 \(endpoint)"
            return
        }
        if state == .connecting, task != nil {
            wantConnected = true
            return
        }
        openSocket(clearLive: true)
    }

    private func openSocket(clearLive: Bool) {
        reconnectWork?.cancel()
        offlineWork?.cancel()
        stopKeepAlive()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        if clearLive { self.clearLive() }
        generation += 1
        let token = generation
        wantConnected = true
        state = .connecting
        detail = "\(endpoint) 에 붙는 중"
        toldOffline = false
        let socket = endpointURL()
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: socket)
        self.task = task
        task.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.generation == token, self.state == .connecting else { return }
            self.softDrop("\(self.endpoint) 이 열리지 않았습니다. 기판은 2.4GHz만 붙습니다.")
        }
    }

    func disconnect(quiet: Bool = false) {
        wantConnected = false
        reconnectWork?.cancel()
        offlineWork?.cancel()
        stopKeepAlive()
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        clearLive()
        state = .offline
        reconnectDelay = 1
        if !quiet {
            detail = "오프라인"
        }
    }

    /// 소켓이 열린 뒤에만 보냅니다. 실패하면 false이고, 연결됨으로 바꾸지 않습니다.
    /// 주의: true 는 웹소켓 쓰기 성공일 뿐, BLE 셔터 성공이 아닙니다.
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
            softDrop("명령을 보내지 못했습니다.")
            return false
        }
    }

    /// 보내고 기판 tally.note(BLE 결과)를 기다립니다. 소켓만 열린 것으로 성공 처리하지 않습니다.
    func sendAwaitingTally(
        _ payload: [String: Any],
        matching name: String,
        timeout: TimeInterval = 18
    ) async -> (sent: Bool, ok: Bool, note: String) {
        guard await send(payload) else {
            return (false, false, "")
        }
        return await withCheckedContinuation { continuation in
            var finished = false
            let finish: (Bool, String) -> Void = { [weak self] ok, note in
                guard !finished else { return }
                finished = true
                self?.tallyWaiter = nil
                self?.tallyWaitName = ""
                continuation.resume(returning: (true, ok, note))
            }
            tallyWaitName = name
            tallyWaiter = { ok, note in
                finish(ok, note)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.tallyWaiter != nil else { return }
                let fallback = self.tallyNote
                let text = fallback.isEmpty
                    ? "\(name) 기판 BLE 답을 기다렸지만 오지 않았습니다. 녹화로 두지 않습니다."
                    : fallback
                finish(false, text)
            }
        }
    }

    /// 기판 tally.note 문장으로 BLE 성공·실패를 가릅니다.
    static func tallyOutcome(_ note: String) -> TallyOutcome {
        if note.contains("붙지 못했습니다")
            || note.contains("보내지 않았습니다")
            || note.contains("답하지 않았습니다")
            || note.contains("명령이 없어") {
            return .failure
        }
        // 셔터는 상태 0인데 LED만 실패한 경우도 녹화는 성공으로 봅니다.
        if note.contains("받았습니다") || note.contains("셔터는 상태 0") {
            return .success
        }
        return .unknown
    }

    enum TallyOutcome {
        case success
        case failure
        case unknown
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard webSocketTask === task else { return }
        offlineWork?.cancel()
        reconnectDelay = 1
        state = .online
        detail = "연결됨 \(endpoint)"
        toldOffline = false
        startKeepAlive()
        listen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard webSocketTask === task else { return }
        softDrop("기판 연결이 끊겼습니다.")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        if state == .connecting || error != nil || wantConnected {
            softDrop("기판에 닿지 못했습니다.")
        }
    }

    private func listen() {
        guard let task, state == .online || state == .connecting else { return }
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
                    self.softDrop("기판 연결이 끊겼습니다.")
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
                // 로닌 짐벌은 올리멕스 목록에 두지 않습니다. 조종은 C3 로닌 역할만입니다.
                if BoardSocket.looksLikeRoninGimbal(name) { return nil }
                let id = (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let kind = (row["kind"] as? String) ?? ""
                let ble = (row["ble"] as? String) ?? BoardSocket.ble(for: kind)
                let recording = row["recording"] as? Bool
                return BoardCamera(
                    id: (id?.isEmpty == false ? id! : name),
                    name: name,
                    kind: kind,
                    ble: ble,
                    recording: recording
                )
            }
        }
        if let ronin = object["ronin"] as? [String: Any] {
            yaw = ronin["yaw"] as? Double
            pitch = ronin["pitch"] as? Double
        }
        if let count = object["recording"] as? Int {
            reportedRecording = count
        }
        // 연결 hello/카메라 목록에는 ack 없음. 녹화·설정 응답만.
        if object["cameras"] == nil, let ack = object["ack"] as? Bool {
            let reason = (object["reason"] as? String)
                ?? (object["tally"] as? [String: Any]).flatMap { $0["note"] as? String }
                ?? (ack ? "응답을 받았습니다." : "기판이 실패라고 답했습니다.")
            if let note = (object["tally"] as? [String: Any])?["note"] as? String, !note.isEmpty {
                tallyNote = note
            } else if !reason.isEmpty {
                tallyNote = reason
            }
            if let waiter = tallyWaiter {
                if tallyWaitName.isEmpty || reason.contains(tallyWaitName) || tallyNote.contains(tallyWaitName) {
                    waiter(ack, reason)
                }
            }
        } else if let tally = object["tally"] as? [String: Any], let note = tally["note"] as? String {
            tallyNote = note
            if let waiter = tallyWaiter {
                if tallyWaitName.isEmpty || note.contains(tallyWaitName) {
                    switch BoardSocket.tallyOutcome(note) {
                    case .success: waiter(true, note)
                    case .failure: waiter(false, note)
                    case .unknown: break
                    }
                }
            }
        }
        if let picked = hostForLane(object) {
            reportedHost = picked
            if let port = object["port"] as? Int, port > 0 {
                reportedPort = port
            }
            detail = "연결됨 \(endpoint)"
        }
        if let mac = object["wifiMac"] as? String, !mac.isEmpty { wifiMac = mac }
        if let mac = object["ethMac"] as? String, !mac.isEmpty { ethMac = mac }
        if let mac = object["apMac"] as? String, !mac.isEmpty { apMac = mac }
    }

    private func softDrop(_ text: String) {
        stopKeepAlive()
        if let waiter = tallyWaiter {
            tallyWaiter = nil
            tallyWaitName = ""
            waiter(false, text)
        }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        guard wantConnected, lane.shoots else {
            clearLive()
            state = .offline
            detail = text
            if !toldOffline { toldOffline = true }
            return
        }
        state = .connecting
        detail = "다시 붙는 중… \(endpoint)"
        offlineWork?.cancel()
        let markOffline = DispatchWorkItem { [weak self] in
            guard let self, self.wantConnected, self.state != .online else { return }
            self.clearLive()
            self.state = .offline
            self.detail = text
            if !self.toldOffline { self.toldOffline = true }
        }
        offlineWork = markOffline
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: markOffline)
        reconnectWork?.cancel()
        let delay = min(reconnectDelay, 8)
        reconnectDelay = min(reconnectDelay * 1.6, 8)
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantConnected, self.generation == token, self.state != .online else { return }
            self.openSocket(clearLive: false)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startKeepAlive() {
        stopKeepAlive()
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.state == .online, let task = self.task else { return }
            task.sendPing { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, error != nil else { return }
                    self.softDrop("기판 응답이 없어 다시 붙습니다.")
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: ["op": "ping"]),
               let text = String(data: data, encoding: .utf8) {
                Task { try? await task.send(.string(text)) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    private func clearLive() {
        cameras = []
        yaw = nil
        pitch = nil
        reportedRecording = nil
        if let waiter = tallyWaiter {
            tallyWaiter = nil
            tallyWaitName = ""
            // 대기 중인 sendAwaitingTally 를 실패로 끝냅니다.
            waiter(false, "올리멕스 연결이 끊겨 명령을 보내지 않았습니다.")
        }
    }

    /// 고른 길과 다른 주소로 바꾸지 않습니다. 와이파이 중인데 이더넷 주소로 갈아타면 다시 끊깁니다.
    private func hostForLane(_ object: [String: Any]) -> String? {
        let wifi = (object["wifiHost"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let eth = (object["ethHost"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let host = (object["host"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch lane {
        case .lan:
            if wifi.hasPrefix("192.168.10.") { return wifi }
            if host.hasPrefix("192.168.10.") { return host }
        case .poe:
            if eth == "192.168.10.150" { return eth }
            if host == "192.168.10.150" { return host }
        case .ap:
            if host == "192.168.4.1" || wifi == "192.168.4.1" { return "192.168.4.1" }
        case .usb:
            break
        }
        return nil
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

    /// 올리멕스 카메라 목록에서 걸러 낼 로닌 RS·SC 짐벌 이름입니다. C3 로닌 역할만 붙입니다.
    static func looksLikeRoninGimbal(_ name: String) -> Bool {
        let text = name.lowercased()
        let keys = [
            "ronin", "ronin-sc", "ronin sc",
            "dji rs", "rs 2", "rs2", "rsc", "rsc2", "rsc 2",
            "rs 3", "rs3", "rs 4", "rs4",
        ]
        return keys.contains { text.contains($0) }
    }
}

/// C3 가 스캔해 준 로닌·울란지 이름입니다.
struct C3Gimbal: Identifiable, Equatable {
    var id: String
    var name: String
    /// 저장 칸(0·1). 스캔 후보는 nil.
    var index: Int? = nil
}

/// S3 에 저장된 울란지 한 대입니다. 개별 밝기·색온도 UI에 씁니다.
struct SavedLight: Identifiable, Equatable {
    var id: String
    var name: String
    var index: Int
}

/// 고정 IP 보드가 살아 있는지 WS hello 한 줄로 확인합니다.
enum BoardHello {
    struct Info {
        var slot: String
        var wifiMac: String
        var host: String
        var job: String
    }

    static func probe(host: String, port: Int = 82, timeout: TimeInterval = 2.5) async -> Info? {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let url = URL(string: "ws://\(clean):\(port)") else { return nil }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        do {
            let message = try await withTimeout(timeout) {
                try await task.receive()
            }
            let text: String?
            switch message {
            case .string(let value): text = value
            case .data(let data): text = String(data: data, encoding: .utf8)
            @unknown default: text = nil
            }
            guard let text, let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let slot = (object["slot"] as? String) ?? ""
            let wifi = (object["wifiMac"] as? String) ?? ""
            let reported = (object["host"] as? String) ?? clean
            let job = (object["job"] as? String) ?? ""
            guard !slot.isEmpty || BoardMac.isFull(wifi) else { return nil }
            return Info(slot: slot, wifiMac: wifi, host: reported, job: job)
        } catch {
            return nil
        }
    }

    private static func withTimeout<T>(_ seconds: TimeInterval, _ work: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}

/// C3 한 대의 웹소켓입니다. 로닌이나 조명 명령의 성공은 ack 가 true 일 때만입니다.
final class C3JobSocket: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published private(set) var state: BoardLinkState = .offline
    @Published private(set) var boardId: UUID?
    @Published private(set) var detail = "오프라인"
    @Published private(set) var wifiMac = ""
    @Published private(set) var apMac = ""
    @Published private(set) var gimbals: [C3Gimbal] = []
    /// S3 저장 울란지(최대 2). 개별 조작 UI용.
    @Published private(set) var savedLights: [SavedLight] = []
    @Published private(set) var pairedName = ""
    @Published private(set) var otaNote = ""
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var generation = 0
    private var waiter: ((Bool, String) -> Void)?
    private var otaStarted = false
    /// 기판 hello 가 알려 준 host. 등록 lanHost 와 맞춰 둘 때 씁니다.
    @Published private(set) var lastHost = ""
    @Published private(set) var lastSlot = ""
    private var lastFw = ""
    private var lastBoard: C3BoardRecord?
    private var keepAliveTimer: Timer?
    private var reconnectWork: DispatchWorkItem?
    private var offlineWork: DispatchWorkItem?
    private var wantConnected = false
    private var reconnectDelay: TimeInterval = 1

    func connect(_ board: C3BoardRecord) {
        guard board.link.shoots, !board.link.c3Host.isEmpty else {
            disconnect()
            detail = "USB는 펌웨어와 점검입니다."
            return
        }
        // 같은 보드가 이미 온라인이면 끊었다 붙이지 않습니다. 조명·로닌 조작과 「지금 연결」이 꼬이지 않게.
        if boardId == board.id, state == .online, task != nil {
            lastBoard = board
            wantConnected = true
            detail = "연결됨 \(board.socketHost)"
            return
        }
        if boardId == board.id, state == .connecting, task != nil { return }
        open(board, clearLists: boardId != board.id)
    }

    private func open(_ board: C3BoardRecord, clearLists: Bool) {
        reconnectWork?.cancel()
        offlineWork?.cancel()
        stopKeepAlive()
        finish(ack: false, reason: "연결을 다시 엽니다.")
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        generation += 1
        let token = generation
        boardId = board.id
        lastBoard = board
        wantConnected = true
        state = .connecting
        if clearLists {
            wifiMac = ""
            apMac = ""
            gimbals = []
            savedLights = []
            pairedName = ""
            otaStarted = false
            lastHost = ""
            lastSlot = ""
            lastFw = ""
            otaNote = ""
        }
        let host = board.socketHost
        detail = "\(host):\(board.link.c3Port) 에 붙는 중"
        let url = URL(string: "ws://\(host):\(board.link.c3Port)")!
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.generation == token, self.state == .connecting else { return }
            self.softDrop("\(host):\(board.link.c3Port) 이 열리지 않았습니다. C3 는 2.4GHz만 붙습니다.")
        }
    }

    /// 온라인이 될 때까지 기다립니다. 이미 붙어 있으면 바로 true 입니다.
    func ensureOnline(_ board: C3BoardRecord, timeout: TimeInterval = 5) async -> Bool {
        if boardId == board.id, state == .online { return true }
        // 다시 붙는 중이면 끊지 않고 기다립니다.
        if boardId == board.id, state == .connecting {
            // fall through
        } else {
            connect(board)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if boardId == board.id, state == .online { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return boardId == board.id && state == .online
    }

    func disconnect() {
        wantConnected = false
        reconnectWork?.cancel()
        offlineWork?.cancel()
        stopKeepAlive()
        generation += 1
        finish(ack: false, reason: "연결이 끊겼습니다.")
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = .offline
        boardId = nil
        detail = "오프라인"
        otaStarted = false
        lastHost = ""
        lastSlot = ""
        lastFw = ""
        otaNote = ""
        reconnectDelay = 1
    }

    /// 열린 소켓으로만 보냅니다. 기판이 ack true 를 주기 전에는 성공으로 보지 않습니다.
    func command(_ payload: [String: Any], timeout: TimeInterval = 2) async -> (sent: Bool, ack: Bool, reason: String) {
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
            softDrop("명령을 보내지 못했습니다.")
            return (false, false, "명령을 보내지 못했습니다.")
        }
        return await withCheckedContinuation { continuation in
            waiter = { ack, reason in
                continuation.resume(returning: (true, ack, reason))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.waiter != nil else { return }
                self.finish(ack: false, reason: "C3 가 응답하지 않았습니다. 성공으로 두지 않습니다.")
            }
        }
    }

    /// 슬라이더용: ack 를 기다리지 않고 바로 보냅니다(최신값 덮어쓰기·즉시 반응).
    func fire(_ payload: [String: Any]) async -> Bool {
        guard state == .online, let task else { return false }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return false
        }
        do {
            try await task.send(.string(text))
            return true
        } catch {
            softDrop("명령을 보내지 못했습니다.")
            return false
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        guard webSocketTask === task else { return }
        offlineWork?.cancel()
        reconnectDelay = 1
        state = .online
        detail = lastHost.isEmpty ? "연결됨" : "연결됨 \(lastHost)"
        startKeepAlive()
        listen()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard webSocketTask === task else { return }
        softDrop("C3 연결이 끊겼습니다.")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        if state != .offline || wantConnected {
            softDrop("C3 에 닿지 못했습니다.")
        }
    }

    private func listen() {
        guard let task, state == .online || state == .connecting else { return }
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
                    self.softDrop("C3 연결이 끊겼습니다.")
                }
            }
        }
    }

    private func ingest(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let mac = object["wifiMac"] as? String, !mac.isEmpty { wifiMac = mac }
        if let mac = object["apMac"] as? String, !mac.isEmpty { apMac = mac }
        if let host = object["host"] as? String, !host.isEmpty {
            lastHost = host
            detail = state == .online ? "연결됨 \(host)" : detail
        }
        if let slot = object["slot"] as? String, !slot.isEmpty { lastSlot = slot }
        if let fw = object["fw"] as? String, !fw.isEmpty { lastFw = fw }
        if let paired = object["paired"] as? String, !paired.isEmpty {
            pairedName = paired
        }
        maybeStartOta()
        let lightRows = (object["lights"] as? [[String: Any]]) ?? (object["gimbals"] as? [[String: Any]])
        if let rows = lightRows {
            gimbals = rows.compactMap { row in
                let id = (row["id"] as? String) ?? ""
                let name = (row["name"] as? String) ?? ""
                guard !name.isEmpty else { return nil }
                let index = row["index"] as? Int
                return C3Gimbal(id: id.isEmpty ? name : id, name: name, index: index)
            }
        }
        if let saved = object["savedLightsList"] as? [[String: Any]] {
            savedLights = saved.compactMap { row in
                let name = (row["name"] as? String) ?? ""
                guard !name.isEmpty else { return nil }
                let index = (row["index"] as? Int) ?? 0
                let id = (row["id"] as? String) ?? "\(index)"
                return SavedLight(id: id.isEmpty ? "\(index)-\(name)" : id, name: name, index: index)
            }
        }
        if object["pong"] as? Bool == true { return }
        if let ack = object["ack"] as? Bool {
            let reason = (object["reason"] as? String) ?? (ack ? "응답을 받았습니다." : "기판이 실패라고 답했습니다.")
            // 연결 hello 의 ack:false 는 대기 중인 명령 응답이 아닙니다. 가로채면 팬·틸트가 조용히 실패합니다.
            if reason.contains("연결만") { return }
            finish(ack: ack, reason: reason)
        }
    }

    private func finish(ack: Bool, reason: String) {
        let pending = waiter
        waiter = nil
        pending?(ack, reason)
    }

    /// 잠깐 끊겨도 바로 오프라인으로 깜빡이지 않습니다. 유지하면서 다시 붙습니다.
    private func softDrop(_ text: String) {
        stopKeepAlive()
        finish(ack: false, reason: text)
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        guard wantConnected, let board = lastBoard else {
            state = .offline
            detail = text
            return
        }
        state = .connecting
        detail = "다시 붙는 중… \(board.socketHost)"
        // 짧은 끊김은 UI 오프라인으로 안 보입니다. 4초 넘기면 그때 오프라인.
        offlineWork?.cancel()
        let markOffline = DispatchWorkItem { [weak self] in
            guard let self, self.wantConnected, self.state != .online else { return }
            self.state = .offline
            self.detail = text
        }
        offlineWork = markOffline
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: markOffline)
        scheduleReconnect(board)
    }

    private func scheduleReconnect(_ board: C3BoardRecord) {
        reconnectWork?.cancel()
        let delay = min(reconnectDelay, 8)
        reconnectDelay = min(reconnectDelay * 1.6, 8)
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantConnected, self.generation == token else { return }
            guard self.state != .online else { return }
            self.open(board, clearLists: false)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startKeepAlive() {
        stopKeepAlive()
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.ping()
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    private func ping() {
        guard state == .online, let task else { return }
        task.sendPing { [weak self] error in
            DispatchQueue.main.async {
                guard let self, error != nil else { return }
                self.softDrop("C3 응답이 없어 다시 붙습니다.")
            }
        }
        // waiter 없이 보냅니다. command() 대기와 겹치면 팬·틸트가 멈춥니다.
        if let data = try? JSONSerialization.data(withJSONObject: ["op": "ping"]),
           let text = String(data: data, encoding: .utf8) {
            Task { try? await task.send(.string(text)) }
        }
    }

    private func maybeStartOta() {
        guard state == .online, !otaStarted else { return }
        guard !lastHost.isEmpty, !lastSlot.isEmpty else { return }
        otaStarted = true
        let host = lastHost
        let slot = lastSlot
        let fw = lastFw
        let board = lastBoard
        Task { @MainActor in
            otaNote = "펌웨어 확인 중…"
            let outcome = await BoardOta.ensureOnConnect(host: host, slot: slot, reportedFw: fw)
            switch outcome {
            case .skipped(let text), .failed(let text):
                otaNote = text
            case .updated(let text):
                otaNote = text
                detail = "OTA 반영 후 다시 붙는 중… \(text)"
                // 보드 재부팅 뒤 「지금 연결」을 다시 누르지 않게 자동 재연결합니다.
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if let board { connect(board) }
            }
        }
    }
}
