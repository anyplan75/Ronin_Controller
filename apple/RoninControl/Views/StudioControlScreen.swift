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
    @State private var ptzUser = ""
    @State private var ptzPassword = ""
    @State private var ptzFound: [Onvif.Found] = []
    @State private var ptzSearching = false
    @State private var ptzPose: [UUID: PtzPose] = [:]
    @State private var ptzOnline: Set<UUID> = []

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
            FirstJoinSheet { kind, host, port in
                studio.adoptLan(kind, host: host, port: port)
            }
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
                    guard studio.profile.olimexRegistered else {
                        studio.note("먼저 올리멕스 ESP32-PoE 를 등록하세요.")
                        return
                    }
                    link.connect()
                }
                .disabled(link.state == .connecting || !studio.profile.olimexRegistered || !link.lane.shoots)
                Button("모두 녹화") { Task { await studio.fieldRecord(group: "all", start: true) } }
                    .buttonStyle(.borderedProminent)
                    .tint(record)
                Button("모두 정지") { Task { await studio.fieldRecord(group: "all", start: false) } }
            }
            HStack(spacing: 8) {
                ForEach(["A", "B", "C"], id: \.self) { name in
                    Button("\(name) 녹화") { Task { await studio.fieldRecord(group: name, start: true) } }
                    Button("\(name) 정지") { Task { await studio.fieldRecord(group: name, start: false) } }
                }
                Spacer()
                Menu("기판 등록") {
                    Button("올리멕스 ESP32-PoE") { studio.registerOlimex() }
                    Button("C3") { askC3Job = true }
                    Button("PTZ 카메라") { showPtz = true }
                }
                Button("처음 연결") { showJoin = true }
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
                        Text(studio.profile.olimexRegistered ? "ESP32-PoE" : "아직 등록하지 않음")
                        Text(studio.profile.olimexRegistered ? "\(link.lane.title) · \(link.state == .online ? "온라인 \(link.endpoint)" : "오프라인")" : "연결을 고르세요")
                        Text("녹화 \(link.reportedRecording == nil ? "모름" : "기판 보고") · HDMI/USB 모름")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
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
                            Text(board.name)
                            Text("\(board.duty.title) · \(board.link.title) · \(c3Link.boardId == board.id && c3Link.state == .online ? "온라인" : "오프라인")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
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
                            Text(camera.name)
                            Text("\(camera.host) · \(ptzOnline.contains(camera.id) ? "온라인" : "오프라인") · 대기 · HDMI 모름")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
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
                                Text(camera.name)
                                Spacer()
                                Text("온라인 · 대기 · 출력 모름")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
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
            onMoveCamera: { id, x, y in cameraMeters[id] = CGPoint(x: x, y: y) },
            onMoveGimbal: { id, x, y in studio.moveStage(deviceId: id, x: x, y: y) },
            ptz: studio.profile.ptzCameras,
            ptzPose: ptzPose,
            ptzOnline: ptzOnline,
            onMovePtz: { id, x, y in studio.moveStage(deviceId: id, x: x, y: y) }
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
            Text("올리멕스 ESP32-PoE")
                .font(.headline)
            Text(studio.profile.olimexRegistered ? (link.state == .online ? "연결됨 \(link.endpoint)" : "오프라인") : "등록 전")
            Text(link.lane.detail)
            Text("액션 카메라는 이 기판 블루투스입니다. 고프로 FEA6, 오즈모 FFF0, 인스타360 CE80. 로닌 짐벌은 로닌 제어 C3 가 맡습니다. HDMI와 USB 출력은 기판이 알려 주기 전에는 모름입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("웹소켓이 열리기 전에는 연결됨으로 두지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func c3Inspector(_ board: C3BoardRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(board.name).font(.headline)
            Text("이 C3 는 \(board.duty.title)만 합니다.")
            Text("\(board.link.title) · \(c3Link.boardId == board.id && c3Link.state == .online ? "온라인" : "오프라인")")
                .font(.caption.weight(.semibold))
            Text(board.link.c3Detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("연결", selection: Binding(get: { board.link }, set: { studio.chooseC3Mode(board.id, $0) })) {
                ForEach(BoardLane.c3Choices) { lane in
                    Text(lane.title).tag(lane)
                }
            }
            if board.duty == .ronin {
                let spot = studio.stageSpot(for: board.id)
                Text("기준 팬 \(Int(spot.homeYaw))°, 틸트 \(Int(spot.homePitch))°. 슬라이더는 그 기준에서의 차이입니다. 무대 화각은 기준과 이 차이를 더해 미터 눈금으로 그립니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("차이 팬 \(Int(yaw))°")
                Slider(value: $yaw, in: -180...180, step: 1)
                Text("틸트 \(Int(pitch))°")
                Slider(value: $pitch, in: -56...90, step: 1)
                Button("이 차이를 보내기") {
                    Task { await studio.nudgeRonin(yaw: yaw, pitch: pitch) }
                }
                Button("지금 각도를 기준으로") {
                    studio.setHomeAim(board.id, yaw: spot.homeYaw + yaw, pitch: spot.homePitch + pitch)
                    yaw = 0
                    pitch = 0
                }
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
                    Button("끄기") { Task { await studio.setLight(board.id, brightness: Int(level), kelvin: Int(kelvin), on: false) } }
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
            Text("화각 프리셋은 렌즈가 알려 준 값이 아닙니다. 고른 카메라만 그 각도의 부채꼴을 미터 눈금으로 그립니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("녹화") { Task { await studio.olimexCamera(camera, start: true) } }
                Button("정지") { Task { await studio.olimexCamera(camera, start: false) } }
            }
            HStack {
                Button("탈리 켜기") { Task { await studio.tally(camera, on: true) } }
                Button("탈리 끄기") { Task { await studio.tally(camera, on: false) } }
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
    }

    private func ptzInspector(_ camera: PtzRecord) -> some View {
        let pose = ptzPose[camera.id] ?? PtzPose()
        return VStack(alignment: .leading, spacing: 8) {
            Text(camera.name).font(.headline)
            Text("\(camera.host) · ONVIF · \(ptzOnline.contains(camera.id) ? "온라인" : "오프라인")")
                .font(.caption.weight(.semibold))
            Text("팬·틸트·줌은 카메라가 명령을 받았을 때만 성공입니다. 고른 동안 무대 화각은 이 슬라이더를 미터 눈금으로 그립니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("팬 \(Int(pose.yaw))°")
            Slider(value: Binding(get: { ptzPose[camera.id]?.yaw ?? 0 }, set: { setPose(camera.id, yaw: $0) }), in: -180...180, step: 1)
            Text("틸트 \(Int(pose.pitch))°")
            Slider(value: Binding(get: { ptzPose[camera.id]?.pitch ?? 0 }, set: { setPose(camera.id, pitch: $0) }), in: -45...45, step: 1)
            Text("줌 \(Int((ptzPose[camera.id]?.zoom ?? 0) * 100))%")
            Slider(value: Binding(get: { ptzPose[camera.id]?.zoom ?? 0 }, set: { setPose(camera.id, zoom: $0) }), in: 0...1)
            Button("이 방향으로 보내기") {
                Task {
                    let password = FieldSecret.load(account: camera.id.uuidString)
                    let note = await Onvif.move(
                        host: camera.host,
                        user: camera.username,
                        password: password,
                        pan: pose.yaw,
                        tilt: pose.pitch,
                        zoom: pose.zoom
                    )
                    if note.contains("받았습니다") { ptzOnline.insert(camera.id) }
                    studio.note(note)
                }
            }
            Button("상태 확인") {
                Task {
                    let password = FieldSecret.load(account: camera.id.uuidString)
                    let note = await Onvif.check(host: camera.host, user: camera.username, password: password)
                    if note.contains("답했습니다") { ptzOnline.insert(camera.id) } else { ptzOnline.remove(camera.id) }
                    studio.note(note)
                }
            }
        }
    }

    private var ptzSheet: some View {
        NavigationStack {
            Form {
                Section("주소로 추가") {
                    TextField("192.168.10.203", text: $ptzHost)
                    TextField("사용자 이름, 없으면 비움", text: $ptzUser)
                    SecureField("비밀번호, 없으면 비움", text: $ptzPassword)
                    Button("이 주소 추가") {
                        studio.addPtz(host: ptzHost, username: ptzUser, password: ptzPassword)
                        ptzPassword = ""
                        showPtz = false
                    }
                }
                Section("같은 망에서 찾기") {
                    Button(ptzSearching ? "찾는 중" : "ONVIF 찾기") {
                        Task {
                            ptzSearching = true
                            ptzFound = await Onvif.discover()
                            ptzSearching = false
                        }
                    }
                    .disabled(ptzSearching)
                    if ptzFound.isEmpty {
                        Text("WS-Discovery 와 192.168.10.200–230 의 ONVIF 응답을 봅니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(ptzFound) { found in
                        Button(found.host) {
                            ptzHost = found.host
                            studio.addPtz(host: found.host, username: ptzUser, password: ptzPassword)
                            ptzPassword = ""
                            showPtz = false
                        }
                    }
                }
            }
            .navigationTitle("PTZ")
            .toolbar {
                Button("닫기") { showPtz = false }
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
    var onMoveCamera: (String, Double, Double) -> Void
    var onMoveGimbal: (UUID, Double, Double) -> Void
    var ptz: [PtzRecord]
    var ptzPose: [UUID: PtzPose]
    var ptzOnline: Set<UUID>
    var onMovePtz: (UUID, Double, Double) -> Void
    @State private var drag: String?

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.08, green: 0.09, blue: 0.11)))
                let deck = Path { path in
                    path.addRect(rect(x0: -StageRoom.width * 0.35, y0: 0.2, x1: StageRoom.width * 0.35, y1: 2.2, size: size))
                }
                context.fill(deck, with: .color(Color(red: 0.45, green: 0.62, blue: 0.78).opacity(0.18)))
                var grid = Path()
                var meter = -StageRoom.width / 2
                while meter <= StageRoom.width / 2 + 0.01 {
                    let a = plan(x: meter, y: 0, size: size)
                    let b = plan(x: meter, y: StageRoom.length, size: size)
                    grid.move(to: a)
                    grid.addLine(to: b)
                    meter += 2
                }
                var depth = 0.0
                while depth <= StageRoom.length + 0.01 {
                    let a = plan(x: -StageRoom.width / 2, y: depth, size: size)
                    let b = plan(x: StageRoom.width / 2, y: depth, size: size)
                    grid.move(to: a)
                    grid.addLine(to: b)
                    depth += 2
                }
                context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)
                let scaleA = plan(x: -6, y: 0.4, size: size)
                let scaleB = plan(x: -4, y: 0.4, size: size)
                var scale = Path()
                scale.move(to: scaleA)
                scale.addLine(to: scaleB)
                context.stroke(scale, with: .color(Color(red: 0.54, green: 0.42, blue: 0.20)), lineWidth: 2)
                context.draw(Text("2 m").font(.caption2).foregroundStyle(.white.opacity(0.8)), at: CGPoint(x: (scaleA.x + scaleB.x) / 2, y: scaleA.y - 10), anchor: .bottom)
                context.draw(Text("객석 · 조준 0°").font(.caption2).foregroundStyle(.white.opacity(0.7)), at: CGPoint(x: size.width / 2, y: 14), anchor: .center)
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
                        asset: "gear-ronin",
                        chosen: chosen,
                        useLens: chosen
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
                        aim: pose.yaw,
                        pitch: pose.pitch,
                        title: camera.name,
                        asset: nil,
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
                        asset: faceAsset(camera),
                        chosen: chosen,
                        useLens: chosen
                    )
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if drag == nil { drag = hit(value.startLocation, size: geo.size) }
                        guard let drag else { return }
                        let room = unplan(value.location, size: geo.size)
                        if let id = UUID(uuidString: drag), gimbal?.id == id {
                            onMoveGimbal(id, room.x, room.y)
                        }                         else if let id = UUID(uuidString: drag), ptz.contains(where: { $0.id == id }) {
                            onMovePtz(id, room.x, room.y)
                        } else {
                            onMoveCamera(drag, room.x, room.y)
                        }
                    }
                    .onEnded { _ in drag = nil }
            )
        }
    }

    private let pad: CGFloat = 28
    private let brass = Color(red: 0.54, green: 0.42, blue: 0.20)

    private func paint(context: GraphicsContext, size: CGSize, x: Double, y: Double, aim: Double, pitch: Double, title: String, asset: String?, chosen: Bool, useLens: Bool, degrees: Double? = nil, throwMeters: Double? = nil, online: Bool = true) {
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
        let height = pixels(0.42, size: size)
        if let asset {
            context.draw(Image(asset), in: CGRect(x: at.x - width / 2, y: at.y - height / 2, width: width, height: height))
        }
        if chosen {
            let ring = Path(ellipseIn: CGRect(x: at.x - width / 2 - 4, y: at.y - height / 2 - 4, width: width + 8, height: height + 8))
            context.stroke(ring, with: .color(.white), lineWidth: 1.5)
        }
        if asset == nil {
            let box = Path(roundedRect: CGRect(x: at.x - width / 2, y: at.y - height / 2, width: width, height: height), cornerRadius: 4)
            context.fill(box, with: .color(Color(red: 0.48, green: 0.18, blue: 0.22)))
            context.draw(Text("PTZ").font(.caption2.weight(.bold)).foregroundStyle(.white), at: at, anchor: .center)
            context.draw(Text(online ? "온라인" : "오프라인").font(.caption2).foregroundStyle(.white.opacity(0.7)), at: CGPoint(x: at.x, y: at.y + height / 2 + 4), anchor: .top)
        }
        context.draw(Text(title).font(.caption2.weight(chosen ? .bold : .regular)).foregroundStyle(.white), at: CGPoint(x: at.x, y: at.y - height / 2 - 4), anchor: .bottom)
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

    private func faceAsset(_ camera: BoardCamera) -> String? {
        let text = (camera.kind + " " + camera.name).lowercased()
        if text.contains("hero13") || text.contains("gopro 13") { return "gear-gopro-13" }
        if text.contains("hero12") || text.contains("gopro 12") { return "gear-gopro-12" }
        if text.contains("hero11") || text.contains("gopro 11") { return "gear-gopro-11" }
        if text.contains("hero10") { return "gear-gopro-10" }
        if text.contains("hero9") { return "gear-gopro-9" }
        if text.contains("insta") && text.contains("ace") { return "gear-insta360-ace-pro" }
        if text.contains("insta") || camera.ble == "CE80" { return "gear-insta360-x4" }
        if text.contains("osmo") || text.contains("action") || camera.ble == "FFF0" { return "gear-osmo-action-5-pro" }
        if camera.ble == "FEA6" { return "gear-gopro-11" }
        return nil
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
