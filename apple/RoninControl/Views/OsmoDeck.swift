import SwiftUI

struct OsmoDeck: View {
    @EnvironmentObject private var studio: Studio
    @ObservedObject var radio: OsmoRadio
    let deviceId: UUID
    @State private var mode = 0x01

    private var device: DeviceRecord? {
        studio.profile.devices.first { $0.id == deviceId }
    }

    var body: some View {
        if let device {
            if device.kind == .osmoNoAPI {
                Section("제어 불가") {
                    ApiBadge(title: "API 없음", tint: .orange)
                    Text(Honest.noAPI)
                }
            } else {
                controls(device)
            }
        }
    }

    @ViewBuilder private func controls(_ device: DeviceRecord) -> some View {
        Section("읽기") {
            ApiBadge(title: radio.isReady(device.id) ? "세션 유지" : "연결 전", tint: radio.isReady(device.id) ? .green : .orange)
            if let live = radio.live[device.id] {
                Text(live.phase)
                Text("모드 \(live.mode.map(OsmoCatalog.modeName) ?? "-")  상태 \(live.status.map(OsmoCatalog.statusName) ?? "-")")
                Text("해상도 \(live.resolution.map(OsmoCatalog.resolutionName) ?? "-")  프레임 \(live.fps.map(OsmoCatalog.fpsName) ?? "-")  흔들림 보정 \(live.eis.map(OsmoCatalog.eisName) ?? "-")")
                Text("배터리 \(live.battery.map(String.init) ?? "-")  제품 \(live.product)")
                if !live.modeName.isEmpty { Text("모드 이름 \(live.modeName)") }
                if !live.lastError.isEmpty { Text(live.lastError).foregroundStyle(.orange) }
            } else {
                Text("아직 상태가 없습니다.")
            }
            Text("해상도, 프레임, 흔들림 보정은 읽기만 됩니다. 이 SDK는 그 값을 쓰지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("기기 번호는 모드 전환 문서의 바이트 순서를 따릅니다. 녹화 예제에만 있는 뒤바뀐 번호는 보내지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("모드") {
            Picker("모드", selection: $mode) {
                ForEach(OsmoCatalog.writableModes(for: device.osmoModel), id: \.0) { item in
                    Text(item.1).tag(item.0)
                }
            }
            Button("모드 보내기") {
                Task {
                    if studio.profile.practice {
                        studio.note("연습: \(device.name) 모드")
                    } else {
                        studio.note((await radio.setMode(device, mode: mode)).text)
                    }
                }
            }
        }
        Section("이 카메라만 녹화") {
            Text("함께 시작과 다릅니다. 이미 연결된 세션으로만 보냅니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("시작") { record(device, true) }
                Button("정지") { record(device, false) }
            }
        }
        Section("만들지 않은 기능") {
            ApiBadge(title: "없음", tint: .orange)
            Text("슬립에서 깨우는 광고와 키 리포트는 보내지 않습니다. 컴패니언 페이지에도 오즈모 버튼을 넣지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func record(_ device: DeviceRecord, _ start: Bool) {
        Task {
            if studio.profile.practice {
                studio.note("연습: \(device.name) \(start ? "시작" : "정지")")
            } else {
                studio.note((await radio.record(device, start: start)).text)
            }
        }
    }
}
