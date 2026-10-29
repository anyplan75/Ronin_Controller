import SwiftUI
import UniformTypeIdentifiers

/// 아이폰 기본 화면입니다. 밝은 카메라 목록과 연결·함께 시작·프리셋 적용을 둡니다.
/// 무대 화면 위쪽에 장치를 두고, 그 아래 휠은 고른 로닌만 셉니다. 실시간 그림은 고프로 와이파이만 엽니다.
struct PhoneRunView: View {
    @EnvironmentObject private var studio: Studio
    @State private var editing: UUID?
    @State private var importProfile = false
    @State private var profileFile: ExportFile?
    @State private var showProfile = false
    @State private var liveID: UUID?
    @State private var detailID: UUID?
    @State private var showStage = false
    /// 휠에 올릴 로닌입니다. 고른 순서가 왼쪽부터입니다. 비어 있으면 휠이 없습니다.
    @State private var wheelIds: [UUID] = []

    private let canvas = StagePalette.paper
    private let rowFill = Color.white.opacity(0.72)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    listHeader
                    if studio.profile.devices.isEmpty {
                        Text("아이폰에서는 연결하고, 이미 만든 프리셋을 적용합니다. 프리셋 편집은 맥이나 아이패드에서 하세요.")
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
            .navigationTitle("카메라")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(StagePalette.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar { toolbar }
            .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                addressSheet
            }
            .navigationDestination(item: $liveID) { id in
                LiveStageView(deviceId: id, wheelIds: $wheelIds)
            }
            .navigationDestination(isPresented: $showStage) {
                LiveStageView(deviceId: nil, wheelIds: $wheelIds)
            }
            .navigationDestination(item: $detailID) { id in
                PhoneDeviceDetail(deviceId: id)
            }
            .fileImporter(isPresented: $importProfile, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result, let data = readSecurityScoped(url) {
                    studio.importProfile(data)
                }
            }
            .fileExporter(isPresented: $showProfile, document: profileFile, contentType: .json, defaultFilename: "로닌컨트롤-프로필") { result in
                if case .failure = result { studio.note("프로필 파일을 저장하지 못했습니다.") }
            }
            .onChange(of: studio.profile.devices.map(\.id)) { _, ids in
                wheelIds.removeAll { !ids.contains($0) }
            }
        }
        .background(StagePalette.paper)
        .foregroundStyle(StagePalette.ink)
        .preferredColorScheme(.light)
    }

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("고른 로닌 \(wheelIds.count)대")
                .font(.subheadline.weight(.semibold))
            Text("무대는 가운데를 위아래로 반씩 나눕니다. 위는 방, 아래는 여기서 고른 로닌 휠 0개에서 4개까지입니다. 고프로와 액션 5 프로는 C3 기판으로 붙습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("무대") { showStage = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private func cameraRow(_ device: DeviceRecord) -> some View {
        let picked = wheelIds.contains(device.id)
        return HStack(spacing: 12) {
            if device.kind == .ronin {
                Button {
                    toggleWheel(device.id)
                } label: {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(picked ? "\(device.name) 휠 빼기" : "\(device.name) 휠에 넣기")
            }
            Button {
                open(device)
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
            Button(device.kind == .goproBridge ? "설정" : "주소") { editing = device.id }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(picked ? StagePalette.brass.opacity(0.28) : rowFill, in: RoundedRectangle(cornerRadius: 12))
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
            Menu("장치") {
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

    @ViewBuilder private var addressSheet: some View {
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
                .navigationTitle(sheetTitle(id))
                .toolbar {
                    Button("닫기") { editing = nil }
                }
            }
        }
    }

    private func open(_ device: DeviceRecord) {
        if device.kind.supportsLiveView {
            detailID = nil
            liveID = device.id
        } else {
            liveID = nil
            detailID = device.id
        }
    }

    private func toggleWheel(_ id: UUID) {
        if let index = wheelIds.firstIndex(of: id) {
            wheelIds.remove(at: index)
            return
        }
        guard wheelIds.count < 4 else {
            studio.note("휠은 고른 로닌 4대까지입니다.")
            return
        }
        wheelIds.append(id)
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
            return "\(device.linkLabel)  \(phase)  붙음 \(attached)/4"
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

    private func sheetTitle(_ id: UUID) -> String {
        studio.profile.devices.first(where: { $0.id == id })?.kind == .goproBridge ? "장치 설정" : "주소"
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

/// 미리보기가 없는 장치의 기본 조작입니다. 영상 자리는 만들지 않습니다.
struct PhoneDeviceDetail: View {
    @EnvironmentObject private var studio: Studio
    let deviceId: UUID

    var body: some View {
        Group {
            if let device = studio.profile.devices.first(where: { $0.id == deviceId }) {
                Form {
                    Section(device.linkLabel) {
                        Text(device.baseURLText.isEmpty ? "주소가 없습니다." : device.baseURLText)
                        Text("이 장치는 실시간 그림을 주지 않습니다. 미리보기 화면을 만들지 않습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    basicControls(device)
                }
                .navigationTitle(device.name)
            } else {
                ContentUnavailableView("장치를 찾지 못했습니다", systemImage: "video.slash")
            }
        }
        .background(StagePalette.paper)
        .preferredColorScheme(.light)
    }

    @ViewBuilder private func basicControls(_ device: DeviceRecord) -> some View {
        switch device.kind {
        case .ronin:
            Section("이 기판만") {
                Button("녹화 시작") { Task { await studio.ronin(device, path: "/record", query: ["action": "start"]) } }
                Button("녹화 정지") { Task { await studio.ronin(device, path: "/record", query: ["action": "stop"]) } }
                Button("짐벌 정지") { Task { await studio.ronin(device, path: "/stop") } }
            }
        case .goproAction5:
            Section("중계 기판") {
                Button("셔터 시작") { shutter(device, true) }
                Button("셔터 정지") { shutter(device, false) }
                Text("오즈모 액션 5 프로 중계는 미리보기 그림을 주지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .goproBridge:
            Section("기판에 붙은 카메라") {
                BridgeAttachmentList(device: device)
                Button("촬영 시작") { Task { await studio.bridgeRecord(device, start: true) } }
                Button("촬영 정지") { Task { await studio.bridgeRecord(device, start: false) } }
            }
        case .gopro:
            EmptyView()
        case .osmoAction:
            Section("이 카메라만") {
                Button("녹화 시작") { osmoRecord(device, true) }
                Button("녹화 정지") { osmoRecord(device, false) }
            }
        case .osmoNoAPI:
            Section("제어 불가") {
                Text(Honest.noAPI)
            }
        }
    }

    private func shutter(_ device: DeviceRecord, _ start: Bool) {
        Task { await studio.gopro(device, { try await GoProClient.shutter($0, start: start) }, label: start ? "셔터 시작" : "셔터 정지") }
    }

    private func osmoRecord(_ device: DeviceRecord, _ start: Bool) {
        Task {
            if studio.profile.practice {
                studio.note("연습: \(device.name) \(start ? "시작" : "정지")")
            } else {
                studio.note((await studio.radio.record(device, start: start)).text)
            }
        }
    }
}
