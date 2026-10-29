import SwiftUI
import UniformTypeIdentifiers

struct PhoneRunView: View {
    @EnvironmentObject private var studio: Studio
    @State private var editing: UUID?
    @State private var importProfile = false
    @State private var profileFile: ExportFile?
    @State private var showProfile = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    GroupBar(compact: true)
                }
                Section("장치") {
                    if studio.profile.devices.isEmpty {
                        Text("아이폰에서는 연결하고, 이미 만든 프리셋을 적용합니다. 프리셋 편집은 맥이나 아이패드에서 하세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(studio.profile.devices) { device in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(device.name).font(.headline)
                                Spacer()
                                Text(device.kind.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(summary(device)).font(.caption)
                            Toggle("함께 촬영", isOn: studio.groupBinding(device.id))
                            Button("주소") { editing = device.id }
                        }
                    }
                }
                Section("프리셋 적용") {
                    Text("아이폰에는 프리셋 편집기가 없습니다. 맥이나 아이패드에서 만든 파일을 가져오세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if studio.profile.presets.isEmpty {
                        Text("가져온 프리셋이 없습니다.")
                    }
                    ForEach(studio.profile.presets) { preset in
                        Button(preset.name) { Task { await studio.apply(preset) } }
                    }
                }
                Section("기록") { LogList() }
            }
            .navigationTitle("촬영")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu("장치") {
                        ForEach(DeviceKind.allCases) { kind in
                            Button(kind.title) { studio.addDevice(kind: kind) }
                        }
                    }
                    .disabled(studio.profile.devices.count >= StudioProfile.maxDevices)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("상태") { Task { await studio.refresh() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("파일") {
                        Button("프로필 가져오기") { importProfile = true }
                        Button("프로필 보내기") { exportProfile() }
                    }
                }
            }
            .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                if let id = editing {
                    NavigationStack {
                        Form {
                            DeviceForm(radio: studio.radio, deviceId: id)
                            Section {
                                Button("삭제", role: .destructive) {
                                    studio.deleteDevice(id)
                                    editing = nil
                                }
                            }
                        }
                        .navigationTitle("주소")
                        .toolbar {
                            Button("닫기") { editing = nil }
                        }
                    }
                }
            }
            .fileImporter(isPresented: $importProfile, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result, let data = readSecurityScoped(url) {
                    studio.importProfile(data)
                }
            }
            .fileExporter(isPresented: $showProfile, document: profileFile, contentType: .json, defaultFilename: "로닌컨트롤-프로필") { result in
                if case .failure = result { studio.note("프로필 파일을 저장하지 못했습니다.") }
            }
        }
    }

    private func summary(_ device: DeviceRecord) -> String {
        switch device.kind {
        case .ronin:
            let live = studio.roninLive[device.id]
            let rec = live?.camRecording == true ? "녹화 명령" : "대기"
            return "\(device.baseURLText)  \(rec)"
        case .gopro, .goproAction5:
            return "\(device.baseURLText)  \(studio.goproSession[device.id] ?? "세션 미확인")"
        case .osmoAction:
            return studio.radio.live[device.id]?.phase ?? "블루투스 연결 전"
        case .osmoNoAPI:
            return "공개 API 없음"
        }
    }

    private func exportProfile() {
        do {
            profileFile = ExportFile(data: try studio.exportProfile())
            showProfile = true
        } catch {
            studio.note("프로필을 만들지 못했습니다.")
        }
    }
}
