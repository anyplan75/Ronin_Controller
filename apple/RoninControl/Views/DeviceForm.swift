import SwiftUI

struct DeviceForm: View {
    @EnvironmentObject private var studio: Studio
    @ObservedObject var radio: OsmoRadio
    let deviceId: UUID

    private var device: Binding<DeviceRecord> { studio.deviceBinding(deviceId) }

    var body: some View {
        Section("직접 연결") {
            TextField("이름", text: device.name)
            Picker("종류", selection: kindChoice) {
                ForEach(DeviceKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            Toggle("사용", isOn: device.enabled)
            Toggle("함께 촬영에 포함", isOn: studio.groupBinding(deviceId))
            if device.wrappedValue.kind.usesHTTP {
                TextField(addressPrompt, text: device.host)
                    .autocorrectionDisabled()
                Stepper("포트 \(device.wrappedValue.port)", value: device.port, in: 1...65535)
                Text(device.wrappedValue.baseURLText.isEmpty ? "주소가 비어 있습니다." : device.wrappedValue.baseURLText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            note
        }
        if device.wrappedValue.kind == .osmoAction || device.wrappedValue.kind == .osmoNoAPI {
            osmoIdentity
        }
        if device.wrappedValue.kind == .osmoAction {
            osmoPair
        }
    }

    private var addressPrompt: String {
        device.wrappedValue.kind == .goproAction5 ? "중계 기판 주소" : "주소"
    }

    private var kindChoice: Binding<DeviceKind> {
        Binding(
            get: { device.wrappedValue.kind },
            set: { kind in
                device.wrappedValue.kind = kind
                device.wrappedValue.osmoModel = OsmoModel.choices(for: kind).first ?? .unknown
                device.wrappedValue.port = kind.defaultPort
                if kind == .gopro, device.wrappedValue.host.isEmpty {
                    device.wrappedValue.host = "10.5.5.9"
                }
                if kind == .goproAction5, device.wrappedValue.host == "10.5.5.9" {
                    device.wrappedValue.host = ""
                }
            }
        )
    }

    @ViewBuilder private var note: some View {
        switch device.wrappedValue.kind {
        case .ronin:
            Text(Honest.ronin).font(.caption).foregroundStyle(.secondary)
        case .gopro:
            Text(Honest.gopro).font(.caption).foregroundStyle(.secondary)
        case .goproAction5:
            Text(Honest.action5).font(.caption).foregroundStyle(.secondary)
        case .osmoAction:
            Text(Honest.osmo).font(.caption).foregroundStyle(.secondary)
        case .osmoNoAPI:
            Text(Honest.noAPI).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var osmoIdentity: some View {
        Section("오즈모 기종") {
            Picker("기종", selection: device.osmoModel) {
                ForEach(OsmoModel.choices(for: device.wrappedValue.kind)) { model in
                    Text(model.title).tag(model)
                }
            }
            if device.wrappedValue.kind == .osmoNoAPI {
                ApiBadge(title: "API 없음", tint: .orange)
            }
        }
    }

    @ViewBuilder private var osmoPair: some View {
        Section("블루투스 세션") {
            Text(radio.bluetoothNote).font(.caption)
            Text(radio.live[deviceId]?.phase ?? "연결 안 됨")
            Button(radio.scanning ? "찾는 중" : "카메라 찾기") {
                radio.startScan()
            }
            .disabled(radio.scanning)
            ForEach(radio.seen) { seen in
                Button("\(seen.name)  \(seen.rssi)") {
                    device.wrappedValue.bleIdentifier = seen.identifier.uuidString
                }
            }
            Text(device.wrappedValue.bleIdentifier.isEmpty ? "고른 카메라가 없습니다." : device.wrappedValue.bleIdentifier)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("처음 연결 (카메라에 숫자 확인)") {
                Task { await pair(verify: device.wrappedValue.pairedOnce ? 0 : 1) }
            }
            Button("확인 없이 다시 시도") {
                Task { await pair(verify: 0) }
            }
            Text("요청마다 붙였다 끊지 않습니다. 페어링은 수십 초 걸릴 수 있어 함께 시작이 대신 연결하지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func pair(verify: UInt8) async {
        let current = device.wrappedValue
        let outcome = await radio.pair(
            device: current,
            senderId: studio.profile.senderId,
            mac: studio.profile.senderMac,
            verifyMode: verify
        )
        studio.note(outcome.text)
        if outcome.ok {
            device.wrappedValue.pairedOnce = true
        }
    }
}
