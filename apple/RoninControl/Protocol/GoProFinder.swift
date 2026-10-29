import Darwin
import Foundation
import Network

/// 같은 와이파이에서 Open GoPro가 알린 카메라입니다. 찾지 못한 카메라는 만들지 않습니다.
struct FoundGoPro: Identifiable, Equatable, Sendable {
    var id: String { service }
    /// 카메라가 알린 서비스 이름입니다.
    var service: String
    /// 목록에 보여줄 이름입니다. 카메라가 알려 준 값만 씁니다.
    var name: String
    var host: String
    var port: Int
}

/// `_gopro-web._tcp` 알림을 듣고, `/gopro/version` 이 대답한 카메라만 목록에 남깁니다.
@MainActor
final class GoProFinder: ObservableObject {
    @Published private(set) var found: [FoundGoPro] = []
    @Published private(set) var searching = false
    @Published private(set) var note = "찾기 버튼을 누르면 같은 와이파이의 고프로를 찾습니다."

    private var browser: NWBrowser?
    private var resolvers: [String: ServiceResolver] = [:]
    private var liveServices: Set<String> = []
    private var checks: Set<String> = []

    func start() {
        stop()
        found = []
        liveServices = []
        checks = []
        searching = true
        note = "같은 와이파이에서 고프로 알림을 듣는 중입니다."
        let browser = NWBrowser(for: .bonjour(type: "_gopro-web._tcp", domain: nil), using: .tcp)
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

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.stop() }
        resolvers.removeAll()
        searching = false
    }

    private func apply(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            searching = true
            if found.isEmpty {
                note = "같은 와이파이에서 고프로 알림을 듣는 중입니다."
            }
        case .waiting:
            searching = true
            if found.isEmpty {
                note = "로컬 네트워크 권한이 없으면 고프로를 찾지 못합니다. 설정에서 로컬 네트워크를 허용해 주세요."
            }
        case .failed:
            searching = false
            if found.isEmpty {
                note = "고프로 찾기를 시작하지 못했습니다."
            }
        case .cancelled:
            searching = false
        case .setup:
            break
        @unknown default:
            break
        }
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        var names = Set<String>()
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            names.insert(trimmed)
            if resolvers[trimmed] == nil && !found.contains(where: { $0.service == trimmed }) {
                resolve(name: trimmed, type: type, domain: domain)
            }
        }
        liveServices = names
        found.removeAll { !names.contains($0.service) }
        for key in resolvers.keys where !names.contains(key) {
            resolvers[key]?.stop()
            resolvers[key] = nil
            checks.remove(key)
        }
        if found.isEmpty {
            note = names.isEmpty
                ? "같은 와이파이에서 고프로를 아직 찾지 못했습니다."
                : "고프로 주소를 확인하는 중입니다."
        } else {
            note = "찾은 고프로 \(found.count)대입니다. 등록하면 고프로 · 와이파이로 들어갑니다."
        }
    }

    private func resolve(name: String, type: String, domain: String) {
        let resolver = ServiceResolver(name: name, type: type, domain: domain)
        resolvers[name] = resolver
        resolver.onAddress = { [weak self] host, port in
            Task { @MainActor in
                await self?.confirm(service: name, host: host, port: port)
            }
        }
        resolver.onFail = { [weak self] in
            Task { @MainActor in
                self?.resolvers[name] = nil
            }
        }
        resolver.start()
    }

    /// 알림만으로 목록에 넣지 않습니다. Open GoPro 버전 주소가 대답해야 합니다.
    private func confirm(service: String, host: String, port: Int) async {
        resolvers[service]?.stop()
        resolvers[service] = nil
        guard liveServices.contains(service), !checks.contains(service) else { return }
        guard let url = LocalHTTP.url(host: host, port: port, path: "/gopro/version") else { return }
        checks.insert(service)
        defer { checks.remove(service) }
        guard liveServices.contains(service) else { return }
        guard let (_, text) = try? await LocalHTTP.get(url, timeout: 4) else { return }
        guard text.contains("\"version\"") else { return }
        guard liveServices.contains(service) else { return }
        guard !found.contains(where: { $0.host == host && $0.port == port }) else { return }
        let display = await advertisedName(service: service, host: host, port: port)
        found.append(FoundGoPro(service: service, name: display, host: host, port: port))
        found.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        note = "찾은 고프로 \(found.count)대입니다. 등록하면 고프로 · 와이파이로 들어갑니다."
    }

    /// 카메라 정보에서 이름과 일련번호가 있을 때만 그 글자를 씁니다.
    private func advertisedName(service: String, host: String, port: Int) async -> String {
        guard let url = LocalHTTP.url(host: host, port: port, path: "/gopro/camera/info"),
              let (_, text) = try? await LocalHTTP.get(url, timeout: 3),
              let data = text.data(using: .utf8),
              let info = try? JSONDecoder().decode(GoProAdvertisedName.self, from: data) else {
            return service
        }
        let model = info.modelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let serial = info.serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !model.isEmpty && !serial.isEmpty { return "\(model) \(serial)" }
        if !model.isEmpty { return model }
        if !serial.isEmpty { return serial }
        return service
    }
}

private struct GoProAdvertisedName: Decodable {
    var modelName: String?
    var serialNumber: String?

    enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case serialNumber = "serial_number"
    }
}

/// 서비스 이름을 주소로 바꿉니다. 주소가 없으면 카메라를 만들지 않습니다.
private final class ServiceResolver: NSObject, NetServiceDelegate {
    let service: NetService
    var onAddress: ((String, Int) -> Void)?
    var onFail: (() -> Void)?
    private var finished = false

    init(name: String, type: String, domain: String) {
        let typeText = type.hasSuffix(".") ? type : type + "."
        let domainText = domain.isEmpty ? "local." : (domain.hasSuffix(".") ? domain : domain + ".")
        service = NetService(domain: domainText, type: typeText, name: name)
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
        if let host = Self.ipv4(sender) {
            onAddress?(host, sender.port)
            return
        }
        var host = sender.hostName ?? ""
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else {
            onFail?()
            return
        }
        onAddress?(host, sender.port)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard !finished else { return }
        finished = true
        _ = errorDict
        onFail?()
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
