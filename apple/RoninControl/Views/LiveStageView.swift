import SwiftUI

/// 아이폰 무대입니다. 가운데 위는 방, 아래는 휠과 촬영, 오른쪽은 고른 장치입니다.
struct LiveStageView: View {
    var deviceId: UUID?
    @Binding var wheelIds: [UUID]

    var body: some View {
        StageConsole(initialId: deviceId, wheelIds: $wheelIds, showsWheels: true)
            .navigationTitle("무대")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(StagePalette.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .preferredColorScheme(.light)
    }
}

/// 가운데를 위아래로 반씩 나눕니다. 위는 방, 아래는 휠과 촬영, 오른쪽은 상태와 설정입니다.
struct StageConsole: View {
    @EnvironmentObject private var studio: Studio
    var initialId: UUID?
    @Binding var wheelIds: [UUID]
    var showsWheels: Bool

    @StateObject private var preview = GoProPreview()
    @State private var selected: UUID?
    @State private var nudges: [UUID: GimbalNudge] = [:]
    @State private var settingChoices: [Int: Int] = [:]
    @State private var osmoMode = 0x01
    @State private var zoom = 0.0

    private var device: DeviceRecord? {
        guard let selected else { return nil }
        return studio.profile.devices.first { $0.id == selected }
    }

    private var wheels: [DeviceRecord] {
        guard showsWheels else { return [] }
        return wheelIds.compactMap { id in
            studio.profile.devices.first { $0.id == id && $0.kind == .ronin }
        }
    }

