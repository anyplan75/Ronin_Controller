import SwiftUI

struct RoninDeck: View {
    @EnvironmentObject private var studio: Studio
    let deviceId: UUID

    @State private var jogSpeed = 30.0
    @State private var yaw = 0.0
    @State private var roll = 0.0
    @State private var pitch = 0.0
    @State private var seconds = 1.5
    @State private var absolute = true
    @State private var shotScale = 1.0
    @State private var speedYaw = 0.0
    @State private var speedRoll = 0.0
    @State private var speedPitch = 0.0
    @State private var dial = 800.0
    @State private var sonySSID = ""
    @State private var sonyPassword = ""
    @State private var sonyHost = "192.168.122.1"

    var body: some View {
        if let device = studio.profile.devices.first(where: { $0.id == deviceId }) {
            deck(device)
        }
    }

    @ViewBuilder private func deck(_ device: DeviceRecord) -> some View {
        Section("이 기판 상태") {
            ApiBadge(title: "실사용 · CAN", tint: .green)
            Button("상태 다시 읽기") { Task { await studio.refresh() } }
            statusText(device)
            Text("cam_recording 은 기판이 마지막으로 보낸 녹화 명령입니다. 짐벌이 카메라 상태를 확인해 준 값은 아닙니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("이 기판만 바로 녹화") {
            Text("함께 시작과 다릅니다. CAN 명령을 지금 보냅니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("녹화 시작") { Task { await studio.ronin(device, path: "/record", query: ["action": "start"]) } }
                Button("녹화 정지") { Task { await studio.ronin(device, path: "/record", query: ["action": "stop"]) } }
                Button("토글") { Task { await studio.ronin(device, path: "/record", query: ["action": "toggle"]) } }
                Button("셔터") { Task { await studio.ronin(device, path: "/photo") } }
            }
            Text("셔터는 CAN 0x0001 입니다. 소니 와이파이 녹화 함수는 기판에 있지만 웹 주소로는 연결되어 있지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("기판에 고정된 자세") {
            Text("사용자 프리셋이 아닙니다. 기판 프로그램에 적힌 세 자세입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("정면") { Task { await studio.ronin(device, path: "/preset/front") } }
                Button("아래") { Task { await studio.ronin(device, path: "/preset/down") } }
                Button("위") { Task { await studio.ronin(device, path: "/preset/up") } }
                Button("중앙") { Task { await studio.ronin(device, path: "/recenter") } }
                Button("정지") { Task { await studio.ronin(device, path: "/stop") } }
            }
        }
        Section("촬영 동작") {
            HStack {
                Text("시간 배율")
                Slider(value: $shotScale, in: 0.25...4)
                Text(String(format: "%.2f", shotScale)).frame(width: 48)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)]) {
                ForEach(studio.shotNames, id: \.self) { name in
                    Button(RoninCatalog.title(name)) {
                        Task {
                            await studio.ronin(device, path: "/shot/\(name)", query: ["t": String(format: "%.2f", shotScale)])
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        Section("조그 (누르는 동안)") {
            Stepper("속도 \(Int(jogSpeed))", value: $jogSpeed, in: 1...180, step: 1)
            VStack {
                HoldButton(title: "피치 위", press: { sendJog(device, "/jog/pitch/up") }, release: { stop(device) })
                HStack {
                    HoldButton(title: "요 왼쪽", press: { sendJog(device, "/jog/yaw/left") }, release: { stop(device) })
                    HoldButton(title: "요 오른쪽", press: { sendJog(device, "/jog/yaw/right") }, release: { stop(device) })
                }
                HoldButton(title: "피치 아래", press: { sendJog(device, "/jog/pitch/down") }, release: { stop(device) })
                HStack {
                    HoldButton(title: "롤 왼쪽", press: { sendJog(device, "/jog/roll/left") }, release: { stop(device) })
                    HoldButton(title: "롤 오른쪽", press: { sendJog(device, "/jog/roll/right") }, release: { stop(device) })
                }
            }
        }
        Section("축 속도") {
            numberField("요", value: $speedYaw)
            numberField("롤", value: $speedRoll)
            numberField("피치", value: $speedPitch)
            Button("속도 보내기") {
                Task {
                    await studio.ronin(device, path: "/speed", query: [
                        "yaw": num(speedYaw), "roll": num(speedRoll), "pitch": num(speedPitch),
                    ])
                }
            }
        }
        Section("위치 이동") {
            Toggle("절대 각도", isOn: $absolute)
            numberField("요", value: $yaw)
            numberField("롤", value: $roll)
            numberField("피치", value: $pitch)
            numberField("초", value: $seconds)
            Button(absolute ? "절대 이동" : "상대 이동") {
                Task {
                    await studio.ronin(device, path: absolute ? "/move" : "/relative", query: [
                        "yaw": num(yaw), "roll": num(roll), "pitch": num(pitch), "time": num(seconds),
                    ])
                }
            }
        }
        Section("줌 · 포커스 모터") {
            Text("누르는 동안 다이얼이 돌고, 떼면 멈춥니다. 초점 거리 숫자를 보내는 주소는 없습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper("다이얼 \(Int(dial))", value: $dial, in: 1...2000, step: 50)
            HStack {
                HoldButton(title: "줌 인", press: { motor(device, "/zoom/in") }, release: { motorStop(device, "/zoom/stop") })
                HoldButton(title: "줌 아웃", press: { motor(device, "/zoom/out") }, release: { motorStop(device, "/zoom/stop") })
            }
            HStack {
                HoldButton(title: "포커스 인", press: { motor(device, "/focus/in") }, release: { motorStop(device, "/focus/stop") })
                HoldButton(title: "포커스 아웃", press: { motor(device, "/focus/out") }, release: { motorStop(device, "/focus/stop") })
            }
            HStack {
                HoldButton(title: "모터 인", press: { motor(device, "/motor/in") }, release: { motorStop(device, "/motor/stop") })
                HoldButton(title: "모터 아웃", press: { motor(device, "/motor/out") }, release: { motorStop(device, "/motor/stop") })
            }
        }
        Section("소니 와이파이") {
            ApiBadge(title: "연결만 실사용", tint: .blue)
            TextField("와이파이 이름", text: $sonySSID)
            SecureField("비밀번호", text: $sonyPassword)
            TextField("카메라 주소", text: $sonyHost)
            Button("기판에 연결 저장") {
                Task { await studio.sonyConnect(device, ssid: sonySSID, password: sonyPassword, host: sonyHost) }
            }
            Button("소니 상태") { Task { await studio.ronin(device, path: "/sony/status") } }
            Text("비밀번호는 이 앱 프로필에 저장하지 않습니다. 기판에만 전달합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("기타") {
            Button("CAN 듣기 30초") {
                Task { await studio.ronin(device, path: "/can/listen", query: ["sec": "30"]) }
            }
            Text("시리얼 모니터에서 확인하는 기능입니다. 앱 화면에 짐벌 버튼 값이 쌓이지는 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func statusText(_ device: DeviceRecord) -> some View {
        if let status = studio.roninLive[device.id] {
            Text("주소 \(status.ip ?? "-")  랜 \(status.ethLink == true ? "연결" : "끊김")  CAN \(status.twai ?? "-")")
            Text(String(format: "요 %.1f  롤 %.1f  피치 %.1f  자세 %@", status.yaw ?? 0, status.roll ?? 0, status.pitch ?? 0, status.attitudeValid == true ? "유효" : "없음"))
            Text("녹화 명령 \(status.camRecording == true ? "시작" : "정지")  동기 \(status.syncResult ?? "-")  샷 \(status.shot ?? "-")")
            Text("소니 와이파이 \(status.sonyWifi == true ? "연결" : "끊김")  소니 녹화표시 \(status.sonyRecording == true ? "켜짐" : "꺼짐")")
            if let error = status.sonyError, !error.isEmpty {
                Text(error).foregroundStyle(.orange)
            }
        } else {
            Text("아직 상태를 읽지 못했습니다.")
        }
    }

    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 36, alignment: .leading)
            TextField(title, value: value, format: .number)
        }
    }

    private func num(_ value: Double) -> String { String(format: "%.2f", value) }

    private func sendJog(_ device: DeviceRecord, _ path: String) {
        Task { await studio.ronin(device, path: path, query: ["speed": num(jogSpeed)]) }
    }

    private func stop(_ device: DeviceRecord) {
        Task { await studio.ronin(device, path: "/stop") }
    }

    private func motor(_ device: DeviceRecord, _ path: String) {
        Task { await studio.ronin(device, path: path, query: ["speed": String(Int(dial))]) }
    }

    private func motorStop(_ device: DeviceRecord, _ path: String) {
        Task { await studio.ronin(device, path: path) }
    }
}
