import SwiftUI

/// 아이폰 무대입니다. 가운데 위는 방, 아래는 조작대, 오른쪽은 고른 장치입니다.
struct LiveStageView: View {
    var deviceId: UUID?
    @Binding var selected: UUID?
    @Binding var selectedCamera: UUID?
    @Binding var showSettings: Bool

    var body: some View {
        StageConsole(initialId: deviceId, selected: $selected, selectedCamera: $selectedCamera, showSettings: $showSettings)
            .navigationTitle("무대")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbarBackground(StagePalette.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .preferredColorScheme(.light)
    }
}

/// 가운데를 위아래로 반씩 나눕니다. 위는 방, 아래 가운데는 조작대, 오른쪽은 상태입니다.
struct StageConsole: View {
    @EnvironmentObject private var studio: Studio
    var initialId: UUID?
    @Binding var selected: UUID?
    @Binding var selectedCamera: UUID?
    @Binding var showSettings: Bool

    @StateObject private var preview = GoProPreview()
    @State private var sticks: [UUID: CGSize] = [:]
    @State private var settingChoices: [Int: Int] = [:]
    @State private var osmoMode = 0x01
    @State private var zoom = 0.0

    private var device: DeviceRecord? {
        guard let selected else { return nil }
        return studio.profile.devices.first { $0.id == selected }
    }

    private var focusedCamera: BridgeCameraSlot? {
        guard let selectedCamera, let device else { return nil }
        return device.cameras.first { $0.id == selectedCamera }
    }

    private var bottomHint: String {
        if device == nil {
            return "무대에서 로닌을 누르면 아래에 휠 두 개가 나옵니다."
        }
        if device?.kind == .goproBridge, focusedCamera == nil {
            return "왼쪽에서 카메라 한 대를 고르세요. 촬영과 설정은 그 카메라만 따릅니다."
        }
        return "이 장치에는 짐벌 휠이 없습니다."
    }

    /// 무대에서 장치를 누르면 카메라 선택은 풀립니다. 목록의 카메라 선택은 그대로 둡니다.
    private var stagePick: Binding<UUID?> {
        Binding(
            get: { selected },
            set: { newValue in
                selected = newValue
                selectedCamera = nil
            }
        )
    }

    /// 화각은 기판이 갈 수 있는 각도 안에 둡니다. 각도가 오면 그 값을 쓰고, 없으면 스틱이 끝 각도까지 미리 보여 줍니다.
    private var drives: [StageDrive] {
        studio.profile.devices.compactMap { device in
            guard device.kind == .ronin else { return nil }
            let spot = studio.stageSpot(for: device.id)
            let stick = sticks[device.id] ?? .zero
            let live = studio.roninLive[device.id]
            let gimbalYaw: Double
            let firmwarePitch: Double
            if live?.attitudeValid == true, let yaw = live?.yaw, let pitch = live?.pitch {
                gimbalYaw = RoninTravel.clampYaw(yaw)
                firmwarePitch = RoninTravel.clampPitch(pitch)
            } else if hypot(stick.width, stick.height) > 0.08 {
                gimbalYaw = RoninTravel.yaw(from: spot.homeYaw, cameraRight: Double(stick.width))
                firmwarePitch = RoninTravel.pitch(from: spot.homePitch, cameraUp: -Double(stick.height))
            } else {
                gimbalYaw = RoninTravel.clampYaw(spot.homeYaw)
                firmwarePitch = RoninTravel.clampPitch(spot.homePitch)
            }
            return StageDrive(
                deviceId: device.id,
                yaw: spot.aimYaw + gimbalYaw,
                pitch: RoninTravel.roomPitch(firmwarePitch: firmwarePitch)
            )
        }
    }

