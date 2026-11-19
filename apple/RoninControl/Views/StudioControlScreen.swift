import AVKit
import SwiftUI

/// 맥, 아이패드, 아이폰이 같이 여는 스튜디오 화면입니다. 위 운송, 왼쪽 목록, 가운데 평면도, 아래 그림, 오른쪽 검사입니다.
struct StudioControlScreen: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var link: BoardSocket
    @EnvironmentObject private var c3Link: C3JobSocket
    @State private var pick: DeskPick = .olimex
    @State private var askC3Job = false
    @State private var fov = "와이드"
    @State private var resolution = "1080p"
    @State private var yaw = 0.0
    @State private var pitch = 0.0
    @State private var lightLevel: [UUID: Double] = [:]
    @State private var lightKelvin: [UUID: Double] = [:]
    /// 카메라 자리입니다. x는 좌우 미터, y는 무대에서 객석 쪽 깊이 미터입니다.
    @State private var cameraMeters: [String: CGPoint] = [:]
    @State private var showJoin = false
    @State private var showPtz = false
    @State private var ptzHost = "192.168.10.203"
    @State private var ptzName = "PTZ"
    @State private var ptzOnvif = "2000"
    @State private var ptzVisca = "1259"
    @State private var ptzMac = "E4:77:D4:07:0A:5A"
    @State private var ptzUser = ""
    @State private var ptzPassword = ""
    @State private var ptzFound: [Onvif.Found] = []
    @State private var ptzSearching = false
    @State private var ptzPose: [UUID: PtzPose] = [:]
    @State private var ptzOnline: Set<UUID> = []
    @State private var floorTool: FloorTool = .look
    @State private var ptzDrive: Task<Void, Never>?
    @State private var ptzSent = Date.distantPast
    @State private var stickSpeed = 0.45
    @State private var absoluteTask: Task<Void, Never>?
    @State private var absolutePending: (PtzRecord, Double, Double, Double)?
    @State private var roninTask: Task<Void, Never>?
    @State private var roninPending: (Double, Double)?

    private let ink = Color(red: 0.93, green: 0.94, blue: 0.95)
    private let panel = Color(red: 0.11, green: 0.12, blue: 0.14)
    private let canvas = Color(red: 0.07, green: 0.08, blue: 0.09)
    private let line = Color.white.opacity(0.14)
    private let record = Color(red: 0.86, green: 0.28, blue: 0.28)

    var body: some View {
        VStack(spacing: 0) {
            transport
            GeometryReader { geo in
                if geo.size.width < 760 {
                    ScrollView {
                        VStack(spacing: 0) {
                            deviceList.frame(minHeight: 240)
                            floor.frame(height: 300)
                            liveStrip.frame(height: 150)
                            inspector.frame(minHeight: 260)
                        }
                    }
                } else {
                    HStack(spacing: 0) {
                        deviceList.frame(width: min(280, geo.size.width * 0.24))
                        VStack(spacing: 0) {
                            floor
                            liveStrip.frame(height: 168)
                        }
                        inspector.frame(width: min(320, geo.size.width * 0.26))
                    }
                }
            }
        }
        .background(canvas)
        .foregroundStyle(ink)
        .preferredColorScheme(.dark)
        .confirmationDialog("이 C3 의 일", isPresented: $askC3Job, titleVisibility: .visible) {
            Button("로닌 제어") { studio.registerC3(.ronin) }
            Button("조명 · 울란지 VL120BI") { studio.registerC3(.light) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("한 대는 고른 일만 합니다. 액션 카메라는 올리멕스 기판에 남습니다.")
        }
        .sheet(isPresented: $showJoin) {
            FirstJoinSheet { kind, host, port, radios, name in
                studio.adoptLan(kind, host: host, port: port, radios: radios, name: name)
            }
        }
        .onChange(of: link.wifiMac) { _, _ in
            studio.rememberOlimex(wifi: link.wifiMac, ethernet: link.ethMac, hotspot: link.apMac)
        }
        .onChange(of: link.ethMac) { _, _ in
            studio.rememberOlimex(wifi: link.wifiMac, ethernet: link.ethMac, hotspot: link.apMac)
        }
        .onChange(of: c3Link.wifiMac) { _, _ in
            if let id = c3Link.boardId { studio.rememberC3(id, wifi: c3Link.wifiMac, hotspot: c3Link.apMac) }
        }
        .sheet(isPresented: $showPtz) {
            ptzSheet
        }
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(recordCount)
                    .font(.headline)
                    .foregroundStyle(link.state == .online ? record : ink)
                Text(link.state == .online ? link.detail : "오프라인")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("연결", selection: Binding(get: { link.lane }, set: { studio.chooseLane($0) })) {
                    ForEach(BoardLane.allCases) { lane in
                        Text(lane.title).tag(lane)
                    }
                }
                .pickerStyle(.menu)
                Button(link.state == .connecting ? "연결 중" : "지금 연결") {
                    studio.reconnectOlimex()
                }
                .buttonStyle(DeskButtonStyle(selected: link.state == .online || link.state == .connecting))
                .disabled(link.state == .connecting || !studio.profile.olimexRegistered || !link.lane.shoots)
                Button("모두 녹화") { Task { await studio.fieldRecord(group: "all", start: true) } }
                    .buttonStyle(DeskButtonStyle(tone: .record))
                Button("모두 정지") { Task { await studio.fieldRecord(group: "all", start: false) } }
                    .buttonStyle(DeskButtonStyle(tone: .stop))
            }
            HStack(spacing: 8) {
                ForEach(["A", "B", "C"], id: \.self) { name in
                    Button("\(name) 녹화") { Task { await studio.fieldRecord(group: name, start: true) } }
                        .buttonStyle(DeskButtonStyle(tone: .record))
                    Button("\(name) 정지") { Task { await studio.fieldRecord(group: name, start: false) } }
                        .buttonStyle(DeskButtonStyle(tone: .stop))
                }
                Spacer()
                Menu {
                    Button("올리멕스 ESP32-PoE") { studio.registerOlimex() }
                    Button("C3") { askC3Job = true }
                    Button("PTZ 카메라") { showPtz = true }
                } label: {
                    Text("기판 등록")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.45), lineWidth: 1))
                }
                Button("처음 연결") { showJoin = true }
                    .buttonStyle(DeskButtonStyle())
            }
            .font(.caption)
        }
        .padding(12)
        .background(panel)
        .overlay(alignment: .bottom) { Rectangle().fill(line).frame(height: 1) }
    }

    private var recordCount: String {
        guard link.state == .online, let count = link.reportedRecording else { return "오프라인" }
        return "녹화 \(count)"
    }

    private var deviceList: some View {
        List {
            Section("올리멕스") {
                Button {
                    pick = .olimex
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(studio.profile.olimexRegistered ? studio.olimexTitle : "아직 등록하지 않음", systemImage: "server.rack")
                        Text(studio.profile.olimexRegistered ? "\(link.lane.title) · \(link.state == .online ? "온라인 \(link.endpoint)" : "오프라인")" : "연결을 고르세요")
                        Text("녹화 \(link.reportedRecording == nil ? "모름" : "기판 보고") · HDMI/USB 모름")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(DeskButtonStyle(selected: pick == .olimex, expand: true))
                .listRowBackground(pick == .olimex ? Color.white.opacity(0.08) : Color.clear)
            }
            Section("C3") {
                if studio.profile.c3Boards.isEmpty {
                    Text("등록하면 로닌 또는 조명 중 하나만 맡습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(studio.profile.c3Boards) { board in
                    Button {
                        pick = .c3(board.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(board.name, systemImage: board.duty == .light ? "lightbulb.fill" : "rotate.3d")
                            Text("\(board.duty.title) · \(board.link.title) · \(c3Link.boardId == board.id && c3Link.state == .online ? "온라인" : "오프라인")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(DeskButtonStyle(selected: pick == .c3(board.id), expand: true))
                    .listRowBackground(pick == .c3(board.id) ? Color.white.opacity(0.08) : Color.clear)
                    .swipeActions {
                        Button("삭제", role: .destructive) { studio.deleteC3(board.id) }
                    }
                }
            }
            Section("PTZ") {
                if studio.profile.ptzCameras.isEmpty {
                    Text("192.168.10.203 또는 같은 망 검색으로 넣습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(studio.profile.ptzCameras) { camera in
                    Button {
                        pick = .ptz(camera.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(camera.name, systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                            Text("\(camera.host) · \(ptzOnline.contains(camera.id) ? "온라인" : "오프라인") · 대기 · HDMI 모름")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(DeskButtonStyle(selected: pick == .ptz(camera.id), expand: true))
                    .listRowBackground(pick == .ptz(camera.id) ? Color.white.opacity(0.08) : Color.clear)
                    .swipeActions {
                        Button("삭제", role: .destructive) { studio.deletePtz(camera.id) }
                    }
                }
            }
            Section("액션 카메라") {
                if !studio.profile.olimexRegistered {
                    Text("올리멕스를 등록하면 여기 나옵니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if link.state != .online {
                    Text("올리멕스가 오프라인입니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if link.cameras.isEmpty {
                    Text("블루투스로 붙은 카메라가 없습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(link.cameras) { camera in
                        Button {
                            pick = .camera(camera.id)
                        } label: {
                            HStack {
                                Label(camera.name, systemImage: cameraSymbol(camera))
                                Spacer()
                                Text(link.state == .online ? "온라인 · 대기" : "오프라인")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(DeskButtonStyle(selected: pick == .camera(camera.id), expand: true))
                        .listRowBackground(pick == .camera(camera.id) ? Color.white.opacity(0.08) : Color.clear)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(panel)
    }

    private var selectedMark: String? {
        switch pick {
        case .olimex: return nil
        case .c3(let id): return id.uuidString
        case .camera(let id): return id
        case .ptz(let id): return id.uuidString
        }
    }

    private var floor: some View {
        FloorPlan(
            gimbal: studio.roninC3,
            cameras: link.cameras,
            meters: cameraMeters,
            selected: selectedMark,
            lens: LensLook(name: fov),
            liveYaw: yaw,
            livePitch: pitch,
            tool: floorTool,
            camerasOnline: link.state == .online,
            liveC3: c3Link.state == .online ? c3Link.boardId : nil,
            onTool: { floorTool = $0 },
            onMoveCamera: { id, x, y in cameraMeters[id] = CGPoint(x: x, y: y) },
            onMoveGimbal: { id, x, y in studio.moveStage(deviceId: id, x: x, y: y) },
            ptz: studio.profile.ptzCameras,
            ptzPose: ptzPose,
            ptzOnline: ptzOnline,
            onMovePtz: { id, x, y in studio.moveStage(deviceId: id, x: x, y: y) },
            onAim: { id, heading in aimOnStage(id, heading: heading) }
        )
        .onChange(of: link.tallyNote) { _, note in
            if !note.isEmpty { studio.note(note) }
        }
        .background(canvas)
    }

    private var liveStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if link.state != .online || link.cameras.isEmpty {
                    liveCell(title: "실시간 그림", note: link.state == .online ? "그림 없음" : "오프라인", url: nil)
                } else {
                    ForEach(link.cameras) { camera in
                        HonestPicture(title: camera.name, stream: camera.id)
                    }
                }
            }
            .padding(10)
        }
        .background(panel)
        .overlay(alignment: .top) { Rectangle().fill(line).frame(height: 1) }
    }

    private func liveCell(title: String, note: String, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            ZStack {
                Color.black
                if let url {
                    VideoPlayer(player: AVPlayer(url: url))
                } else {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 220, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch pick {
                case .olimex:
                    olimexInspector
                case .c3(let id):
                    if let board = studio.profile.c3Boards.first(where: { $0.id == id }) {
                        c3Inspector(board)
                    }
                case .camera(let id):
                    if let camera = link.cameras.first(where: { $0.id == id }) {
                        cameraInspector(camera)
                    }
                case .ptz(let id):
                    if let camera = studio.profile.ptzCameras.first(where: { $0.id == id }) {
                        ptzInspector(camera)
                    }
                }
                LogList()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(panel)
        .overlay(alignment: .leading) { Rectangle().fill(line).frame(width: 1) }
    }

    private var olimexInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("올리멕스 ESP32-PoE", systemImage: "server.rack")
                .font(.headline)
            TextField("기판 이름", text: Binding(get: { studio.profile.olimexName }, set: { studio.renameOlimex($0) }))
                .textFieldStyle(.roundedBorder)
            Text(studio.profile.olimexRegistered ? (link.state == .online ? "온라인" : "오프라인") : "등록 전")
                .font(.caption.weight(.semibold))
            Text("연결 방식 \(link.lane.title)")
            Text("주소 \(shownOlimexAddress)")
                .textSelection(.enabled)
            Text(macBlock(wifi: studio.profile.olimexWifiMac.isEmpty ? link.wifiMac : studio.profile.olimexWifiMac, ethernet: studio.profile.olimexEthMac.isEmpty ? link.ethMac : studio.profile.olimexEthMac, hotspot: studio.profile.olimexApMac.isEmpty ? link.apMac : studio.profile.olimexApMac))
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("공유기에서 고정 주소를 예약할 때 이 MAC을 적습니다. 와이파이는 와이파이 MAC, 랜 케이블은 이더넷 MAC 입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("액션 카메라는 이 기판 블루투스입니다. 로닌 짐벌은 로닌 제어 C3 가 맡습니다. 웹소켓이 열리기 전에는 온라인으로 두지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cameraSymbol(_ camera: BoardCamera) -> String {
        let text = (camera.kind + " " + camera.name).lowercased()
        if text.contains("insta") || camera.ble == "CE80" { return "pano" }
        if text.contains("osmo") || camera.ble == "FFF0" { return "video.fill" }
        return "camera.fill"
    }

    private var shownOlimexAddress: String {
        if link.state == .online { return link.endpoint }
        if !studio.profile.olimexLanHost.isEmpty { return "\(studio.profile.olimexLanHost):81" }
        return link.lane.detail
    }

    private func macBlock(wifi: String, ethernet: String, hotspot: String) -> String {
        let wifiText = wifi.isEmpty ? "아직 없음" : wifi
        let ethText = ethernet.isEmpty ? "아직 없음" : ethernet
        let apText = hotspot.isEmpty ? "아직 없음" : hotspot
        return "와이파이 MAC \(wifiText)\n이더넷 MAC \(ethText)\n핫스팟 MAC \(apText)"
    }

    private func c3Inspector(_ board: C3BoardRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(board.duty == .light ? "조명" : "로닌", systemImage: board.duty == .light ? "lightbulb.fill" : "rotate.3d")
                .font(.headline)
            TextField("기판 이름", text: Binding(get: { board.name }, set: { studio.renameC3(board.id, $0) }))
                .textFieldStyle(.roundedBorder)
            Text("이 C3 는 \(board.duty.title)만 합니다.")
            Text("\(board.link.title) · \(c3Link.boardId == board.id && c3Link.state == .online ? "온라인 \(board.socketHost):82" : "오프라인 \(board.socketHost):82")")
                .font(.caption.weight(.semibold))
                .textSelection(.enabled)
            Text("와이파이 MAC \(board.wifiMac.isEmpty ? "아직 없음" : board.wifiMac)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("공유기 고정 주소는 이 와이파이 MAC으로 예약합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(board.link.c3Detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("연결", selection: Binding(get: { board.link }, set: { studio.chooseC3Mode(board.id, $0) })) {
                ForEach(BoardLane.c3Choices) { lane in
                    Text(lane.title).tag(lane)
                }
            }
            Button(c3Link.boardId == board.id && c3Link.state == .connecting ? "연결 중" : "지금 연결") {
                studio.reconnectC3(board.id)
            }
            .buttonStyle(DeskButtonStyle(selected: c3Link.boardId == board.id && c3Link.state == .online, expand: true))
            .disabled(c3Link.state == .connecting || !board.link.shoots)
            if board.duty == .ronin {
                let spot = studio.stageSpot(for: board.id)
                Text("방향 버튼은 누르는 동안만 움직입니다. 끝은 그 방향의 한계로 가고, 제자리는 기본 시선으로 돌아옵니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("기본 시선 팬 \(Int(spot.homeYaw))°, 틸트 \(Int(spot.homePitch))°")
                    .font(.caption.weight(.semibold))
                AimPad(
                    nudge: { pan, tilt in steerRonin(pan: pan * stickSpeed, tilt: tilt * stickSpeed) },
                    stop: {},
                    home: {
                        yaw = 0
                        pitch = 0
                        queueRonin(yaw: 0, pitch: 0)
                    },
                    panEnd: { yaw = $0; steerRonin(pan: yaw, tilt: pitch, absolute: true) },
                    tiltEnd: { pitch = $0; steerRonin(pan: yaw, tilt: pitch, absolute: true) },
                    panMin: -180,
                    panMax: 180,
                    tiltMin: -56,
                    tiltMax: 90
                )
                Text("팬 \(Int(wrapDegrees(spot.homeYaw + yaw)))°")
                Slider(value: Binding(get: { yaw }, set: { yaw = $0; steerRonin(pan: yaw, tilt: pitch, absolute: true) }), in: -180...180, step: 1)
                Text("틸트 \(Int(spot.homePitch + pitch))°")
                Slider(value: Binding(get: { pitch }, set: { pitch = $0; steerRonin(pan: yaw, tilt: pitch, absolute: true) }), in: -56...90, step: 1)
                Text("속도 \(Int(stickSpeed * 100))%")
                Slider(value: $stickSpeed, in: 0.15...1)
                Button("기본 시선 고정") {
                    studio.setHomeAim(board.id, yaw: wrapDegrees(spot.homeYaw + yaw), pitch: spot.homePitch + pitch)
                    yaw = 0
                    pitch = 0
                }
                .buttonStyle(DeskButtonStyle(selected: true, expand: true))
            } else {
                let level = lightLevel[board.id] ?? 40
                let kelvin = lightKelvin[board.id] ?? 4500
                Text("울란지 VL120BI. 밝기와 색온도만 다룹니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("밝기 \(Int(level))")
                Slider(value: Binding(get: { lightLevel[board.id] ?? 40 }, set: { lightLevel[board.id] = $0 }), in: 0...100, step: 1)
                Text("색온도 \(Int(kelvin))K")
                Slider(value: Binding(get: { lightKelvin[board.id] ?? 4500 }, set: { lightKelvin[board.id] = $0 }), in: 2500...6500, step: 100)
                HStack {
                    Button("켜기") { Task { await studio.setLight(board.id, brightness: Int(level), kelvin: Int(kelvin), on: true) } }
                        .buttonStyle(DeskButtonStyle(tone: .record))
                    Button("끄기") { Task { await studio.setLight(board.id, brightness: Int(level), kelvin: Int(kelvin), on: false) } }
                        .buttonStyle(DeskButtonStyle(tone: .stop))
                }
            }
        }
    }

    private func cameraInspector(_ camera: BoardCamera) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(camera.name).font(.headline)
            Text("올리멕스 블루투스 \(camera.ble)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("화각", selection: $fov) {
                Text("와이드").tag("와이드")
                Text("리니어").tag("리니어")
                Text("내로우").tag("내로우")
            }
            Picker("해상도", selection: $resolution) {
                Text("4K").tag("4K")
                Text("2.7K").tag("2.7K")
                Text("1080p").tag("1080p")
            }
            Button("이 카메라만 보내기") {
                Task {
                    await studio.sendCameraSetting(id: camera.id, kind: camera.kind, ble: camera.ble, setting: "fov", value: fov)
                    await studio.sendCameraSetting(id: camera.id, kind: camera.kind, ble: camera.ble, setting: "resolution", value: resolution)
                }
            }
            .buttonStyle(DeskButtonStyle(selected: true, expand: true))
            Text("화각 프리셋은 렌즈가 알려 준 값이 아닙니다. 고른 카메라만 그 각도의 부채꼴을 미터 눈금으로 그립니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("녹화") { Task { await studio.olimexCamera(camera, start: true) } }
                    .buttonStyle(DeskButtonStyle(tone: .record))
                Button("정지") { Task { await studio.olimexCamera(camera, start: false) } }
                    .buttonStyle(DeskButtonStyle(tone: .stop))
            }
            HStack {
                Button("탈리 켜기") { Task { await studio.tally(camera, on: true) } }
                    .buttonStyle(DeskButtonStyle())
                Button("탈리 끄기") { Task { await studio.tally(camera, on: false) } }
                    .buttonStyle(DeskButtonStyle(tone: .stop))
            }
            Text("앞 화면에 글을 그리는 공식 블루투스 명령은 없습니다. 녹화 중 빨간 표시와 LED가 가장 가까운 탈리입니다. 랩스 펌웨어의 *FRNT=1 은 QR로만 앞 화면에 글을 띄웁니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func setPose(_ id: UUID, yaw: Double? = nil, pitch: Double? = nil, zoom: Double? = nil) {
        var pose = ptzPose[id] ?? PtzPose()
        if let yaw { pose.yaw = yaw }
        if let pitch { pose.pitch = pitch }
        if let zoom { pose.zoom = zoom }
        ptzPose[id] = pose
        studio.rememberPtzAim(id, pan: pose.yaw, tilt: pose.pitch, zoom: pose.zoom)
    }

    private func ptzInspector(_ camera: PtzRecord) -> some View {
        let pose = ptzPose[camera.id] ?? PtzPose()
        return VStack(alignment: .leading, spacing: 8) {
            Label("PTZ", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.headline)
            TextField("카메라 이름", text: Binding(get: { camera.name }, set: { studio.renamePtz(camera.id, $0) }))
                .textFieldStyle(.roundedBorder)
            Text("\(camera.host) · ONVIF \(camera.onvifPort) · Visca \(camera.viscaPort) · \(ptzOnline.contains(camera.id) ? "온라인" : "오프라인")")
                .font(.caption.weight(.semibold))
            Text("MAC \(camera.mac.isEmpty ? "아직 없음" : camera.mac)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text(camera.endpoint.isEmpty ? "ONVIF 주소를 찾는 중입니다." : camera.endpoint)
                .font(.caption)
                .textSelection(.enabled)
            Text("방향 버튼은 누르는 동안만 움직입니다. 끝은 한계 각도로 가고, 제자리는 기본 시선입니다. 무대 시선을 끌어도 그 절대 방향입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            let spot = studio.stageSpot(for: camera.id)
            Text("기본 시선 \(Int(spot.homeYaw))°")
                .font(.caption.weight(.semibold))
            AimPad(
                nudge: { pan, tilt in steer(camera, pan: pan * stickSpeed, tilt: tilt * stickSpeed, zoom: 0) },
                stop: { halt(camera) },
                home: {
                    setPose(camera.id, yaw: 0, pitch: 0)
                    sendAbsolute(camera)
                },
                panEnd: {
                    setPose(camera.id, yaw: $0)
                    sendAbsolute(camera)
                },
                tiltEnd: {
                    setPose(camera.id, pitch: $0)
                    sendAbsolute(camera)
                },
                panMin: -180,
                panMax: 180,
                tiltMin: -45,
                tiltMax: 45
            )
            Text("팬 \(Int(wrapDegrees(spot.homeYaw + pose.yaw)))°")
            Slider(value: Binding(get: { ptzPose[camera.id]?.yaw ?? 0 }, set: {
                setPose(camera.id, yaw: $0)
                sendAbsolute(camera)
            }), in: -180...180, step: 1)
            Text("틸트 \(Int(pose.pitch))°")
            Slider(value: Binding(get: { ptzPose[camera.id]?.pitch ?? 0 }, set: {
                setPose(camera.id, pitch: $0)
                sendAbsolute(camera)
            }), in: -45...45, step: 1)
            Text("줌 \(Int((ptzPose[camera.id]?.zoom ?? 0) * 100))%")
            Slider(value: Binding(get: { ptzPose[camera.id]?.zoom ?? 0 }, set: {
                setPose(camera.id, zoom: $0)
                sendAbsolute(camera)
            }), in: 0...1)
            Text("속도 \(Int(stickSpeed * 100))%")
            Slider(value: $stickSpeed, in: 0.15...1)
            Text("장면 1–10. 이름은 바꿔도 번호는 고정입니다. 저장은 지금 각도이고, 부르기는 그 각도로 갑니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(PtzScene.ten(camera.scenes)) { scene in
                HStack(spacing: 6) {
                    Text("\(scene.number)")
                        .font(.caption.weight(.bold))
                        .frame(width: 18)
                    TextField("이름", text: Binding(
                        get: { scene.name },
                        set: { studio.renamePtzScene(camera.id, number: scene.number, name: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button("저장") {
                        let current = ptzPose[camera.id] ?? PtzPose()
                        Task { await studio.savePtzScene(camera.id, number: scene.number, pan: current.yaw, tilt: current.pitch, zoom: current.zoom) }
                    }
                    .buttonStyle(DeskButtonStyle())
                    Button("부르기") {
                        let saved = PtzScene.ten(camera.scenes).first { $0.number == scene.number }
                        guard let saved, saved.saved else {
                            studio.note("\(scene.stableId) 은 아직 저장되지 않았습니다.")
                            return
                        }
                        setPose(camera.id, yaw: saved.pan, pitch: saved.tilt, zoom: saved.zoom)
                        Task { _ = await studio.recallPtzScene(camera.id, number: scene.number) }
                    }
                    .buttonStyle(DeskButtonStyle(selected: scene.saved))
                    .disabled(!scene.saved)
                }
            }
            Button("기본 시선 고정") {
                let current = ptzPose[camera.id] ?? PtzPose()
                studio.setHomeAim(camera.id, yaw: wrapDegrees(spot.homeYaw + current.yaw), pitch: spot.homePitch + current.pitch)
                setPose(camera.id, yaw: 0, pitch: 0)
            }
            .buttonStyle(DeskButtonStyle(selected: true, expand: true))
            Button("상태 확인") {
                Task { await refreshPtz(camera) }
            }
            .buttonStyle(DeskButtonStyle(expand: true))
        }
        .onChange(of: studio.ptzRecallTick) { _, _ in
            guard let aim = studio.ptzLive[camera.id] else { return }
            setPose(camera.id, yaw: aim.pan, pitch: aim.tilt, zoom: aim.zoom)
        }
        .task(id: camera.id) { await refreshPtz(camera) }
    }

    private func wrapDegrees(_ value: Double) -> Double {
        var next = value
        while next > 180 { next -= 360 }
        while next < -180 { next += 360 }
        return next
    }

    private func aimOnStage(_ id: String, heading: Double) {
        guard let uuid = UUID(uuidString: id) else { return }
        let spot = studio.stageSpot(for: uuid)
        let relative = wrapDegrees(heading - spot.homeYaw)
        if let camera = studio.profile.ptzCameras.first(where: { $0.id == uuid }) {
            setPose(uuid, yaw: relative)
            sendAbsolute(camera)
            return
        }
        if studio.roninC3?.id == uuid {
            yaw = relative
            queueRonin(yaw: yaw, pitch: pitch)
        }
    }

    private func sendAbsolute(_ camera: PtzRecord) {
        let pose = ptzPose[camera.id] ?? PtzPose()
        absolutePending = (camera, pose.yaw, pose.pitch, pose.zoom)
        guard absoluteTask == nil else { return }
        absoluteTask = Task {
            while let next = absolutePending {
                absolutePending = nil
                let password = FieldSecret.load(account: next.0.id.uuidString)
                let result = await Onvif.move(
                    host: next.0.host,
                    endpoint: next.0.endpoint,
                    user: next.0.username,
                    password: password,
                    pan: next.1,
                    tilt: next.2,
                    zoom: next.3,
                    viscaPort: next.0.viscaPort
                )
                if !result.1.isEmpty { studio.rememberPtzEndpoint(next.0.id, result.1) }
                if result.0.contains("받았습니다") {
                    ptzOnline.insert(next.0.id)
                } else {
                    ptzOnline.remove(next.0.id)
                    studio.note(result.0)
                }
                try? await Task.sleep(nanoseconds: 220_000_000)
            }
            absoluteTask = nil
            if absolutePending != nil, let pending = absolutePending {
                sendAbsolute(pending.0)
            }
        }
    }

    private func steerRonin(pan: Double, tilt: Double, absolute: Bool = false) {
        if absolute {
            yaw = pan
            pitch = tilt
        } else {
            let now = Date()
            if now.timeIntervalSince(ptzSent) < 0.16 { return }
            ptzSent = now
            yaw = wrapDegrees(yaw + pan * 8)
            pitch = min(90, max(-56, pitch + tilt * 4))
        }
        queueRonin(yaw: yaw, pitch: pitch)
    }

    private func queueRonin(yaw: Double, pitch: Double) {
        roninPending = (yaw, pitch)
        guard roninTask == nil else { return }
        roninTask = Task {
            while let next = roninPending {
                roninPending = nil
                await studio.nudgeRonin(yaw: next.0, pitch: next.1, quiet: true)
                try? await Task.sleep(nanoseconds: 220_000_000)
            }
            roninTask = nil
            if let pending = roninPending {
                queueRonin(yaw: pending.0, pitch: pending.1)
            }
        }
    }

    private func steer(_ camera: PtzRecord, pan: Double, tilt: Double, zoom: Double) {
        let now = Date()
        if now.timeIntervalSince(ptzSent) < 0.18 { return }
        ptzSent = now
        ptzDrive?.cancel()
        ptzDrive = Task {
            let password = FieldSecret.load(account: camera.id.uuidString)
            let result = await Onvif.drive(
                host: camera.host,
                endpoint: camera.endpoint,
                user: camera.username,
                password: password,
                pan: pan,
                tilt: tilt,
                zoom: zoom,
                viscaPort: camera.viscaPort
            )
            if Task.isCancelled { return }
            if !result.1.isEmpty { studio.rememberPtzEndpoint(camera.id, result.1) }
            if result.0.contains("받았습니다") {
                ptzOnline.insert(camera.id)
            } else {
                ptzOnline.remove(camera.id)
                studio.note(result.0)
            }
        }
    }

    private func halt(_ camera: PtzRecord) {
        ptzDrive?.cancel()
        Task {
            let password = FieldSecret.load(account: camera.id.uuidString)
            let note = await Onvif.stop(host: camera.host, endpoint: camera.endpoint, user: camera.username, password: password, viscaPort: camera.viscaPort)
            if note.contains("받았습니다") { ptzOnline.insert(camera.id) }
            studio.note(note)
        }
    }

    private func refreshPtz(_ camera: PtzRecord) async {
        let password = FieldSecret.load(account: camera.id.uuidString)
        let result = await Onvif.check(host: camera.host, endpoint: camera.endpoint, user: camera.username, password: password)
        if !result.1.isEmpty { studio.rememberPtzEndpoint(camera.id, result.1) }
        if result.0.contains("답했습니다") { ptzOnline.insert(camera.id) } else { ptzOnline.remove(camera.id) }
        studio.note(result.0)
    }

    private var ptzSheet: some View {
        NavigationStack {
            Form {
                Section("바로 등록") {
                    Text("찾기 없이 적힌 값으로 바로 넣습니다. 기본값은 이 카메라 화면의 주소입니다.")
                        .font(.caption)
                    TextField("이름", text: $ptzName)
                    TextField("IP", text: $ptzHost)
                    TextField("ONVIF 포트", text: $ptzOnvif)
                    TextField("Visca 포트", text: $ptzVisca)
                    TextField("사용자 이름, 없으면 비움", text: $ptzUser)
                    SecureField("비밀번호, 없으면 비움", text: $ptzPassword)
                    TextField("MAC, 없으면 비움", text: $ptzMac)
                    Button("바로 등록") {
                        studio.addPtz(
                            host: ptzHost,
                            username: ptzUser,
                            password: ptzPassword,
                            name: ptzName,
                            onvifPort: Int(ptzOnvif) ?? 2000,
                            viscaPort: Int(ptzVisca) ?? 1259,
                            mac: ptzMac
                        )
                        ptzPassword = ""
                        showPtz = false
                    }
                    .buttonStyle(DeskButtonStyle(selected: true, expand: true))
                }
                Section("같은 망에서 찾기") {
                    Button(ptzSearching ? "찾는 중" : "ONVIF 찾기") {
                        Task {
                            ptzSearching = true
                            ptzFound = await Onvif.discover()
                            ptzSearching = false
                        }
                    }
                    .buttonStyle(DeskButtonStyle(expand: true))
                    .disabled(ptzSearching)
                    if ptzFound.isEmpty {
                        Text("WS-Discovery 와 192.168.10.200–230 의 ONVIF 응답을 봅니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(ptzFound) { found in
                        Button(found.endpoint.isEmpty ? found.host : found.endpoint) {
                            ptzHost = found.host
                            studio.addPtz(
                                host: found.host,
                                username: ptzUser,
                                password: ptzPassword,
                                name: ptzName,
                                onvifPort: Int(ptzOnvif) ?? 2000,
                                viscaPort: Int(ptzVisca) ?? 1259,
                                mac: ptzMac
                            )
                            ptzPassword = ""
                            showPtz = false
                        }
                        .buttonStyle(DeskButtonStyle(expand: true))
                    }
                }
            }
            .navigationTitle("PTZ")
            .toolbar {
                Button("닫기") { showPtz = false }
                    .buttonStyle(DeskButtonStyle())
            }
        }
    }
}

private struct PtzPose {
    var yaw = 0.0
    var pitch = 0.0
    var zoom = 0.0
}

private enum DeskPick: Hashable {
    case olimex
    case c3(UUID)
    case camera(String)
    case ptz(UUID)
}

private enum FloorTool: String, CaseIterable, Identifiable {
    case look
    case stage
    case foh
    var id: String { rawValue }
    var title: String {
        switch self {
        case .look: return "보기"
        case .stage: return "무대 배치"
        case .foh: return "FOH 배치"
        }
    }
}

/// 방향은 누르는 동안만, 끝은 그 방향의 한계, 가운데는 제자리입니다.
private struct AimPad: View {
    var nudge: (Double, Double) -> Void
    var stop: () -> Void
    var home: () -> Void
    var panEnd: (Double) -> Void
    var tiltEnd: (Double) -> Void
    var panMin: Double
    var panMax: Double
    var tiltMin: Double
    var tiltMax: Double

    var body: some View {
        VStack(spacing: 6) {
            HStack { Spacer(); endButton("위 끝") { tiltEnd(tiltMax) }; Spacer() }
            HStack { Spacer(); moveButton("위") { nudge(0, 1) }; Spacer() }
            HStack(spacing: 6) {
                endButton("왼쪽 끝") { panEnd(panMin) }
                moveButton("왼쪽") { nudge(-1, 0) }
                Button("제자리", action: home)
                    .buttonStyle(DeskButtonStyle(selected: true))
                moveButton("오른쪽") { nudge(1, 0) }
                endButton("오른쪽 끝") { panEnd(panMax) }
            }
            HStack { Spacer(); moveButton("아래") { nudge(0, -1) }; Spacer() }
            HStack { Spacer(); endButton("아래 끝") { tiltEnd(tiltMin) }; Spacer() }
        }
    }

    private func moveButton(_ title: String, onChange: @escaping () -> Void) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.45), lineWidth: 1))
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in onChange() }.onEnded { _ in stop() })
            .accessibilityLabel(title)
    }

    private func endButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(DeskButtonStyle())
            .accessibilityLabel("\(title) 한계")
    }
}

/// 렌즈 프리셋입니다. 카메라가 각도를 알려 주지 않으면 이 표의 각만 씁니다.
private struct LensLook {
    var name: String
    var degrees: Double {
        switch name {
        case "리니어": return 85
        case "내로우": return 55
        default: return 118
        }
    }
    var throwMeters: Double {
        switch name {
        case "리니어": return 6
        case "내로우": return 8
        default: return 4
        }
    }
}

/// 가로 14m, 깊이 18m 무대를 미터로만 그립니다. 0°는 객석(+Y)입니다.
private struct FloorPlan: View {
    @EnvironmentObject private var studio: Studio
    var gimbal: C3BoardRecord?
    var cameras: [BoardCamera]
    var meters: [String: CGPoint]
    var selected: String?
    var lens: LensLook
    var liveYaw: Double
    var livePitch: Double
    var tool: FloorTool
    var camerasOnline: Bool
    var liveC3: UUID?
    var onTool: (FloorTool) -> Void
    var onMoveCamera: (String, Double, Double) -> Void
    var onMoveGimbal: (UUID, Double, Double) -> Void
    var ptz: [PtzRecord]
    var ptzPose: [UUID: PtzPose]
    var ptzOnline: Set<UUID>
    var onMovePtz: (UUID, Double, Double) -> Void
    var onAim: (String, Double) -> Void
    @State private var drag: String?
    @State private var dragAim = false
    @State private var draft: FloorMark?
    @State private var dragStart: FloorMark?
    @State private var sizeWidth = ""
    @State private var sizeDepth = ""

    private var stageMark: FloorMark {
        studio.profile.stageMark ?? FloorMark(x: -StageRoom.width * 0.35, y: 0.2, w: StageRoom.width * 0.7, d: 2)
    }

    private var fohMark: FloorMark {
        studio.profile.fohMark ?? FloorMark(x: -2.4, y: 11.5, w: 4.8, d: 3.2)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.08, green: 0.09, blue: 0.11)))
                let room = rect(x0: -StageRoom.width / 2, y0: 0, x1: StageRoom.width / 2, y1: StageRoom.length, size: size)
                context.fill(Path(room), with: .color(Color(red: 0.14, green: 0.15, blue: 0.17)))
                context.stroke(Path(room), with: .color(.white.opacity(0.35)), lineWidth: 1.5)
                let stageDraw = tool == .stage ? sized(stageMark) : stageMark
                let fohDraw = tool == .foh ? sized(fohMark) : fohMark
                paintZone(context: context, size: size, mark: stageDraw, title: "무대", fill: Color(red: 0.45, green: 0.62, blue: 0.78).opacity(0.28), stroke: Color(red: 0.62, green: 0.78, blue: 0.9))
                paintZone(context: context, size: size, mark: fohDraw, title: "FOH", fill: Color(red: 0.54, green: 0.42, blue: 0.20).opacity(0.28), stroke: Color(red: 0.93, green: 0.78, blue: 0.42))
                context.draw(Text("객석").font(.caption2).foregroundStyle(.white.opacity(0.7)), at: CGPoint(x: size.width / 2, y: 14), anchor: .center)
                if let gimbal {
                    let spot = studio.stageSpot(for: gimbal.id)
                    let chosen = selected == gimbal.id.uuidString
                    let aim = spot.homeYaw + liveYaw
                    let pitch = spot.homePitch + livePitch
                    paint(
                        context: context,
                        size: size,
                        x: spot.x,
                        y: spot.y,
                        aim: aim,
                        pitch: pitch,
                        title: gimbal.name,
                        mark: "rotate.3d",
                        chosen: chosen,
                        useLens: chosen,
                        online: liveC3 == gimbal.id
                    )
                }
                for board in studio.profile.c3Boards where board.duty == .light {
                    let spot = studio.stageSpot(for: board.id)
                    paint(
                        context: context,
                        size: size,
                        x: spot.x,
                        y: spot.y,
                        aim: 0,
                        pitch: 0,
                        title: board.name,
                        mark: "lightbulb.fill",
                        chosen: selected == board.id.uuidString,
                        useLens: false,
                        online: liveC3 == board.id
                    )
                }
                for camera in ptz {
                    let spot = studio.stageSpot(for: camera.id)
                    let pose = ptzPose[camera.id] ?? PtzPose()
                    let chosen = selected == camera.id.uuidString
                    paint(
                        context: context,
                        size: size,
                        x: spot.x,
                        y: spot.y,
                        aim: spot.homeYaw + pose.yaw,
                        pitch: pose.pitch,
                        title: camera.name,
                        mark: "arrow.up.and.down.and.arrow.left.and.right",
                        chosen: chosen,
                        useLens: chosen,
                        degrees: chosen ? max(12, 60 - pose.zoom * 45) : 0,
                        throwMeters: chosen ? 8 : 1.8,
                        online: ptzOnline.contains(camera.id)
                    )
                }
                for (index, camera) in cameras.enumerated() {
                    let place = cameraPlace(camera.id, index: index, count: cameras.count)
                    let chosen = selected == camera.id
                    paint(
                        context: context,
                        size: size,
                        x: place.x,
                        y: place.y,
                        aim: 0,
                        pitch: 0,
                        title: camera.name,
                        mark: symbolName(camera),
                        chosen: chosen,
                        useLens: chosen,
                        online: camerasOnline
                    )
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if tool != .look {
                            if dragStart == nil {
                                dragStart = sized(tool == .stage ? stageMark : fohMark)
                            }
                            let a = unplan(value.startLocation, size: geo.size)
                            let b = unplan(value.location, size: geo.size)
                            var next = dragStart ?? sized(tool == .stage ? stageMark : fohMark)
                            next.x += b.x - a.x
                            next.y += b.y - a.y
                            draft = next
                            return
                        }
                        if drag == nil {
                            let body = hit(value.startLocation, size: geo.size)
                            if let body, body != selected || !canAim(body) {
                                drag = body
                                dragAim = false
                            } else if let selected, canAim(selected) {
                                let at = bodyPoint(selected, size: geo.size)
                                let inside = body == selected && hypot(at.x - value.startLocation.x, at.y - value.startLocation.y) < 22
                                drag = selected
                                dragAim = !inside
                            } else {
                                drag = body
                                dragAim = false
                            }
                        }
                        guard let drag else { return }
                        let room = unplan(value.location, size: geo.size)
                        if dragAim, let id = UUID(uuidString: drag) {
                            let spot = studio.stageSpot(for: id)
                            let heading = atan2(room.x - spot.x, room.y - spot.y) * 180 / .pi
                            onAim(drag, heading)
                            return
                        }
                        if let id = UUID(uuidString: drag), gimbal?.id == id || studio.profile.c3Boards.contains(where: { $0.id == id && $0.duty == .light }) {
                            onMoveGimbal(id, room.x, room.y)
                        } else if let id = UUID(uuidString: drag), ptz.contains(where: { $0.id == id }) {
                            onMovePtz(id, room.x, room.y)
                        } else {
                            onMoveCamera(drag, room.x, room.y)
                        }
                    }
                    .onEnded { _ in
                        dragStart = nil
                        drag = nil
                        dragAim = false
                    }
            )
            .onAppear { fillSizes(tool) }
            .onChange(of: tool) { _, new in
                draft = nil
                fillSizes(new)
            }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(FloorTool.allCases) { item in
                            Button(item.title) { onTool(item) }
                                .buttonStyle(DeskButtonStyle(selected: tool == item))
                        }
                    }
                    if tool != .look {
                        HStack(spacing: 6) {
                            TextField("가로 m", text: $sizeWidth)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                            TextField("세로 m", text: $sizeDepth)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                            Button("이 자리에 고정") { lockZone() }
                                .buttonStyle(DeskButtonStyle(selected: true))
                        }
                        Text("가로·세로를 적고, 사각형을 끌어 자리를 정한 뒤 고정합니다.")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(8)
            }
        }
    }

    private func fillSizes(_ tool: FloorTool) {
        let mark = tool == .foh ? fohMark : stageMark
        guard tool != .look else { return }
        sizeWidth = String(format: "%.1f", mark.w)
        sizeDepth = String(format: "%.1f", mark.d)
    }

    private func meters(_ text: String, fallback: Double) -> Double {
        let value = Double(text.replacingOccurrences(of: ",", with: ".")) ?? fallback
        return max(0.4, value)
    }

    private func sized(_ base: FloorMark) -> FloorMark {
        var mark = draft ?? base
        mark.w = meters(sizeWidth, fallback: base.w)
        mark.d = meters(sizeDepth, fallback: base.d)
        return mark
    }

    private func lockZone() {
        let base = tool == .stage ? stageMark : fohMark
        let mark = sized(base)
        if tool == .stage { studio.profile.stageMark = mark }
        if tool == .foh { studio.profile.fohMark = mark }
        draft = nil
    }

    private func paintZone(context: GraphicsContext, size: CGSize, mark: FloorMark, title: String, fill: Color, stroke: Color) {
        let box = rect(x0: mark.x, y0: mark.y, x1: mark.x + mark.w, y1: mark.y + mark.d, size: size)
        context.fill(Path(box), with: .color(fill))
        context.stroke(Path(box), with: .color(stroke), lineWidth: 2)
        context.draw(Text(title).font(.caption.weight(.bold)).foregroundStyle(.white), at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
        if title == "FOH" {
            context.draw(Text("객석 앞").font(.caption2).foregroundStyle(.white.opacity(0.8)), at: CGPoint(x: box.midX, y: box.midY + 14), anchor: .center)
        }
    }

    private let pad: CGFloat = 28
    private let brass = Color(red: 0.54, green: 0.42, blue: 0.20)

    private func paint(context: GraphicsContext, size: CGSize, x: Double, y: Double, aim: Double, pitch: Double, title: String, mark: String, chosen: Bool, useLens: Bool, degrees: Double? = nil, throwMeters: Double? = nil, online: Bool = true) {
        let at = plan(x: x, y: y, size: size)
        let fov = degrees ?? lens.degrees
        let reachBase = throwMeters ?? lens.throwMeters
        let reach = useLens ? reachBase * max(0.2, cos(pitch * .pi / 180)) : 1.8
        if useLens {
            var path = Path()
            path.move(to: at)
            let half = fov / 2
            for step in 0...12 {
                let deg = aim - half + (half * 2) * Double(step) / 12
                let end = offset(x: x, y: y, degrees: deg, meters: reach)
                path.addLine(to: plan(x: end.x, y: end.y, size: size))
            }
            path.closeSubpath()
            context.fill(path, with: .color(Color(red: 0.55, green: 0.22, blue: 0.24).opacity(0.28)))
            let tip = offset(x: x, y: y, degrees: aim, meters: reach)
            let tipPt = plan(x: tip.x, y: tip.y, size: size)
            context.draw(Text(String(format: "%.1f m", reach)).font(.caption2).foregroundStyle(brass), at: tipPt, anchor: .bottom)
        }
        var aimLine = Path()
        let tip = offset(x: x, y: y, degrees: aim, meters: useLens ? reach : 1.8)
        aimLine.move(to: at)
        aimLine.addLine(to: plan(x: tip.x, y: tip.y, size: size))
        context.stroke(aimLine, with: .color(brass), style: StrokeStyle(lineWidth: chosen ? 2.5 : 1.2, dash: useLens ? [] : [4, 3]))
        let width = pixels(0.7, size: size)
        let height = pixels(0.55, size: size)
        let box = CGRect(x: at.x - width / 2, y: at.y - height / 2, width: width, height: height)
        context.fill(Path(roundedRect: box, cornerRadius: 8), with: .color(Color.white.opacity(chosen ? 0.16 : 0.08)))
        context.stroke(Path(roundedRect: box, cornerRadius: 8), with: .color(chosen ? .white : .white.opacity(0.4)), lineWidth: chosen ? 2 : 1)
        let side = min(width, height) * 0.55
        var icon = context.resolve(Image(systemName: mark))
        icon.shading = .color(.white)
        context.draw(icon, in: CGRect(x: at.x - side / 2, y: at.y - side / 2 - 4, width: side, height: side))
        let state = online ? "온라인" : "오프라인"
        context.draw(Text(state).font(.caption2.weight(.bold)).foregroundStyle(online ? Color(red: 0.55, green: 0.85, blue: 0.55) : Color.white.opacity(0.55)), at: CGPoint(x: at.x, y: box.maxY - 2), anchor: .bottom)
        context.draw(Text(title).font(.caption2.weight(chosen ? .bold : .regular)).foregroundStyle(.white), at: CGPoint(x: at.x, y: box.minY - 4), anchor: .bottom)
    }

    private func plan(x: Double, y: Double, size: CGSize) -> CGPoint {
        let nx = (x + StageRoom.width / 2) / StageRoom.width
        let ny = 1 - (y / StageRoom.length)
        return CGPoint(
            x: pad + (size.width - pad * 2) * nx,
            y: pad + (size.height - pad * 2) * ny
        )
    }

    private func unplan(_ point: CGPoint, size: CGSize) -> (x: Double, y: Double) {
        let nx = (point.x - pad) / max(1, size.width - pad * 2)
        let ny = (point.y - pad) / max(1, size.height - pad * 2)
        return (Double(nx) * StageRoom.width - StageRoom.width / 2, (1 - Double(ny)) * StageRoom.length)
    }

    private func pixels(_ meters: Double, size: CGSize) -> CGFloat {
        let a = plan(x: 0, y: 0, size: size)
        let b = plan(x: meters, y: 0, size: size)
        return hypot(b.x - a.x, b.y - a.y)
    }

    private func offset(x: Double, y: Double, degrees: Double, meters: Double) -> (x: Double, y: Double) {
        let r = degrees * .pi / 180
        return (x + sin(r) * meters, y + cos(r) * meters)
    }

    private func rect(x0: Double, y0: Double, x1: Double, y1: Double, size: CGSize) -> CGRect {
        let a = plan(x: x0, y: y1, size: size)
        let b = plan(x: x1, y: y0, size: size)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func cameraPlace(_ id: String, index: Int, count: Int) -> (x: Double, y: Double) {
        if let saved = meters[id] { return (Double(saved.x), Double(saved.y)) }
        return defaultMeters(index, count: count)
    }

    private func defaultMeters(_ index: Int, count: Int) -> (x: Double, y: Double) {
        let span = min(StageRoom.width * 0.62, Double(max(count - 1, 1)) * 1.6)
        let t = count <= 1 ? 0.5 : Double(index) / Double(max(count - 1, 1))
        return (-span / 2 + span * t, 4)
    }

    private func symbolName(_ camera: BoardCamera) -> String {
        let text = (camera.kind + " " + camera.name).lowercased()
        if text.contains("insta") || camera.ble == "CE80" { return "pano" }
        if text.contains("osmo") || camera.ble == "FFF0" { return "video.fill" }
        return "camera.fill"
    }

    private func canAim(_ id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        if gimbal?.id == uuid { return true }
        return ptz.contains { $0.id == uuid }
    }

    private func bodyPoint(_ id: String, size: CGSize) -> CGPoint {
        guard let uuid = UUID(uuidString: id) else { return .zero }
        let spot = studio.stageSpot(for: uuid)
        return plan(x: spot.x, y: spot.y, size: size)
    }

    private func hit(_ point: CGPoint, size: CGSize) -> String? {
        if let gimbal {
            let spot = studio.stageSpot(for: gimbal.id)
            let at = plan(x: spot.x, y: spot.y, size: size)
            if hypot(at.x - point.x, at.y - point.y) < 28 { return gimbal.id.uuidString }
        }
        for (index, camera) in cameras.enumerated() {
            let place = cameraPlace(camera.id, index: index, count: cameras.count)
            let at = plan(x: place.x, y: place.y, size: size)
            if hypot(at.x - point.x, at.y - point.y) < 28 { return camera.id }
        }
        for camera in ptz {
            let spot = studio.stageSpot(for: camera.id)
            let at = plan(x: spot.x, y: spot.y, size: size)
            if hypot(at.x - point.x, at.y - point.y) < 28 { return camera.id.uuidString }
        }
        for board in studio.profile.c3Boards where board.duty == .light {
            let spot = studio.stageSpot(for: board.id)
            let at = plan(x: spot.x, y: spot.y, size: size)
            if hypot(at.x - point.x, at.y - point.y) < 28 { return board.id.uuidString }
        }
        return nil
    }
}

/// HLS 목록이 200일 때만 그림을 엽니다. 없으면 빈 화면 대신 글만 둡니다.
private struct HonestPicture: View {
    @EnvironmentObject private var link: BoardSocket
    var title: String
    var stream: String
    @State private var player: AVPlayer?
    @State private var note = "그림 없음"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else {
                    Text(note)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .frame(width: 240, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .task(id: link.state) { await load() }
    }

    private func load() async {
        player?.pause()
        player = nil
        guard link.state == .online else {
            note = "오프라인"
            return
        }
        #if os(macOS)
        guard let url = URL(string: "http://127.0.0.1:8888/\(stream)/index.m3u8") else {
            note = "그림 없음"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            note = "그림 없음"
            return
        }
        let next = AVPlayer(url: url)
        player = next
        next.play()
        #else
        note = "그림 없음. 실시간 그림은 맥의 MediaMTX 입니다."
        #endif
    }
}
