import SwiftUI
import UniformTypeIdentifiers

/// 아이폰 기본 화면입니다. 밝은 카메라 목록과 연결·함께 시작·프리셋 적용을 둡니다.
/// 기판은 한 줄로 묶이고, 카메라는 한 대씩 고릅니다. 실시간 그림은 아래 가운데에 고프로 와이파이만 엽니다.
struct PhoneRunView: View {
    @EnvironmentObject private var studio: Studio
    @State private var importProfile = false
    @State private var profileFile: ExportFile?
    @State private var showProfile = false
    @State private var selected: UUID?
    @State private var selectedCamera: UUID?
    @State private var showDevices = false
    @State private var showSettings = false
    @State private var openSettingsAfterList = false

    private let canvas = StagePalette.paper
    private let rowFill = Color.white.opacity(0.72)

    var body: some View {
        NavigationStack {
            LiveStageView(deviceId: nil, selected: $selected, selectedCamera: $selectedCamera, showSettings: $showSettings)
                .toolbar { toolbar }
                .sheet(isPresented: $showDevices, onDismiss: {
                    if openSettingsAfterList {
                        openSettingsAfterList = false
                        showSettings = true
                    }
                }) {
                    deviceSheet
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
        .background(StagePalette.paper)
        .foregroundStyle(StagePalette.ink)
        .preferredColorScheme(.light)
    }

    private var deviceSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    listHeader
                    if studio.profile.devices.isEmpty {
                        Text("장치를 추가한 뒤 무대에서 고릅니다. 프리셋 편집은 맥이나 아이패드에서 하세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    ForEach(studio.profile.devices) { device in
                        cameraRow(device)
                    }
                    presetBlock
                    GroupBar(compact: true)
                        .padding(12)
                        .background(rowFill, in: RoundedRectangle(cornerRadius: 12))
                    LogList()
                        .padding(12)
                        .background(rowFill, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(16)
            }
            .background(canvas)
            .navigationTitle("장치")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("닫기") { showDevices = false }
            }
        }
        .stagePopup()
    }

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("기판을 누르면 그 중계가 선택됩니다. 카메라를 누르면 그 카메라만 선택되고, 설정도 그 카메라만 엽니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cameraRow(_ device: DeviceRecord) -> some View {
        let boardPicked = selected == device.id && selectedCamera == nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    selected = device.id
                    selectedCamera = nil
                    showDevices = false
                } label: {
                    HStack(alignment: .center, spacing: 10) {
                        Circle()
                            .fill(statusColor(device))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(summary(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        if device.kind.supportsLiveView {
                            Text("실시간")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .foregroundStyle(StagePalette.ink)
                                .background(Color.white.opacity(0.8), in: Capsule())
                        }
                    }
                }
                .buttonStyle(.plain)
                Button(device.kind == .goproBridge ? "설정" : "주소") {
                    selected = device.id
                    selectedCamera = nil
                    openSettingsAfterList = true
                    showDevices = false
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                Button("삭제", role: .destructive) {
                    if selected == device.id {
                        selected = nil
                        selectedCamera = nil
                    }
                    studio.deleteDevice(device.id)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }
            if device.kind == .goproBridge {
                ForEach(Array(device.cameras.enumerated()), id: \.element.id) { index, camera in
                    cameraLine(device, index: index, camera: camera)
                }
                if device.cameras.count < 4 {
                    Button("카메라 추가") { studio.addCamera(device.id) }
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .padding(12)
        .background(boardPicked ? StagePalette.brass.opacity(0.28) : rowFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private func cameraLine(_ device: DeviceRecord, index: Int, camera: BridgeCameraSlot) -> some View {
        let picked = selectedCamera == camera.id
        return HStack(spacing: 8) {
            Button {
                selected = device.id
                selectedCamera = camera.id
                showDevices = false
            } label: {
                HStack {
                    Text("카메라 \(index + 1)  \(camera.role.title)")
                    Text(BoardMac.isFull(camera.mac) ? BoardMac.normalize(camera.mac) : "맥 없음")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            Button("설정") {
                selected = device.id
                selectedCamera = camera.id
                openSettingsAfterList = true
                showDevices = false
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            Button("삭제", role: .destructive) {
                if selectedCamera == camera.id { selectedCamera = nil }
                studio.deleteCamera(device.id, camera.id)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
        }
        .font(.caption)
        .padding(8)
        .background(picked ? StagePalette.brass.opacity(0.28) : Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var presetBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("프리셋 적용")
                .font(.subheadline.weight(.semibold))
            Text("아이폰에는 프리셋 편집기가 없습니다. 맥이나 아이패드에서 만든 파일을 가져오세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if studio.profile.presets.isEmpty {
                Text("가져온 프리셋이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(studio.profile.presets) { preset in
                Button(preset.name) { Task { await studio.apply(preset) } }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 12))
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("장치") { showDevices = true }
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu("추가") {
                ForEach(DeviceProduct.addMenu) { product in
                    Button(product.label) { studio.addDevice(product) }
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

    private func summary(_ device: DeviceRecord) -> String {
        switch device.kind {
        case .ronin:
            let live = studio.roninLive[device.id]
            let rec = live?.camRecording == true ? "녹화 명령" : "대기"
            let link = live == nil ? "상태 없음" : "상태 있음"
            return "\(device.linkLabel)  \(link)  \(rec)  \(device.baseURLText)"
        case .gopro:
            return "\(device.linkLabel)  \(studio.goproSession[device.id] ?? "세션 미확인")  \(device.baseURLText)"
        case .goproAction5:
            return "\(device.linkLabel)  미리보기 없음  \(studio.goproSession[device.id] ?? "세션 미확인")"
        case .goproBridge:
            let live = studio.bridgeLive[device.id]
            let attached = device.cameras.filter { live?.attachment(for: $0) == "붙음" }.count
            let phase = studio.bridgePhase[device.id] ?? "기판을 찾는 중입니다."
            return "\(device.linkLabel)  \(phase)  붙음 \(attached)/\(device.cameras.count)"
        case .osmoAction:
            let battery = studio.radio.live[device.id]?.battery
            let power = battery.map { "배터리 \($0)" } ?? "배터리 없음"
            return "\(device.linkLabel)  \(studio.radio.live[device.id]?.phase ?? "블루투스 연결 전")  \(power)"
        case .osmoNoAPI:
            return "\(device.linkLabel)  추가 메뉴에 없습니다"
        }
    }

    private func statusColor(_ device: DeviceRecord) -> Color {
        switch device.kind {
        case .ronin:
            return studio.roninLive[device.id] == nil ? .gray : .green
        case .gopro, .goproAction5:
            let text = studio.goproSession[device.id] ?? ""
            if text.contains("유지") { return .green }
            if text.contains("붙지") { return .red }
            return .gray
        case .goproBridge:
            let phase = studio.bridgePhase[device.id] ?? ""
            if phase.contains("붙었습니다") { return .green }
            if phase.contains("닿지") || phase.contains("다른") { return .red }
            return .gray
        case .osmoAction:
            return studio.radio.isReady(device.id) ? .green : .gray
        case .osmoNoAPI:
            return .orange
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