    var body: some View {
        GeometryReader { geo in
            let side = sideWidth(geo.size.width)
            let center = max(0, geo.size.width - side)
            let half = geo.size.height / 2
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    StageBoard(selection: stagePick, drives: drives)
                        .frame(width: center, height: half)
                    bottomHalf(width: center, height: half)
                }
                .frame(width: center, height: geo.size.height)
                sidePanel()
                    .frame(width: side, height: geo.size.height)
                    .background(StagePalette.paper)
            }
            .background(StagePalette.paper)
        }
        .background(StagePalette.paper)
        .foregroundStyle(StagePalette.ink)
        .preferredColorScheme(.light)
        .onAppear {
            if selected == nil {
                selected = initialId ?? studio.profile.devices.first?.id
            }
        }
        .onChange(of: studio.profile.devices.map(\.id)) { _, ids in
            if let selected, !ids.contains(selected) {
                self.selected = ids.first
                selectedCamera = nil
            }
        }
        .onChange(of: device?.cameras.map(\.id) ?? []) { _, ids in
            if let selectedCamera, !ids.contains(selectedCamera) {
                self.selectedCamera = nil
            }
        }
        .sheet(isPresented: $showSettings) {
            settingsSheet
                .stagePopup()
        }
        .task(id: device?.id) {
            guard let device, device.kind.supportsLiveView else {
                preview.stop()
                return
            }
            if studio.profile.practice {
                preview.stop()
                preview.note = "연습 모드입니다. 미리보기를 받지 않습니다."
                return
            }
            preview.open(device)
            do {
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch {
                preview.stop()
            }
        }
    }

    /// 좁은 화면은 오른쪽을 조금 줄여 아래 휠이 남게 합니다.
    private func sideWidth(_ width: CGFloat) -> CGFloat {
        if width < 700 {
            return min(180, max(148, width * 0.36))
        }
        return min(340, max(240, width * 0.30))
    }

