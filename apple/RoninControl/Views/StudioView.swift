import SwiftUI
import UniformTypeIdentifiers

enum StudioPick: Hashable {
    case device(UUID)
    case camera(UUID, UUID)
    case preset(UUID)
}

struct StudioView: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var link: BoardSocket
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
    @State private var askC3Job = false
    @State private var lightLevel: [UUID: Double] = [:]
    @State private var lightKelvin: [UUID: Double] = [:]

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("로닌 · 같은 기판") {
                    ForEach(studio.profile.devices.filter { $0.kind == .ronin }) { device in
                        deviceHeader(device)
                            .tag(StudioPick.device(device.id))
                    }
                }
                Section("등록한 기판") {
                    if studio.profile.olimexRegistered {
                        Text("올리멕스 ESP32-PoE")
                        Text(link.state == .online ? link.detail : "오프라인")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(studio.profile.c3Boards) { board in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(board.name)
                                Spacer()
                                Button("삭제", role: .destructive) { studio.deleteC3(board.id) }
                                    .buttonStyle(.borderless)
                            }
                            Text("이 C3 는 \(board.duty.title)만 합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if board.duty == .light {
                                lightControls(board)
                            } else {
                                Text("로닌 팬과 틸트만 이 기판으로 갑니다. 액션 카메라와 PoE 는 움직이지 않습니다. 연결이 없으면 오프라인입니다.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("액션 카메라 · 올리멕스") {
                    if !studio.profile.olimexRegistered {
                        Text("올리멕스를 등록하면 액션 카메라가 여기 나옵니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if link.state != .online {
                        Text("올리멕스 웹소켓이 오프라인입니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if link.cameras.isEmpty {
                        Text("기판에는 닿았고, 블루투스로 붙은 카메라는 없습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(link.cameras) { camera in
                            HStack {
                                Text(camera.name)
                                Text(camera.ble)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("녹화") { Task { await studio.olimexCamera(camera, start: true) } }
                                Button("정지") { Task { await studio.olimexCamera(camera, start: false) } }
                            }
                            .buttonStyle(.borderless)
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
        .safeAreaInset(edge: .top) {
            transportBar
        }
        .confirmationDialog("이 C3 의 일", isPresented: $askC3Job, titleVisibility: .visible) {
            Button("로닌 제어") { studio.registerC3(.ronin) }
            Button("조명 · 울란지 VL120BI") { studio.registerC3(.light) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("한 대는 고른 일만 합니다. 액션 카메라는 올리멕스 기판에 남습니다.")
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
            Menu("기판 등록") {
                Button("올리멕스 ESP32-PoE") { studio.registerOlimex() }
                Button("C3") { askC3Job = true }
            }
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

    private var transportBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(link.state == .online ? "확인해 준 녹화 \(link.reportedRecording ?? 0)" : "오프라인")
                    .font(.subheadline.weight(.semibold))
                Text(link.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("길", selection: Binding(get: { link.lane }, set: { studio.chooseLane($0) })) {
                    ForEach(BoardLane.allCases) { lane in
                        Text(lane.title).tag(lane)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Button(link.state == .connecting ? "연결 중" : "지금 연결") {
                    guard studio.profile.olimexRegistered else {
                        studio.note("먼저 올리멕스 ESP32-PoE 를 등록하세요.")
                        return
                    }
                    link.connect()
                }
                    .disabled(link.state == .connecting || !studio.profile.olimexRegistered)
                Button("모두 녹화") { Task { await studio.fieldRecord(group: "all", start: true) } }
                Button("모두 정지") { Task { await studio.fieldRecord(group: "all", start: false) } }
            }
            HStack(spacing: 8) {
                ForEach(["A", "B", "C"], id: \.self) { name in
                    Button("\(name) 녹화") { Task { await studio.fieldRecord(group: name, start: true) } }
                    Button("\(name) 정지") { Task { await studio.fieldRecord(group: name, start: false) } }
                }
            }
            .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func lightControls(_ board: C3BoardRecord) -> some View {
        let level = lightLevel[board.id] ?? 40
        let kelvin = lightKelvin[board.id] ?? 4500
        return VStack(alignment: .leading, spacing: 4) {
            Text("밝기 \(Int(level))")
                .font(.caption2)
            Slider(value: Binding(
                get: { lightLevel[board.id] ?? 40 },
                set: { lightLevel[board.id] = $0 }
            ), in: 0...100, step: 1)
            Text("색온도 \(Int(kelvin))K")
                .font(.caption2)
            Slider(value: Binding(
                get: { lightKelvin[board.id] ?? 4500 },
                set: { lightKelvin[board.id] = $0 }
            ), in: 2500...6500, step: 100)
            HStack {
                Button("켜기") { Task { await studio.setLight(board.id, brightness: Int(level), kelvin: Int(kelvin), on: true) } }
                Button("끄기") { Task { await studio.setLight(board.id, brightness: Int(level), kelvin: Int(kelvin), on: false) } }
            }
            .font(.caption)
            .buttonStyle(.bordered)
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
            Menu("묶음") {
                ForEach(["A", "B", "C"], id: \.self) { name in
                    Button(studio.memberOf(name, deviceId: device.id) ? "\(name) 빼기" : "\(name)에 넣기") {
                        studio.toggleShootGroup(name, deviceId: device.id)
                    }
                }
            }
            .buttonStyle(.borderless)
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
            Button("녹화") { Task { await studio.bridgeSlot(device, cameraId: camera.id, start: true) } }
                .buttonStyle(.borderless)
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
