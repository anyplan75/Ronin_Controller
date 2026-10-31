import SwiftUI
import UniformTypeIdentifiers

enum StudioPick: Hashable {
    case device(UUID)
    case camera(UUID, UUID)
    case preset(UUID)
}

struct StudioView: View {
    @EnvironmentObject private var studio: Studio
    @State private var selection: StudioPick?
    @State private var companionFile: ExportFile?
    @State private var profileFile: ExportFile?
    @State private var showCompanion = false
    @State private var showProfile = false
    @State private var showCompanionNote = false
    @State private var companionNote = ""
    @State private var importProfile = false
    /// 무대에서 고른 장치입니다. 목록을 눌러도 무대는 그대로입니다.
    @State private var stageSelection: UUID?
    @State private var selectedCamera: UUID?
    @State private var showSettings = false
    @State private var presetEditor: UUID?
    @State private var pendingPresetDelete: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("장치 \(studio.profile.devices.count)/\(StudioProfile.maxDevices)") {
                    ForEach(studio.profile.devices) { device in
                        deviceHeader(device)
                            .tag(StudioPick.device(device.id))
                        if device.kind == .goproBridge {
                            ForEach(Array(device.cameras.enumerated()), id: \.element.id) { index, camera in
                                cameraHeader(device, index: index, camera: camera)
                                    .tag(StudioPick.camera(device.id, camera.id))
                            }
                            if device.cameras.count < 4 {
                                Button("카메라 추가") { studio.addCamera(device.id) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                Section("프리셋") {
                    ForEach(studio.profile.presets) { preset in
                        Button(preset.name) { presetEditor = preset.id }
                            .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("로닌 컨트롤")
            .toolbar { toolbar }
        } detail: {
            detail
        }
        .background(StagePalette.paper)
        .preferredColorScheme(.light)
        .safeAreaInset(edge: .bottom) {
            GroupBar(compact: false)
                .padding()
                .background(.bar)
        }
        .alert("컴패니언 페이지", isPresented: $showCompanionNote) {
            Button("파일 저장") { showCompanion = true }
            Button("닫기", role: .cancel) {}
        } message: {
            Text(companionNote)
        }
        .fileExporter(isPresented: $showCompanion, document: companionFile, contentType: .json, defaultFilename: "로닌컨트롤-페이지") { result in
            if case .failure = result { studio.note("컴패니언 파일을 저장하지 못했습니다.") }
        }
        .fileExporter(isPresented: $showProfile, document: profileFile, contentType: .json, defaultFilename: "로닌컨트롤-프로필") { result in
            if case .failure = result { studio.note("프로필 파일을 저장하지 못했습니다.") }
        }
        .alert("이 프리셋을 지울까요?", isPresented: Binding(
            get: { pendingPresetDelete != nil },
            set: { if !$0 { pendingPresetDelete = nil } }
        )) {
            Button("삭제", role: .destructive) {
                if let id = pendingPresetDelete {
                    studio.deletePreset(id)
                    if selection == .preset(id) { selection = nil }
                }
                pendingPresetDelete = nil
            }
            Button("취소", role: .cancel) { pendingPresetDelete = nil }
        } message: {
            Text("저장된 프로필에서 빠집니다. 기판에 들어 있는 로닌 동작은 지우지 않습니다.")
        }
        .fileImporter(isPresented: $importProfile, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result, let data = readSecurityScoped(url) {
                studio.importProfile(data)
            }
        }
        .onChange(of: selection) { _, pick in
            switch pick {
            case .device(let id):
                stageSelection = id
                selectedCamera = nil
            case .camera(let deviceId, let cameraId):
                stageSelection = deviceId
                selectedCamera = cameraId
            case .preset, nil:
                break
            }
        }
        .onChange(of: stageSelection) { _, id in
            guard let id else { return }
            if case .camera(let deviceId, _) = selection, deviceId == id, selectedCamera != nil {
                return
            }
            if selection != .device(id) {
                selection = .device(id)
            }
        }
        .onChange(of: selectedCamera) { _, cameraId in
            guard let stageSelection else { return }
            if let cameraId {
                let pick = StudioPick.camera(stageSelection, cameraId)
                if selection != pick { selection = pick }
            } else if case .camera = selection {
                selection = .device(stageSelection)
            }
        }
        .sheet(isPresented: Binding(get: { presetEditor != nil }, set: { if !$0 { presetEditor = nil } })) {
            if let id = presetEditor {
                NavigationStack {
                    PresetEditor(presetId: id)
                        .toolbar {
                            Button("프리셋 삭제", role: .destructive) {
                                pendingPresetDelete = id
                            }
                            Button("닫기") { presetEditor = nil }
                        }
                }
                .stagePopup()
            }
        }
    }

    @ViewBuilder private var detail: some View {
        StageConsole(initialId: nil, selected: $stageSelection, selectedCamera: $selectedCamera, showSettings: $showSettings)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button("설정") {
                guard stageSelection != nil else {
                    studio.note("무대에서 장치를 먼저 고르세요.")
                    return
                }
                showSettings = true
            }
        }
        ToolbarItem {
            Menu("장치 추가") {
                ForEach(DeviceProduct.addMenu) { product in
                    Button(product.label) { studio.addDevice(product) }
                }
            }
            .disabled(studio.profile.devices.count >= StudioProfile.maxDevices)
        }
        ToolbarItem {
            Menu("프리셋 추가") {
                Button("로닌 프리셋") {
                    guard let device = studio.profile.devices.first(where: { $0.kind == .ronin }) else {
                        studio.note("로닌 기판을 먼저 추가하세요.")
                        return
                    }
                    studio.addRoninPreset(for: device, look: RoninLook(shot: "wide", timeScale: 1, sendMove: false, yaw: 0, roll: 0, pitch: 0, seconds: 1.5, absolute: true))
                }
                Button("카메라 설정 프리셋") {
                    guard let device = studio.profile.devices.first(where: { $0.kind == .goproBridge || $0.kind == .gopro || $0.kind == .goproAction5 }) else {
                        studio.note("고프로 또는 액션 5 프로 칸을 먼저 추가하세요.")
                        return
                    }
                    let cameraId = device.kind == .goproBridge ? device.cameras.first?.id : nil
                    studio.addActionPreset(deviceId: device.id, cameraId: cameraId, name: "", look: GoProCatalog.freshLook())
                }
            }
        }
        ToolbarItem {
            Menu("파일") {
                Button("컴패니언 페이지") { prepareCompanion() }
                Button("프로필 보내기") { prepareProfile() }
                Button("프로필 가져오기") { importProfile = true }
            }
        }
    }

    private func prepareCompanion() {
        do {
            let (data, note) = try CompanionExport.page(profile: studio.profile)
            companionFile = ExportFile(data: data)
            companionNote = note + "\n저장 이름이 .json 이면 컴패니언이 원할 때 .companionconfig 로 바꾸세요."
            showCompanionNote = true
        } catch {
            studio.note("컴패니언 페이지를 만들지 못했습니다.")
        }
    }

    private func prepareProfile() {
        do {
            profileFile = ExportFile(data: try studio.exportProfile())
            showProfile = true
        } catch {
            studio.note("프로필을 만들지 못했습니다.")
        }
    }

    private func deviceHeader(_ device: DeviceRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
        HStack {
            Label(device.name, systemImage: icon(device))
            Spacer()
            Button("설정") {
                stageSelection = device.id
                selectedCamera = nil
                showSettings = true
            }
            .buttonStyle(.borderless)
            Button("삭제", role: .destructive) {
                if stageSelection == device.id {
                    stageSelection = nil
                    selectedCamera = nil
                    selection = nil
                }
                studio.deleteDevice(device.id)
            }
            .buttonStyle(.borderless)
        }
            if device.kind == .goproBridge {
                Text(studio.bridgeWifiLine(device.id))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(studio.bridgeDirectLine(device.id))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cameraHeader(_ device: DeviceRecord, index: Int, camera: BridgeCameraSlot) -> some View {
        HStack {
            Image(systemName: "video")
            Text("카메라 \(index + 1)")
            Text(camera.role.title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(BoardMac.isFull(camera.mac) ? BoardMac.normalize(camera.mac) : "맥 없음")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("설정") {
                stageSelection = device.id
                selectedCamera = camera.id
                showSettings = true
            }
            .buttonStyle(.borderless)
            Button("삭제", role: .destructive) {
                if selectedCamera == camera.id { selectedCamera = nil }
                studio.deleteCamera(device.id, camera.id)
            }
            .buttonStyle(.borderless)
        }
        .padding(.leading, 16)
    }

    private func icon(_ device: DeviceRecord) -> String {
        switch device.kind {
        case .ronin: return "rotate.3d"
        case .gopro: return "wifi"
        case .goproAction5: return "dot.radiowaves.left.and.right"
        case .goproBridge: return "square.grid.2x2"
        case .osmoAction:
            return device.osmoModel == .osmo360 ? "camera.metering.center.weighted" : "camera.metering.spot"
        case .osmoNoAPI: return "questionmark.circle"
        }
    }
}
