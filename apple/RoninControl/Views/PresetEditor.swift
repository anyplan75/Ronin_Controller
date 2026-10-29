import SwiftUI

struct PresetEditor: View {
    @EnvironmentObject private var studio: Studio
    let presetId: UUID

    private var preset: Binding<ShootPreset> { studio.presetBinding(presetId) }

    var body: some View {
        Form {
            Section("프리셋") {
                TextField("이름", text: preset.name)
                TextField("메모", text: preset.note, axis: .vertical)
                Text("적용은 설정을 보낼 뿐 녹화를 시작하지 않습니다. 장치 주소도 이 프리셋에 같이 저장됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("적용") { Task { await studio.apply(preset.wrappedValue) } }
                    .buttonStyle(.borderedProminent)
                Button("지금 주소를 이 프리셋에 저장") { studio.rememberConnections(in: presetId) }
                Button("이 프리셋의 주소를 가져오기") { studio.restoreConnections(from: presetId) }
            }
            Section("대상 장치") {
                if studio.profile.devices.isEmpty {
                    Text("장치가 없습니다.")
                }
                ForEach(studio.profile.devices) { device in
                    Toggle(device.name, isOn: member(device.id))
                }
                Text("하나도 고르지 않으면 켜진 장치 전체에 적용합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("로닌") {
                Picker("샷", selection: preset.ronin.shot) {
                    Text("보내지 않음").tag("")
                    ForEach(studio.shotNames, id: \.self) { name in
                        Text(RoninCatalog.title(name)).tag(name)
                    }
                }
                HStack {
                    Text("시간 배율")
                    Slider(value: preset.ronin.timeScale, in: 0.25...4)
                }
                Toggle("이동도 보내기", isOn: preset.ronin.sendMove)
                Toggle("절대 각도", isOn: preset.ronin.absolute)
                number("요", preset.ronin.yaw)
                number("롤", preset.ronin.roll)
                number("피치", preset.ronin.pitch)
                number("초", preset.ronin.seconds)
            }
            Section("고프로") {
                Text("체크한 설정만 보냅니다. 액션 5 프로 중계에는 줌과 카메라 프리셋 번호를 보내지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(GoProCatalog.settings) { spec in
                    let choice = choiceBinding(spec)
                    Toggle(spec.title, isOn: choice.enabled)
                    Picker(spec.title, selection: choice.option) {
                        ForEach(spec.options) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .disabled(!choice.wrappedValue.enabled)
                }
                Toggle("디지털 줌 (직접 연결만)", isOn: zoomOn)
                if preset.wrappedValue.gopro.digitalZoomPercent != nil {
                    Stepper("\(preset.wrappedValue.gopro.digitalZoomPercent ?? 0)%", value: zoomValue, in: 0...100)
                }
                Toggle("카메라 프리셋 번호 (직접 연결만)", isOn: presetIdOn)
                if preset.wrappedValue.gopro.loadPresetId != nil {
                    Stepper("번호 \(preset.wrappedValue.gopro.loadPresetId ?? 0)", value: presetIdValue, in: 0...200)
                }
            }
            Section("오즈모 모드") {
                Picker("모드", selection: osmoMode) {
                    Text("보내지 않음").tag(-1)
                    ForEach(OsmoCatalog.actionModes + OsmoCatalog.osmo360Modes, id: \.0) { item in
                        Text(item.1).tag(item.0)
                    }
                }
                Text("360 전용 모드는 액션 카메라에서 거절됩니다. 해상도는 읽기만 가능해서 프리셋에 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("저장된 주소") {
                if preset.wrappedValue.connections.isEmpty {
                    Text("아직 주소를 저장하지 않았습니다.")
                }
                ForEach(preset.wrappedValue.connections) { device in
                    Text("\(device.name)  \(device.kind.title)  \(device.baseURLText)")
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(preset.wrappedValue.name)
        .onAppear {
            preset.wrappedValue.gopro = GoProCatalog.merged(preset.wrappedValue.gopro)
        }
    }

    private func member(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { preset.wrappedValue.deviceIds.contains(id) },
            set: { on in
                if on {
                    if !preset.wrappedValue.deviceIds.contains(id) {
                        preset.wrappedValue.deviceIds.append(id)
                    }
                } else {
                    preset.wrappedValue.deviceIds.removeAll { $0 == id }
                }
            }
        )
    }

    private func number(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 36, alignment: .leading)
            TextField(title, value: value, format: .number)
        }
    }

    private func choiceBinding(_ spec: GoProSettingSpec) -> Binding<GoProSettingChoice> {
        Binding(
            get: {
                preset.wrappedValue.gopro.settings.first(where: { $0.settingId == spec.id })
                    ?? GoProSettingChoice(settingId: spec.id, option: spec.options[0].value, enabled: false)
            },
            set: { newValue in
                if let index = preset.wrappedValue.gopro.settings.firstIndex(where: { $0.settingId == spec.id }) {
                    preset.wrappedValue.gopro.settings[index] = newValue
                } else {
                    preset.wrappedValue.gopro.settings.append(newValue)
                }
            }
        )
    }

    private var zoomOn: Binding<Bool> {
        Binding(
            get: { preset.wrappedValue.gopro.digitalZoomPercent != nil },
            set: { preset.wrappedValue.gopro.digitalZoomPercent = $0 ? (preset.wrappedValue.gopro.digitalZoomPercent ?? 0) : nil }
        )
    }

    private var zoomValue: Binding<Int> {
        Binding(
            get: { preset.wrappedValue.gopro.digitalZoomPercent ?? 0 },
            set: { preset.wrappedValue.gopro.digitalZoomPercent = min(100, max(0, $0)) }
        )
    }

    private var presetIdOn: Binding<Bool> {
        Binding(
            get: { preset.wrappedValue.gopro.loadPresetId != nil },
            set: { preset.wrappedValue.gopro.loadPresetId = $0 ? (preset.wrappedValue.gopro.loadPresetId ?? 0) : nil }
        )
    }

    private var presetIdValue: Binding<Int> {
        Binding(
            get: { preset.wrappedValue.gopro.loadPresetId ?? 0 },
            set: { preset.wrappedValue.gopro.loadPresetId = min(200, max(0, $0)) }
        )
    }

    private var osmoMode: Binding<Int> {
        Binding(
            get: { preset.wrappedValue.osmo.mode ?? -1 },
            set: { preset.wrappedValue.osmo.mode = $0 < 0 ? nil : $0 }
        )
    }
}
