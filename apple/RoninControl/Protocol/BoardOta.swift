import Foundation

/// C3·S3 보드 와이파이 OTA. USB는 비상만. 연결되면 `/version` 을 보고 다르면 `/update` 로 올립니다.
enum BoardOta {
    /// 앱에 묶인 펌웨어 판본. 보드 `fw` 와 같으면 올리지 않습니다.
    static let expectedFw = "1.0.47"

    enum Outcome: Equatable {
        case skipped(String)
        case updated(String)
        case failed(String)
    }

    /// 슬롯별 묶인 bin 이름입니다. `RoninControl/Firmware/` 아래에 둡니다.
    static func resourceName(slot: String) -> String? {
        switch slot {
        case "oled", "rs2": return "firmware-c3-oled"
        case "rmsid", "sc": return "firmware-c3-rmsid"
        case "s3", "light": return "firmware-s3-light"
        default: return nil
        }
    }

    static func readVersion(host: String) async -> String? {
        guard let url = LocalHTTP.url(host: host, port: 80, path: "/version") else { return nil }
        do {
            let (_, text) = try await LocalHTTP.get(url, timeout: 4)
            guard let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let fw = obj["fw"] as? String else { return nil }
            return fw
        } catch {
            return nil
        }
    }

    static func firmwareURL(slot: String) -> URL? {
        guard let name = resourceName(slot: slot) else { return nil }
        if let bundled = Bundle.main.url(forResource: name, withExtension: "bin") {
            return bundled
        }
        #if os(macOS)
        // 맥 개발용: 저장소 빌드 산출물을 찾습니다.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [String]
        switch slot {
        case "oled", "rs2":
            candidates = ["Dev/Ronin_Controller/esp32-c3/.pio/build/c3-oled/firmware.bin"]
        case "rmsid", "sc":
            candidates = ["Dev/Ronin_Controller/esp32-c3/.pio/build/c3-rmsid/firmware.bin"]
        case "s3", "light":
            candidates = ["Dev/Ronin_Controller/esp32-c3/.pio/build/s3-light/firmware.bin"]
        default:
            candidates = []
        }
        for rel in candidates {
            let url = home.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        #endif
        return nil
    }

    static func upload(host: String, file: URL) async -> Outcome {
        guard let url = LocalHTTP.url(host: host, port: 80, path: "/update") else {
            return .failed("OTA 주소를 만들지 못했습니다.")
        }
        guard let bodyFile = try? Data(contentsOf: file) else {
            return .failed("펌웨어 파일을 읽지 못했습니다.")
        }
        let boundary = "RoninOTA\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"update\"; filename=\"firmware.bin\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(bodyFile)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""
            if code == 200, text.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" {
                return .updated("와이파이 OTA 로 \(file.lastPathComponent) 를 올렸습니다.")
            }
            return .failed("OTA HTTP \(code) \(text)")
        } catch {
            return .failed("OTA 전송 실패: \(error.localizedDescription)")
        }
    }

    /// 연결 직후 호출. 판본이 같으면 건너뛰고, 다르면 슬롯 bin 을 올립니다.
    static func ensureOnConnect(host: String, slot: String, reportedFw: String) async -> Outcome {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty else { return .failed("보드 주소가 없습니다.") }
        let current = reportedFw.isEmpty ? await readVersion(host: cleanHost) : reportedFw
        if let current, current == expectedFw {
            return .skipped("펌웨어 \(current) 이미 최신입니다.")
        }
        guard let file = firmwareURL(slot: slot) else {
            return .failed("슬롯 \(slot) 용 펌웨어 bin 이 앱에 없습니다.")
        }
        let result = await upload(host: cleanHost, file: file)
        if case .updated = result {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if let after = await readVersion(host: cleanHost), after == expectedFw {
                return .updated("OTA 후 fw \(after) 확인.")
            }
            return .updated("OTA 전송은 끝났습니다. 재연결 후 fw 를 확인하세요.")
        }
        return result
    }
}
