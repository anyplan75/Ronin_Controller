import CryptoKit
import Foundation
import Security

/// 기기 안의 열쇠고리입니다. 소스와 프로필에는 비밀번호를 넣지 않습니다.
enum FieldSecret {
    static func save(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "RoninControl.ptz",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "RoninControl.ptz",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

/// 같은 망의 ONVIF PTZ 입니다. 브랜드를 모를 때 이 표준으로 팬·틸트·줌을 보냅니다.
enum Onvif {
    struct Found: Identifiable, Equatable {
        var host: String
        var endpoint: String
        var id: String { host }
    }

    struct Door {
        var device: URL
        var media: URL
        var ptz: URL
    }

    static func discover() async -> [Found] {
        var hosts = Set(await multicast())
        hosts.formUnion(await sweep())
        var found: [Found] = []
        for host in hosts.sorted() {
            let door = await open(host: host, endpoint: "")
            found.append(Found(host: host, endpoint: door?.device.absoluteString ?? ""))
        }
        return found
    }

    static func check(host: String, endpoint: String, user: String, password: String) async -> (String, String) {
        guard let door = await open(host: host, endpoint: endpoint, user: user, password: password) else {
            return ("\(host) 에서 ONVIF 응답이 없습니다. 오프라인으로 둡니다.", "")
        }
        let port = door.ptz.port ?? 80
        return ("\(host) ONVIF 가 답했습니다. PTZ \(door.ptz.host ?? host):\(port).", door.device.absoluteString)
    }

    /// 스틱이 누르는 동안 연속으로 움직입니다. 성공 응답이 있을 때만 빈 실패 문장이 아닙니다.
    static func drive(host: String, endpoint: String, user: String, password: String, pan: Double, tilt: Double, zoom: Double) async -> (String, String) {
        guard let token = await profileToken(host: host, endpoint: endpoint, user: user, password: password) else {
            if user.isEmpty {
                return ("\(host) 는 로그인 없이 움직이지 않습니다. 사용자 이름과 비밀번호를 넣은 뒤 다시 추가하세요.", "")
            }
            return ("\(host) 프로필을 읽지 못했습니다. 팬·틸트·줌을 보내지 않았습니다.", "")
        }
        let x = max(-1, min(1, pan))
        let y = max(-1, min(1, tilt))
        let z = max(-1, min(1, zoom))
        let body = """
        <tptz:ContinuousMove xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl"><tptz:ProfileToken>\(xml(token.token))</tptz:ProfileToken><tptz:Velocity><tt:PanTilt x="\(x)" y="\(y)" xmlns:tt="http://www.onvif.org/ver10/schema"/><tt:Zoom x="\(z)" xmlns:tt="http://www.onvif.org/ver10/schema"/></tptz:Velocity></tptz:ContinuousMove>
        """
        let reply = await post(url: token.ptz, user: user, password: password, body: body)
        if reply.ok {
            return ("\(host) 가 조이스틱 명령을 받았습니다.", token.device)
        }
        if reply.fault {
            return ("\(host) 가 조이스틱을 거절했습니다. 움직이지 않은 것으로 둡니다.", token.device)
        }
        return ("\(host) 가 응답하지 않았습니다. 명령을 성공으로 두지 않습니다.", token.device)
    }

    static func stop(host: String, endpoint: String, user: String, password: String) async -> String {
        guard let token = await profileToken(host: host, endpoint: endpoint, user: user, password: password) else {
            return "\(host) 에 멈춤을 보내지 못했습니다."
        }
        let body = """
        <tptz:Stop xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl"><tptz:ProfileToken>\(xml(token.token))</tptz:ProfileToken><tptz:PanTilt>true</tptz:PanTilt><tptz:Zoom>true</tptz:Zoom></tptz:Stop>
        """
        let reply = await post(url: token.ptz, user: user, password: password, body: body)
        if reply.ok { return "\(host) 가 멈춤을 받았습니다." }
        return "\(host) 가 멈춤에 답하지 않았습니다."
    }

    /// 슬라이더의 절대 각도입니다. 카메라가 받았을 때만 성공 문장입니다.
    static func move(host: String, endpoint: String, user: String, password: String, pan: Double, tilt: Double, zoom: Double) async -> (String, String) {
        guard let token = await profileToken(host: host, endpoint: endpoint, user: user, password: password) else {
            return ("\(host) 프로필을 읽지 못했습니다. 팬·틸트·줌을 보내지 않았습니다.", "")
        }
        let x = max(-1, min(1, pan / 180))
        let y = max(-1, min(1, tilt / 45))
        let z = max(0, min(1, zoom))
        let body = """
        <tptz:AbsoluteMove xmlns:tptz="http://www.onvif.org/ver20/ptz/wsdl"><tptz:ProfileToken>\(xml(token.token))</tptz:ProfileToken><tptz:Position><tt:PanTilt x="\(x)" y="\(y)" xmlns:tt="http://www.onvif.org/ver10/schema"/><tt:Zoom x="\(z)" xmlns:tt="http://www.onvif.org/ver10/schema"/></tptz:Position></tptz:AbsoluteMove>
        """
        let reply = await post(url: token.ptz, user: user, password: password, body: body)
        if reply.fault {
            return ("\(host) 가 그 각도를 거절했습니다. 움직이지 않은 것으로 둡니다.", token.device)
        }
        if reply.ok {
            return ("\(host) 가 팬 \(Int(pan))°, 틸트 \(Int(tilt))°, 줌 \(Int(z * 100))% 명령을 받았습니다.", token.device)
        }
        return ("\(host) 가 응답하지 않았습니다. 명령을 성공으로 두지 않습니다.", token.device)
    }

    private struct Profile {
        var token: String
        var ptz: URL
        var device: String
    }

    private static let cacheLock = NSLock()
    private static var memory: [String: (Profile, Date)] = [:]

    private static func profileToken(host: String, endpoint: String, user: String, password: String) async -> Profile? {
        let key = "\(host)|\(endpoint)|\(user)"
        cacheLock.lock()
        if let saved = memory[key], Date().timeIntervalSince(saved.1) < 20 {
            cacheLock.unlock()
            return saved.0
        }
        cacheLock.unlock()
        guard let door = await open(host: host, endpoint: endpoint, user: user, password: password) else { return nil }
        let body = "<trt:GetProfiles xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\"/>"
        let reply = await post(url: door.media, user: user, password: password, body: body)
        guard reply.ok, let token = firstToken(reply.text) else { return nil }
        let profile = Profile(token: token, ptz: door.ptz, device: door.device.absoluteString)
        cacheLock.lock()
        memory[key] = (profile, Date())
        cacheLock.unlock()
        return profile
    }

    static func open(host: String, endpoint: String, user: String = "", password: String = "") async -> Door? {
        var candidates: [URL] = []
        if let saved = URL(string: endpoint), !endpoint.isEmpty { candidates.append(saved) }
        candidates.append(contentsOf: await discoveredDoors(host: host))
        candidates.append(contentsOf: [
            URL(string: "http://\(host):2000/onvif/device_service"),
            URL(string: "http://\(host)/onvif/device_service"),
            URL(string: "http://\(host):8080/onvif/device_service"),
        ].compactMap { $0 })
        var seen = Set<String>()
        let body = "<tds:GetCapabilities xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\"><tds:Category>All</tds:Category></tds:GetCapabilities>"
        for url in candidates {
            let key = url.absoluteString
            if seen.contains(key) { continue }
            seen.insert(key)
            var reply = await post(url: url, user: "", password: "", body: body)
            if !reply.ok, !user.isEmpty {
                reply = await post(url: url, user: user, password: password, body: body)
            }
            guard reply.ok else { continue }
            let media = firstURL(in: reply.text, keys: ["Media"]) ?? URL(string: "http://\(host):2000/onvif/Media")
            let ptz = firstURL(in: reply.text, keys: ["PTZ"]) ?? URL(string: "http://\(host):2000/onvif/PTZ")
            guard let media, let ptz else { continue }
            return Door(device: url, media: media, ptz: ptz)
        }
        return nil
    }

    private static func discoveredDoors(host: String) async -> [URL] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: unicastXAddrs(host))
            }
        }
    }

    private static func multicast() async -> Set<String> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: multicastProbe())
            }
        }
    }

    private static func multicastProbe() -> Set<String> {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 { return [] }
        defer { close(fd) }
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr.s_addr = in_addr_t(0)
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 { return [] }
        var wait = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let message = Data(probeXML.utf8)
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = UInt16(3702).bigEndian
        dest.sin_addr.s_addr = inet_addr("239.255.255.250")
        let sent = message.withUnsafeBytes { buffer in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                    sendto(fd, buffer.baseAddress, buffer.count, 0, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { return [] }
        var hosts = Set<String>()
        var storage = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<8 {
            let count = recv(fd, &storage, storage.count, 0)
            if count <= 0 { break }
            let text = String(decoding: storage.prefix(count), as: UTF8.self)
            hosts.formUnion(addresses(in: text))
        }
        return hosts
    }

    private static func unicastXAddrs(_ host: String) -> [URL] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 { return [] }
        defer { close(fd) }
        var wait = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let message = Data(probeXML.utf8)
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = UInt16(3702).bigEndian
        dest.sin_addr.s_addr = inet_addr(host)
        let sent = message.withUnsafeBytes { buffer in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                    sendto(fd, buffer.baseAddress, buffer.count, 0, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { return [] }
        var storage = [UInt8](repeating: 0, count: 8192)
        let count = recv(fd, &storage, storage.count, 0)
        if count <= 0 { return [] }
        let text = String(decoding: storage.prefix(count), as: UTF8.self)
        return xaddrURLs(in: text)
    }

    private static func sweep() async -> Set<String> {
        var found = Set<String>()
        let hosts = (200...230).map { "192.168.10.\($0)" }.filter { !["192.168.10.150", "192.168.10.151", "192.168.10.152"].contains($0) }
        for chunk in stride(from: 0, to: hosts.count, by: 32) {
            let slice = hosts[chunk..<min(chunk + 32, hosts.count)]
            await withTaskGroup(of: String?.self) { group in
                for host in slice {
                    group.addTask {
                        let paths = [
                            "http://\(host):2000/onvif/device_service",
                            "http://\(host)/onvif/device_service",
                        ]
                        for path in paths {
                            guard let url = URL(string: path) else { continue }
                            var request = URLRequest(url: url, timeoutInterval: 0.45)
                            request.httpMethod = "POST"
                            request.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
                            request.httpBody = Data(envelope(user: "", password: "", body: "<tds:GetSystemDateAndTime xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\"/>").utf8)
                            do {
                                let (_, response) = try await URLSession.shared.data(for: request)
                                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                                if code == 401 || (200..<300).contains(code) { return host }
                            } catch {
                                continue
                            }
                        }
                        return nil
                    }
                }
                for await host in group {
                    if let host { found.insert(host) }
                }
            }
        }
        return found
    }

    private static var probeXML: String {
        let id = UUID().uuidString
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header><w:MessageID>uuid:\(id)</w:MessageID><w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>
        """
    }

    private struct Reply {
        var ok: Bool
        var fault: Bool
        var text: String
    }

    private static func post(url: URL, user: String, password: String, body: String) async -> Reply {
        await send(url: url, user: user, password: password, body: body, authorization: nil, attempt: 0)
    }

    private static func send(url: URL, user: String, password: String, body: String, authorization: String?, attempt: Int) async -> Reply {
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let soapUser = attempt >= 3 ? user : ""
        request.httpBody = Data(envelope(user: soapUser, password: attempt >= 3 ? password : "", body: body).utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            if code == 401, attempt < 3, !user.isEmpty {
                let challenge = authenticateHeader(http)
                if attempt == 0, let digest = digestHeader(url: url, user: user, password: password, challenge: challenge) {
                    return await send(url: url, user: user, password: password, body: body, authorization: digest, attempt: 1)
                }
                if attempt < 2 {
                    let token = Data("\(user):\(password)".utf8).base64EncodedString()
                    return await send(url: url, user: user, password: password, body: body, authorization: "Basic \(token)", attempt: 2)
                }
                return await send(url: url, user: user, password: password, body: body, authorization: nil, attempt: 3)
            }
            let fault = text.localizedCaseInsensitiveContains("Fault")
            return Reply(ok: (200..<300).contains(code) && !fault, fault: fault || code == 401, text: text)
        } catch {
            return Reply(ok: false, fault: false, text: "")
        }
    }

    private static func authenticateHeader(_ http: HTTPURLResponse?) -> String {
        guard let http else { return "" }
        for (key, value) in http.allHeaderFields {
            if String(describing: key).lowercased() == "www-authenticate" {
                return String(describing: value)
            }
        }
        return http.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
    }

    private static func digestHeader(url: URL, user: String, password: String, challenge: String) -> String? {
        let lower = challenge.lowercased()
        guard lower.contains("digest") else { return nil }
        func field(_ name: String) -> String {
            let pattern = "\(name)=\"?([^\",]+)\"?"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return "" }
            let range = NSRange(challenge.startIndex..<challenge.endIndex, in: challenge)
            guard let match = regex.firstMatch(in: challenge, range: range),
                  let slice = Range(match.range(at: 1), in: challenge) else { return "" }
            return String(challenge[slice])
        }
        let realm = field("realm")
        let nonce = field("nonce")
        guard !realm.isEmpty, !nonce.isEmpty else { return nil }
        let qop = field("qop")
        let opaque = field("opaque")
        let uri = url.path.isEmpty ? "/" : url.path
        let ha1 = md5("\(user):\(realm):\(password)")
        let ha2 = md5("POST:\(uri)")
        let cnonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        let nc = "00000001"
        let response: String
        if qop.isEmpty {
            response = md5("\(ha1):\(nonce):\(ha2)")
        } else {
            response = md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
        }
        var header = "Digest username=\"\(user)\", realm=\"\(realm)\", nonce=\"\(nonce)\", uri=\"\(uri)\", algorithm=MD5, response=\"\(response)\""
        if !qop.isEmpty { header += ", qop=auth, nc=\(nc), cnonce=\"\(cnonce)\"" }
        if !opaque.isEmpty { header += ", opaque=\"\(opaque)\"" }
        return header
    }

    private static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func xaddrURLs(in text: String) -> [URL] {
        let pattern = #"http://\d{1,3}(?:\.\d{1,3}){3}:\d+/[A-Za-z0-9_./-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let slice = Range(match.range, in: text) else { return nil }
            return URL(string: String(text[slice]))
        }
    }

    private static func envelope(user: String, password: String, body: String) -> String {
        let header = security(user: user, password: password)
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\">\(header)<s:Body>\(body)</s:Body></s:Envelope>"
    }

    private static func security(user: String, password: String) -> String {
        guard !user.isEmpty else { return "" }
        var nonce = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce)
        let created = ISO8601DateFormatter().string(from: Date())
        var material = nonce
        material.append(contentsOf: created.utf8)
        material.append(contentsOf: password.utf8)
        let digest = Data(Insecure.SHA1.hash(data: material)).base64EncodedString()
        let nonceText = Data(nonce).base64EncodedString()
        let digestType = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0" + "#PasswordDigest"
        let nonceType = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0" + "#Base64Binary"
        return "<s:Header><wsse:Security s:mustUnderstand=\"1\" xmlns:wsse=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd\" xmlns:wsu=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd\"><wsse:UsernameToken><wsse:Username>\(xml(user))</wsse:Username><wsse:Password Type=\"\(digestType)\">\(digest)</wsse:Password><wsse:Nonce EncodingType=\"\(nonceType)\">\(nonceText)</wsse:Nonce><wsu:Created>\(created)</wsu:Created></wsse:UsernameToken></wsse:Security></s:Header>"
    }

    private static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func addresses(in text: String) -> Set<String> {
        var found = Set<String>()
        let pattern = #"http://(\d{1,3}(?:\.\d{1,3}){3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let slice = Range(match.range(at: 1), in: text) else { continue }
            let host = String(text[slice])
            if host.hasPrefix("192.168.10.") { found.insert(host) }
        }
        return found
    }

    private static func firstURL(in text: String, keys: [String]) -> URL? {
        for key in keys {
            let pattern = "\(key)[\\s\\S]{0,180}?(http://[^<\\s]+)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let slice = Range(match.range(at: 1), in: text) else { continue }
            if let url = URL(string: String(text[slice])) { return url }
        }
        return nil
    }

    private static func firstToken(_ text: String) -> String? {
        let pattern = #"token="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let slice = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[slice])
    }
}