    private var drives: [StageDrive] {
        nudges.compactMap { id, nudge in
            guard studio.profile.devices.contains(where: { $0.id == id && $0.kind == .ronin }) else { return nil }
            let spot = studio.stageSpot(for: id)
            let status = studio.roninLive[id]
            return StageDrive(
                deviceId: id,
                yaw: spot.aimYaw + headYaw(status, nudge, home: spot.homeYaw),
                pitch: headPitch(status, nudge, home: spot.homePitch)
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
                    StageBoard(selection: $selected, drives: drives)
                        .frame(width: center, height: half)
                    bottomHalf(width: center, height: half)
                }
                .frame(width: center, height: geo.size.height)
                sidePanel(height: geo.size.height)
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
            wheelIds.removeAll { !ids.contains($0) }
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
        let picker: CGFloat = showsWheels ? 34 : 0
        let wheelBand = max(64, height - picker - 14)
        return VStack(spacing: 4) {
            if showsWheels {
                wheelPicker
            }
            HStack(alignment: .center, spacing: 8) {
                if showsWheels {
                    wheelRow(width: max(72, width - 96), height: wheelBand)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                shootControls
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var wheelPicker: some View {
        let ronins = studio.profile.devices.filter { $0.kind == .ronin }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if ronins.isEmpty {
                    Text("등록된 로닌이 없습니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(ronins) { item in
                    let on = wheelIds.contains(item.id)
                    Button {
                        toggleWheel(item.id)
                    } label: {
                        Text(item.name)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .foregroundStyle(StagePalette.ink)
                            .background(on ? StagePalette.brass.opacity(0.35) : Color.white.opacity(0.7), in: Capsule())
                            .overlay(Capsule().stroke(StagePalette.ink.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(on ? "\(item.name) 휠 빼기" : "\(item.name) 휠에 넣기")
                }
            }
        }
        .frame(height: 30)
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
                    Button("촬영") { Task { await studio.bridgeRecord(device, start: true) } }
                    Button("정지") { Task { await studio.bridgeRecord(device, start: false) } }
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

    private func sidePanel(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let device {
                if device.kind.supportsLiveView {
                    livePicture(height: max(150, height * 0.34))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(device.name)
                            .font(.headline)
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
                Text("무대에서 장치를 누르면 상태와 설정이 여기에 나옵니다.")
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
            BridgeAttachmentList(device: device)
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
            Text("카메라 칸은 장치 설정에서 바꿉니다. 여기에는 지금 붙었는지가 바로 나옵니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            BridgeAttachmentList(device: device)
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
        Text("화각은 이 각도를 기준으로 그립니다. 제자리는 짐벌을 이 각도로 되돌립니다.")
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
                in: -180...180
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
                in: -180...180
            )
        }
        .font(.caption2)
        Button("제자리") { goHome(device) }
            .buttonStyle(.bordered)
            .font(.caption2)
        Button("지금 각도를 제자리로 기억") { rememberHome(device) }
            .buttonStyle(.bordered)
            .font(.caption2)
        Text("기판에 고정된 자세")
            .font(.caption.weight(.semibold))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)]) {
            Button("정면") { Task { await studio.ronin(device, path: "/preset/front") } }
            Button("아래") { Task { await studio.ronin(device, path: "/preset/down") } }
            Button("위") { Task { await studio.ronin(device, path: "/preset/up") } }
            Button("중앙") { Task { await studio.ronin(device, path: "/recenter") } }
        }
        .buttonStyle(.bordered)
        .font(.caption2)
        Text("기판 샷")
            .font(.caption.weight(.semibold))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)]) {
            ForEach(studio.shotNames, id: \.self) { name in
                Button(RoninCatalog.title(name)) {
                    Task { await studio.ronin(device, path: "/shot/\(name)", query: ["t": "1.00"]) }
                }
                .buttonStyle(.bordered)
                .font(.caption2)
            }
        }
        Text("저장된 프리셋")
            .font(.caption.weight(.semibold))
        if studio.profile.presets.isEmpty {
            Text("저장된 프리셋이 없습니다. 맥이나 아이패드에서 만듭니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 6)]) {
                ForEach(studio.profile.presets) { preset in
                    Button(preset.name) {
                        Task { await studio.applyRoninLook(preset, to: device) }
                    }
                    .buttonStyle(.bordered)
                    .font(.caption2)
                }
            }
        }
    }

    @ViewBuilder private func wheelRow(width: CGFloat, height: CGFloat) -> some View {
        let items = wheels
        if items.isEmpty {
            Text("아래 이름에서 로닌을 고르면 휠이 나옵니다. 최대 4대입니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let diameter = wheelSize(items.count, width: width, height: height)
            HStack(alignment: .center, spacing: 8) {
                ForEach(items) { device in
                    VStack(spacing: 4) {
                        GimbalWheel(title: device.name, diameter: diameter) { nudge in
                            if let nudge {
                                nudges[device.id] = nudge
                            } else {
                                nudges[device.id] = nil
                            }
                            Task { await studio.roninHold(device, path: nudge?.path) }
                        }
                        Button("제자리") { goHome(device) }
                            .buttonStyle(.bordered)
                            .font(.caption2)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func wheelSize(_ count: Int, width: CGFloat, height: CGFloat) -> CGFloat {
        let gaps = CGFloat(max(count - 1, 0)) * 8
        let fit = (width - gaps) / CGFloat(max(count, 1))
        let tall = height - 52
        return min(220, max(36, min(fit, tall)))
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

    /// 저장해 둔 제자리로 절대 이동합니다. 롤은 0입니다.
    private func goHome(_ device: DeviceRecord) {
        let spot = studio.stageSpot(for: device.id)
        Task {
            await studio.ronin(device, path: "/move", query: [
                "yaw": String(format: "%.2f", spot.homeYaw),
                "roll": "0",
                "pitch": String(format: "%.2f", spot.homePitch),
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

    /// 기판이 각도를 주면 그 값을 씁니다. 없을 때는 제자리에서 누르고 있는 방향으로 12°를 그립니다.
    /// 위 버튼은 기판에 음수 피치를 보내므로, 그림의 위는 그 값의 반대입니다.
    private func headYaw(_ status: RoninStatus?, _ nudge: GimbalNudge, home: Double) -> Double {
        if status?.attitudeValid == true, let yaw = status?.yaw { return yaw }
        switch nudge {
        case .left: return home - 12
        case .right: return home + 12
        case .up, .down: return home
        }
    }

    private func headPitch(_ status: RoninStatus?, _ nudge: GimbalNudge, home: Double) -> Double {
        if status?.attitudeValid == true, let pitch = status?.pitch { return -pitch }
        switch nudge {
        case .up: return -home + 12
        case .down: return -home - 12
        case .left, .right: return -home
        }
    }
}

private enum GimbalNudge {
    case up, down, left, right

    /// 기판이 이미 받는 조그 주소입니다. 롤·줌·포커스는 이 휠에서 보내지 않습니다.
    var path: String {
        switch self {
        case .up: return "/jog/pitch/up"
        case .down: return "/jog/pitch/down"
        case .left: return "/jog/yaw/left"
        case .right: return "/jog/yaw/right"
        }
    }
}

/// 가운데 버튼이 있는 작은 원형 휠입니다. 한 대 로닌의 좌우·상하만 움직입니다.
private struct GimbalWheel: View {
    var title: String
    var diameter: CGFloat
    var onNudge: (GimbalNudge?) -> Void

    @State private var sent: GimbalNudge?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(StagePalette.paper)
                Circle()
                    .stroke(StagePalette.ink, lineWidth: 2)
                chevron("chevron.up", .up, y: -1)
                chevron("chevron.down", .down, y: 1)
                chevron("chevron.left", .left, x: -1)
                chevron("chevron.right", .right, x: 1)
                Button {
                    sent = nil
                    onNudge(nil)
                } label: {
                    Circle()
                        .fill(StagePalette.brass.opacity(0.85))
                        .frame(width: diameter * 0.32, height: diameter * 0.32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title) 정지")
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let next = direction(value.translation)
                        guard next != sent else { return }
                        sent = next
                        onNudge(next)
                    }
                    .onEnded { _ in
                        sent = nil
                        onNudge(nil)
                    }
            )
            Text(title)
                .font(.caption2)
                .foregroundStyle(StagePalette.ink)
                .lineLimit(1)
                .frame(width: diameter)
        }
    }

    private func chevron(_ name: String, _ nudge: GimbalNudge, x: CGFloat = 0, y: CGFloat = 0) -> some View {
        Image(systemName: name)
            .font(.system(size: max(9, diameter * 0.12), weight: .bold))
            .foregroundStyle(sent == nudge ? StagePalette.oxblood : StagePalette.ink)
            .offset(x: x * diameter * 0.32, y: y * diameter * 0.32)
            .allowsHitTesting(false)
    }

    private func direction(_ translation: CGSize) -> GimbalNudge? {
        let reach = hypot(translation.width, translation.height)
        guard reach > diameter * 0.18 else { return nil }
        if abs(translation.width) > abs(translation.height) {
            return translation.width < 0 ? .left : .right
        }
        return translation.height < 0 ? .up : .down
    }
}
