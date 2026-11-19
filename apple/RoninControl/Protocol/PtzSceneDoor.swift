import Foundation
import Network

/// 컴패니언이 장면 번호를 부르게 하는 문입니다. 비밀번호는 이 문으로 나가지 않습니다.
final class PtzSceneDoor {
    static let port: UInt16 = 8787
    private var listener: NWListener?
    var onRequest: ((String, String, String) async -> String)?

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.take(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            listener = nil
        }
    }

    private func take(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let head = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = head.split(separator: " ")
            let method = parts.first.map(String.init) ?? "GET"
            let target = parts.dropFirst().first.map(String.init) ?? "/"
            let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            Task {
                let reply = await self?.onRequest?(method, target, body) ?? "{\"ok\":false}"
                let bytes = Data(reply.utf8)
                let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
                var packet = Data(raw.utf8)
                packet.append(bytes)
                connection.send(content: packet, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }
}
