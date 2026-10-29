import Foundation

/// 고프로 랩스 연결 QR입니다.
/// 2025년 8월 랩스 문서는 이름을 `*JOIN="이름:비밀번호"`로 먼저 저장하고,
/// 그 다음에 `!W`가 이미 저장된 망에 붙는다고 적습니다. 무선 켜기는 `oW1`입니다.
/// 따옴표는 ASCII 34입니다. 비밀번호는 코드에 적지 않습니다.
enum GoProLabsJoin {
    /// 첫 코드입니다. 저장만 합니다. 접속 동작은 넣지 않습니다.
    static func storeCommand(ssid: String, password: String) -> String? {
        let name = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password
        guard !name.isEmpty, !pass.isEmpty else { return nil }
        guard !name.contains(":"), !name.contains("\""), !pass.contains("\""),
              !name.contains("\\"), !pass.contains("\\") else { return nil }
        let quote = "\u{22}"
        return "*JOIN=\(quote)\(name):\(pass)\(quote)"
    }

    /// 접속 코드입니다. 카메라 메뉴는 쓰지 않습니다.
    /// `!N` 대기는 화면을 비웁니다. 빌드 13이 그래서 joining network 뒤에 빈 화면으로 남았습니다.
    /// 주소 명령은 여기 넣지 않습니다. 접속 글자와 겹치면 숫자가 안 남습니다.
    static let joinCommand = "oW1*OPNW=1$COHN=1!W"

    /// 주소 코드입니다. 접속 글자가 끝난 뒤에 바로 보여 줍니다. 초를 세지 않습니다.
    /// `$ADDR=9`는 지금 주소를 9초 보여 주고, `$DSPL=9`는 그 글자가 1초 만에 사라지지 않게 합니다.
    /// 표시 길이를 두 번 적는 것은 같은 설정입니다. 문장이 짧으면 빌드 결과에서 빠질 수 있습니다.
    static let addressCommand = "$DSPL=9$DSPL=9$ADDR=9"

    /// 비밀번호 형식이 아니면 바로 이 문장을 씁니다. 와이파이 비밀번호는 8자에서 63자입니다.
    static func passwordMessage(_ password: String) -> String? {
        if password.isEmpty || password.count < 8 || password.count > 63 {
            return "비밀번호가 틀렸습니다."
        }
        if password.contains("\"") || password.contains("\\") {
            return "비밀번호가 틀렸습니다."
        }
        if password.unicodeScalars.contains(where: { $0.value < 32 || $0.value > 126 }) {
            return "비밀번호가 틀렸습니다."
        }
        return nil
    }

    /// 카메라 화면에 적힌 글에서 IPv4 주소만 꺼냅니다.
    static func hostAddress(from text: String) -> String? {
        guard let range = text.range(of: #"(?:\d{1,3}\.){3}\d{1,3}"#, options: .regularExpression) else { return nil }
        let host = String(text[range])
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        guard parts.allSatisfy({ part in
            guard let number = Int(part), (0...255).contains(number) else { return false }
            return String(number) == part
        }) else { return nil }
        return host
    }

    /// 읽어 들인 QR에서 저장 명령만 꺼냅니다. 접속 동작이 같이 있으면 뺍니다.
    static func storedCommand(from payload: String) -> String? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: #"[*$]JOIN="[^"]+""#, options: .regularExpression) else { return nil }
        let piece = text[range]
        guard let open = piece.firstIndex(of: "\""), let close = piece.lastIndex(of: "\""), open < close else { return nil }
        let inner = piece[piece.index(after: open)..<close]
        let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return storeCommand(ssid: String(parts[0]), password: String(parts[1]))
    }

    /// 화면에 보여줄 때 비밀번호 자리는 가립니다.
    static func masked(_ command: String) -> String {
        guard let open = command.firstIndex(of: "\""), let close = command.lastIndex(of: "\""), open < close else {
            return command
        }
        let inner = command[command.index(after: open)..<close]
        let ssid = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let head = command[..<command.index(after: open)]
        let tail = command[close...]
        return "\(head)\(ssid):\u{2022}\u{2022}\u{2022}\u{2022}\(tail)"
    }
}