    private func bottomHalf(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 4) {
            if let device, device.kind.supportsLiveView {
                HStack(alignment: .center, spacing: 8) {
                    livePicture(height: max(80, height - 16))
                    shootControls
                }
            } else if let device, device.kind == .ronin {
                roninController(device, height: max(72, height - 16))
            } else {
                HStack(alignment: .center, spacing: 8) {
                    Text(bottomHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    shootControls
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: width, height: height)
        .background(StagePalette.paper)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(StagePalette.ink.opacity(0.2))
                .frame(height: 1)
        }
    }

    /// 화면 아래 가운데에 있던 조작대입니다. 드론 모드 2처럼 휠은 두 개입니다.
    private func roninController(_ device: DeviceRecord, height: CGFloat) -> some View {
        let diameter = min(150, max(64, height - 28))
        return HStack(alignment: .center, spacing: 8) {
            VStack(spacing: 2) {
                Text("방향")
                    .font(.caption2.weight(.semibold))
                RoninStick(device: device, diameter: diameter, job: .panTilt) { vector in
                    if hypot(vector.width, vector.height) > 0.08 {
                        sticks[device.id] = vector
                    } else {
                        sticks[device.id] = nil
                    }
                }
                Text("카메라 위 · 아래 · 좌 · 우")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("떼도 그 방향")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                RoninCommandBoard(device: device)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 2) {
                Text("줌")
                    .font(.caption2.weight(.semibold))
                RoninStick(device: device, diameter: diameter, job: .zoom)
                Text("위아래 줌")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("좌우는 슬라이드")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var shootControls: some View {
        if let device {
            VStack(spacing: 6) {
                switch device.kind {
                case .ronin:
                    Button("녹화") { Task { await studio.ronin(device, path: "/record", query: ["action": "start"]) } }
                    Button("정지") { Task { await studio.ronin(device, path: "/record", query: ["action": "stop"]) } }
                    Button("셔터") { Task { await studio.ronin(device, path: "/photo") } }
                    Button("제자리") { goHome(device) }
                case .gopro, .goproAction5:
                    Button("셔터") { shutter(device, true) }
                    Button("정지") { shutter(device, false) }
                case .goproBridge:
                    if let camera = focusedCamera {
                        Button("촬영") { Task { await studio.bridgeSlot(device, cameraId: camera.id, start: true) } }
                        Button("정지") { Task { await studio.bridgeSlot(device, cameraId: camera.id, start: false) } }
                    } else {
                        Text("카메라 한 대")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                case .osmoAction:
                    Button("녹화") { osmoRecord(device, true) }
                    Button("정지") { osmoRecord(device, false) }
                case .osmoNoAPI:
                    Text("촬영 없음")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.bordered)
            .font(.caption.weight(.semibold))
        } else {
            Text("장치 없음")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func sidePanel() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let device {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        GearHeader(device: device, camera: focusedCamera)
                        Text(device.name)
                            .font(.headline)
                        Button("설정") { showSettings = true }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        Text(device.linkLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        statusBlock(device)
                            .font(.caption2)
                        Text("자리")
                            .font(.caption.weight(.semibold))
                        StagePlacementControls(deviceId: device.id)
                        settingsBlock(device)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
            } else {
                Text("무대에서 장치를 누르면 상태가 여기에 나옵니다. 설정은 작은 창으로 엽니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
        }
    }

    private func livePicture(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("실시간 그림")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.top, 8)
            ZStack {
                StagePalette.paper
                if let image = preview.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text(preview.note.isEmpty ? "카메라 영상을 기다리는 중입니다." : preview.note)
                        .font(.caption2)
                        .foregroundStyle(StagePalette.ink)
                        .multilineTextAlignment(.center)
                        .padding(8)
                }
            }
            .overlay(Rectangle().stroke(StagePalette.ink.opacity(0.35), lineWidth: 1))
            .frame(maxWidth: .infinity)
            .frame(height: height)
        }
    }

    @ViewBuilder private func statusBlock(_ device: DeviceRecord) -> some View {
        switch device.kind {
        case .ronin:
            if let status = studio.roninLive[device.id] {
                Text("랜 \(status.ethLink == true ? "연결" : "끊김")  CAN \(status.twai ?? "-")")
                Text(String(format: "요 %.1f  롤 %.1f  피치 %.1f", status.yaw ?? 0, status.roll ?? 0, status.pitch ?? 0))
                Text("자세 \(status.attitudeValid == true ? "유효" : "없음")")
                Text("녹화 명령 \(status.camRecording == true ? "시작" : "정지")")
                Text("소니 녹화 \(status.sonyRecording == true ? "켜짐" : "꺼짐")")
            } else {
                Text("아직 상태를 읽지 못했습니다.")
            }
        case .goproBridge:
            if let camera = focusedCamera {
                Text(camera.role.title)
                Text(BoardMac.isFull(camera.mac) ? BoardMac.normalize(camera.mac) : "맥 없음")
                Text(studio.bridgeLive[device.id]?.attachment(for: camera) ?? "아직 읽지 못했습니다.")
            } else {
                Text(studio.bridgePhase[device.id] ?? "기판을 찾는 중입니다.")
                Text("왼쪽에서 카메라 한 대를 고르세요.")
            }
        case .gopro, .goproAction5:
            Text(studio.goproSession[device.id] ?? "세션을 아직 확인하지 않았습니다.")
            if let live = studio.goproLive[device.id] {
                if device.kind == .gopro {
                    Text("녹화 중 \(live.encoding == true ? "예" : "아니오")  바쁨 \(live.busy == true ? "예" : "아니오")")
                    Text("남은 영상 \(live.remainingVideo.map(String.init) ?? "-")  남은 사진 \(live.remainingPhotos.map(String.init) ?? "-")")
                }
                if device.kind == .goproAction5, !live.relayBle.isEmpty {
                    Text(live.relayBle)
                }
                if !live.error.isEmpty {
                    Text(live.error).foregroundStyle(.orange)
                }
            }
        case .osmoAction:
            if let live = studio.radio.live[device.id] {
                Text(live.phase)
                Text("모드 \(live.mode.map(OsmoCatalog.modeName) ?? "-")")
                Text("상태 \(live.status.map(OsmoCatalog.statusName) ?? "-")")
                Text("해상도 \(live.resolution.map(OsmoCatalog.resolutionName) ?? "-")  프레임 \(live.fps.map(OsmoCatalog.fpsName) ?? "-")")
                Text("배터리 \(live.battery.map(String.init) ?? "-")")
                if !live.lastError.isEmpty { Text(live.lastError).foregroundStyle(.orange) }
            } else {
                Text("아직 상태가 없습니다.")
            }
        case .osmoNoAPI:
            Text(Honest.noAPI)
        }
    }

    @ViewBuilder private func settingsBlock(_ device: DeviceRecord) -> some View {
        switch device.kind {
        case .ronin:
            roninSettings(device)
        case .goproBridge:
            Text("설정")
                .font(.caption.weight(.semibold))
            Text(focusedCamera == nil ? "기판만 고른 상태입니다. 카메라 설정은 고른 카메라만 엽니다." : "이 카메라의 설정만 작은 창으로 엽니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .gopro, .goproAction5:
            Text("설정")
                .font(.caption.weight(.semibold))
            ForEach(GoProCatalog.settings) { spec in
                VStack(alignment: .leading, spacing: 4) {
                    Text(spec.title).font(.caption.weight(.semibold))
                    if let current = studio.goproLive[device.id]?.settings[spec.id] {
                        Text("카메라 값 \(current)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Picker(spec.title, selection: choiceBinding(spec)) {
                        ForEach(spec.options) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                    Button("보내기") {
                        let option = settingChoices[spec.id] ?? spec.options[0].value
                        Task {
                            await studio.gopro(device, { try await GoProClient.setSetting($0, setting: spec.id, option: option) }, label: spec.title)
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption2)
                }
            }
            if device.kind == .gopro {
                Text("디지털 줌 \(Int(zoom))%")
                    .font(.caption2)
                Slider(value: $zoom, in: 0...100, step: 1)
                Button("줌 보내기") {
                    Task { await studio.gopro(device, { try await GoProClient.digitalZoom($0, percent: Int(zoom)) }, label: "디지털 줌") }
                }
                .buttonStyle(.bordered)
                .font(.caption2)
            }
        case .osmoAction:
            Text("모드")
                .font(.caption.weight(.semibold))
            Picker("모드", selection: $osmoMode) {
                ForEach(OsmoCatalog.writableModes(for: device.osmoModel), id: \.0) { item in
                    Text(item.1).tag(item.0)
                }
            }
            .pickerStyle(.menu)
            Button("모드 보내기") {
                Task {
                    if studio.profile.practice {
                        studio.note("연습: \(device.name) 모드")
                    } else {
                        studio.note((await studio.radio.setMode(device, mode: osmoMode)).text)
                    }
                }
            }
            .buttonStyle(.bordered)
            .font(.caption2)
        case .osmoNoAPI:
            EmptyView()
        }
    }

    @ViewBuilder private func roninSettings(_ device: DeviceRecord) -> some View {
        let spot = studio.stageSpot(for: device.id)
        Text("제자리")
            .font(.caption.weight(.semibold))
        Text("화각은 기판이 가는 각도입니다. 요는 -180°에서 180°, 피치는 -56°에서 146°까지입니다.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        Text(String(format: "저장값 요 %.0f°  피치 %.0f°", spot.homeYaw, spot.homePitch))
            .font(.caption2)
            .monospacedDigit()
        HStack {
            Text("요")
                .frame(width: 28, alignment: .leading)
            Slider(
                value: Binding(
                    get: { spot.homeYaw },
                    set: { studio.moveStage(deviceId: device.id, homeYaw: $0) }
                ),
                in: RoninTravel.yawMin...RoninTravel.yawMax
            )
        }
        .font(.caption2)
        HStack {
            Text("피치")
                .frame(width: 28, alignment: .leading)
            Slider(
                value: Binding(
                    get: { spot.homePitch },
                    set: { studio.moveStage(deviceId: device.id, homePitch: $0) }
                ),
                in: RoninTravel.pitchMin...RoninTravel.pitchMax
            )
        }
        .font(.caption2)
        Button("제자리") { goHome(device) }
            .buttonStyle(.bordered)
            .font(.caption2)
        Button("지금 각도를 제자리로 기억") { rememberHome(device) }
            .buttonStyle(.bordered)
            .font(.caption2)
        Text("명령 버튼과 휠은 아래 가운데에 있습니다.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func choiceBinding(_ spec: GoProSettingSpec) -> Binding<Int> {
        Binding(
            get: { settingChoices[spec.id] ?? spec.options[0].value },
            set: { settingChoices[spec.id] = $0 }
        )
    }

    private func shutter(_ device: DeviceRecord, _ start: Bool) {
        Task {
            await studio.gopro(device, { try await GoProClient.shutter($0, start: start) }, label: start ? "셔터 시작" : "셔터 정지")
        }
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

    /// 저장해 둔 제자리로 절대 이동합니다. 롤은 0이고, 각도는 기판이 받는 범위로 자릅니다.
    private func goHome(_ device: DeviceRecord) {
        let spot = studio.stageSpot(for: device.id)
        let yaw = RoninTravel.clampYaw(spot.homeYaw)
        let pitch = RoninTravel.clampPitch(spot.homePitch)
        Task {
            await studio.ronin(device, path: "/move", query: [
                "yaw": String(format: "%.2f", yaw),
                "roll": "0",
                "pitch": String(format: "%.2f", pitch),
                "time": "1.2",
            ])
        }
    }

    /// 기판이 지금 알려 준 요·피치를 이 짐벌의 제자리로 기억합니다.
    private func rememberHome(_ device: DeviceRecord) {
        guard let status = studio.roninLive[device.id], status.attitudeValid == true,
              let yaw = status.yaw, let pitch = status.pitch else {
            studio.note("\(device.name) 각도를 아직 받지 못해 제자리로 기억하지 못했습니다.")
            return
        }
        studio.moveStage(deviceId: device.id, homeYaw: yaw, homePitch: pitch)
        studio.note(String(format: "%@ 제자리 요 %.1f° 피치 %.1f°", device.name, yaw, pitch))
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                if let device {
                    DeviceForm(radio: studio.radio, deviceId: device.id, cameraId: selectedCamera)
                    switch device.kind {
                    case .ronin:
                        if selectedCamera == nil {
                            RoninDeck(deviceId: device.id)
                        }
                    case .gopro, .goproAction5:
                        if selectedCamera == nil {
                            GoProDeck(deviceId: device.id)
                        }
                    case .goproBridge:
                        EmptyView()
                    case .osmoAction, .osmoNoAPI:
                        if selectedCamera == nil {
                            OsmoDeck(radio: studio.radio, deviceId: device.id)
                        }
                    }
                    Section {
                        if let camera = focusedCamera {
                            Button("이 카메라 삭제", role: .destructive) {
                                studio.deleteCamera(device.id, camera.id)
                                selectedCamera = nil
                                showSettings = false
                            }
                        } else {
                            Button("이 장치 삭제", role: .destructive) {
                                let id = device.id
                                studio.deleteDevice(id)
                                showSettings = false
                                if selected == id { selected = nil }
                                selectedCamera = nil
                            }
                        }
                    }
                } else {
                    Text("무대에서 장치를 먼저 고르세요.")
                }
            }
            .navigationTitle(focusedCamera?.role.title ?? "설정")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("닫기") { showSettings = false }
            }
        }
    }
}

extension View {
    @ViewBuilder func stagePopup() -> some View {
        #if os(iOS)
        self.presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #else
        self.frame(minWidth: 460, minHeight: 520)
        #endif
    }
}
