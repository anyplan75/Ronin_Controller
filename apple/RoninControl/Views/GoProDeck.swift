import SwiftUI

struct GoProDeck: View {
    @EnvironmentObject private var studio: Studio
    let deviceId: UUID
    @State private var choices: [Int: Int] = Dictionary(
        uniqueKeysWithValues: GoProCatalog.settings.map { ($0.id, $0.options[0].value) }
    )
    @State private var zoom = 0.0
    @State private var presetId = ""
    @State private var relaySSID = ""
    @State private var relayPassword = ""

    private var device: DeviceRecord? {
        studio.profile.devices.first { $0.id == deviceId }
    }

    var body: some View {
        if let device {
            content(device)
        }
    }

    @ViewBuilder private func content(_ device: DeviceRecord) -> some View {
        let relay = device.kind == .goproAction5
        Section(relay ? "오즈모 액션 5 프로 · 블루투스" : "고프로 · 와이파이") {
            ApiBadge(title: relay ? "C3 블루투스 중계" : "와이파이", tint: relay ? .blue : .green)
            Text(studio.goproSession[device.id] ?? "세션을 아직 확인하지 않았습니다.")
            if relay {
                Text(studio.goproLive[device.id]?.relayBle ?? "")
            }
            Button("상태 다시 읽기") { Task { await studio.refresh() } }
            Button("세션 유지 한 번 더") {
                Task { await studio.gopro(device, { try await GoProClient.keepAlive($0) }, label: "세션 유지") }
            }
            if relay {
                Button("블루투스 다시 붙기") {
                    Task { await studio.gopro(device, { try await GoProClient.pairRelay($0) }, label: "중계 연결") }
                }
                Text("중계 기판이 카메라와 이미 붙은 세션을 다시 찾습니다. 촬영 버튼이 붙였다 끊지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            liveText(device)
        }
        Section("셔터") {
            Text(relay
                 ? "중계 기판이 Open GoPro 명령 특성으로 셔터를 보냅니다. 지금 카메라 모드의 촬영입니다."
                 : "Open GoPro 셔터입니다. 지금 카메라 모드가 영상이면 녹화, 사진이면 사진입니다. 별도 사진 주소는 없습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("시작") { shutter(device, true) }
                Button("정지") { shutter(device, false) }
            }
        }
        Section("설정") {
            Text("문서에 선택값이 있는 항목만 있습니다. 카메라가 거절하면 기록에 남습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(GoProCatalog.settings) { spec in
                VStack(alignment: .leading, spacing: 4) {
                    Text(spec.title).font(.headline)
                    Text(spec.note).font(.caption).foregroundStyle(.secondary)
                    if let current = studio.goproLive[device.id]?.settings[spec.id] {
                        Text("카메라가 알려 준 값 \(current)").font(.caption2)
                    }
                    Picker(spec.title, selection: choiceBinding(spec)) {
                        ForEach(spec.options) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    Button("이 설정 보내기") {
                        let option = choices[spec.id] ?? spec.options[0].value
                        Task {
                            await studio.gopro(device, { try await GoProClient.setSetting($0, setting: spec.id, option: option) }, label: spec.title)
                        }
                    }
                }
            }
            Text("LED, 화면 밝기, 플리커 방지, 일부 기종의 프레임 번호 234는 선택값 표를 확인하지 못해 빼 두었습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if relay {
            Section("중계 기판 와이파이") {
                Text("비밀번호는 프로필에 저장하지 않습니다. 중계 기판에만 전달합니다. 처음에는 기판 설정 와이파이 Ronin-Action5 의 192.168.4.1 로 보냅니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("집 와이파이 이름", text: $relaySSID)
                SecureField("비밀번호", text: $relayPassword)
                Button("중계 기판에 저장") {
                    Task { await saveWifi(device) }
                }
            }
            Section("이 중계에 없는 기능") {
                ApiBadge(title: "없음", tint: .orange)
                Text("디지털 줌, 웹캠, 카메라 안 프리셋 불러오기는 중계 기판이 501로 거절합니다. 버튼으로 있는 척하지 않습니다.")
            }
        } else {
            Section("디지털 줌") {
                Slider(value: $zoom, in: 0...100, step: 1)
                Button("줌 \(Int(zoom))% 보내기") {
                    Task { await studio.gopro(device, { try await GoProClient.digitalZoom($0, percent: Int(zoom)) }, label: "디지털 줌") }
                }
            }
            Section("카메라 안 프리셋") {
                Text("앱 프리셋과 다릅니다. 카메라에 저장된 번호입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("목록 읽기") {
                    Task { await studio.gopro(device, { try await GoProClient.presetList($0) }, label: "프리셋 목록") }
                }
                if let list = studio.goproLive[device.id]?.presetList, !list.isEmpty {
                    let items = CameraPresetText.parse(list)
                    if items.isEmpty {
                        Text(list).font(.caption2)
                    } else {
                        ForEach(items) { item in
                            Button(item.title) {
                                Task { await studio.gopro(device, { try await GoProClient.loadPreset($0, id: item.id) }, label: item.title) }
                            }
                        }
                    }
                }
                TextField("프리셋 번호", text: $presetId)
                Button("그 번호 불러오기") {
                    guard let id = Int(presetId) else { return }
                    Task { await studio.gopro(device, { try await GoProClient.loadPreset($0, id: id) }, label: "카메라 프리셋") }
                }
            }
            Section("웹캠") {
                ApiBadge(title: "웹캠 모드", tint: .blue)
                Text("일반 녹화가 아닙니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("웹캠 시작") { Task { await studio.gopro(device, { try await GoProClient.webcam($0, start: true) }, label: "웹캠 시작") } }
                    Button("웹캠 정지") { Task { await studio.gopro(device, { try await GoProClient.webcam($0, start: false) }, label: "웹캠 정지") } }
                }
            }
        }
    }

    @ViewBuilder private func liveText(_ device: DeviceRecord) -> some View {
        if let live = studio.goproLive[device.id] {
            if device.kind == .gopro {
                Text("녹화 중 \(live.encoding == true ? "예" : "아니오")  바쁨 \(live.busy == true ? "예" : "아니오")")
                Text("남은 영상 \(live.remainingVideo.map(String.init) ?? "-")  남은 사진 \(live.remainingPhotos.map(String.init) ?? "-")  카드 \(live.sdRemaining.map(String.init) ?? "-")")
            }
            if !live.error.isEmpty {
                Text(live.error).foregroundStyle(.orange)
            }
        }
    }

    private func choiceBinding(_ spec: GoProSettingSpec) -> Binding<Int> {
        Binding(
            get: { choices[spec.id] ?? spec.options[0].value },
            set: { choices[spec.id] = $0 }
        )
    }

    private func shutter(_ device: DeviceRecord, _ start: Bool) {
        Task { await studio.gopro(device, { try await GoProClient.shutter($0, start: start) }, label: start ? "셔터 시작" : "셔터 정지") }
    }

    private func saveWifi(_ device: DeviceRecord) async {
        if studio.profile.practice {
            studio.note("연습: 중계 기판 와이파이는 보내지 않았습니다.")
            return
        }
        do {
            _ = try await GoProClient.saveRelayWifi(device, ssid: relaySSID, password: relayPassword)
            studio.note("\(device.name) 중계 기판에 와이파이 저장을 보냈습니다. 비밀번호는 적지 않습니다.")
        } catch {
            studio.note("\(device.name) \(error.localizedDescription)")
        }
    }
}
