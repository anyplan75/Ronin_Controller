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

    /// 두 번째 코드입니다. 카메라 메뉴는 쓰지 않습니다.
    /// 2025년 8월 랩스 기록: `$ADDR=초`는 지금 주소를 그 초만큼 카메라 화면에 남깁니다.
    /// `$DSPL=9`는 안내 글이 1초 만에 사라지지 않게 9초로 늘립니다. 9초가 최대입니다.
    /// `!8N`은 켜진 채로 8초를 쉽니다. `!10N`부터는 카메라가 잠들어 방금 붙은 망이 끊깁니다.
    /// 빌드 12의 `oW1!W*OPNW=1$COHN=1$ADDR=8`은 접속과 동시에 주소를 띄워서,
    /// 카메라가 보여 주는 joining network 화면에 가려진 채 끝났습니다.
    /// 그래서 접속(`!W`) 다음에 8초를 두 번 기다리고, 그 뒤에 주소를 9초씩 세 번 보여 줍니다.
    static let joinCommand = "oW1*OPNW=1$COHN=1!W!8N!8N$DSPL=9$ADDR=9!2N$ADDR=9!2N$ADDR=9"

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
