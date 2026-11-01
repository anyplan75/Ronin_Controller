import AVKit
import SwiftUI

/// 맥, 아이패드, 아이폰이 같이 여는 스튜디오 화면입니다. 위 운송, 왼쪽 목록, 가운데 평면도, 아래 그림, 오른쪽 검사입니다.
struct StudioControlScreen: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var link: BoardSocket
    @State private var pick: DeskPick = .olimex
    @State private var askC3Job = false
    @State private var fov = "와이드"
    @State private var resolution = "1080p"
    @State private var yaw = 0.0
    @State private var pitch = 0.0
    @State private var lightLevel: [UUID: Double] = [:]
    @State private var lightKelvin: [UUID: Double] = [:]
    @State private var cameraSpots: [String: CGPoint] = [:]

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
                Picker("길", selection: Binding(get: { link.lane }, set: { studio.chooseLane($0) })) {
                    ForEach(BoardLane.allCases) { lane in
                        Text(lane.title).tag(lane)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                Button(link.state == .connecting ? "연결 중" : "지금 연결") {
                    guard studio.profile.olimexRegistered else {
                        studio.note("먼저 올리멕스 ESP32-PoE 를 등록하세요.")
                        return
                    }
                    link.connect()
                }
                .disabled(link.state == .connecting || !studio.profile.olimexRegistered)
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
                }
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
                        Text(studio.profile.olimexRegistered ? (link.state == .online ? link.endpoint : "오프라인") : "PoE 또는 와이파이")
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
                            Text(board.duty.title)
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
                                Text(camera.ble)
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

    private var floor: some View {
        FloorPlan(
            ronins: studio.profile.devices.filter { $0.kind == .ronin },
            cameras: link.cameras,
            spots: cameraSpots,
            onMoveCamera: { id, point in cameraSpots[id] = point },
            onMoveRonin: { id, x, y in studio.moveStage(deviceId: id, x: x, y: y) }
        )
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
            Text("PoE 192.168.0.150:81 또는 와이파이 192.168.0.151:81. 액션 카메라는 이 기판 블루투스입니다. 고프로 FEA6, 오즈모 FFF0, 인스타360 CE80.")
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
            Text("오프라인")
                .font(.caption.weight(.semibold))
            if board.duty == .ronin {
                Text("팬과 틸트만 이 기판으로 갑니다. 액션 카메라와 PoE 웹소켓으로는 보내지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("팬 \(Int(yaw))°")
                Slider(value: $yaw, in: -180...180, step: 1)
                Text("틸트 \(Int(pitch))°")
                Slider(value: $pitch, in: -56...90, step: 1)
                Button("이 각도로 보내기") {
                    Task { await studio.nudgeRonin(yaw: yaw, pitch: pitch) }
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
            HStack {
                Button("녹화") { Task { await studio.olimexCamera(camera, start: true) } }
                Button("정지") { Task { await studio.olimexCamera(camera, start: false) } }
            }
        }
    }
}

private enum DeskPick: Hashable {
    case olimex
    case c3(UUID)
    case camera(String)
}

/// 어두운 2차원 평면도입니다. 북쪽은 팬 0° 입니다. 그림 미리보기를 그리지 않습니다.
private struct FloorPlan: View {
    @EnvironmentObject private var studio: Studio
    var ronins: [DeviceRecord]
    var cameras: [BoardCamera]
    var spots: [String: CGPoint]
    var onMoveCamera: (String, CGPoint) -> Void
    var onMoveRonin: (UUID, Double, Double) -> Void
    @State private var drag: String?

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(rect), with: .color(Color(red: 0.08, green: 0.09, blue: 0.11)))
                var grid = Path()
                for step in 0...7 {
                    let x = pad + (size.width - pad * 2) * CGFloat(step) / 7
                    grid.move(to: CGPoint(x: x, y: pad))
                    grid.addLine(to: CGPoint(x: x, y: size.height - pad))
                }
                for step in 0...9 {
                    let y = pad + (size.height - pad * 2) * CGFloat(step) / 9
                    grid.move(to: CGPoint(x: pad, y: y))
                    grid.addLine(to: CGPoint(x: size.width - pad, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)
                context.draw(
                    Text("북 · 팬 0°").font(.caption2).foregroundStyle(.white.opacity(0.7)),
                    at: CGPoint(x: size.width / 2, y: 14),
                    anchor: .center
                )
                for device in ronins {
                    let spot = studio.stageSpot(for: device.id)
                    let at = plan(x: spot.x, y: spot.y, size: size)
                    wedge(context: context, at: at, yaw: spot.aimYaw, degrees: 70, size: size)
                    mark(context: context, at: at, title: device.name)
                }
                for (index, camera) in cameras.enumerated() {
                    let at = spots[camera.id] ?? defaultCamera(index, count: cameras.count, size: size)
                    wedge(context: context, at: at, yaw: 0, degrees: 80, size: size)
                    mark(context: context, at: at, title: camera.name)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if drag == nil {
                            drag = hit(value.startLocation, size: geo.size)
                        }
                        guard let drag else { return }
                        if let id = UUID(uuidString: drag), ronins.contains(where: { $0.id == id }) {
                            let room = unplan(value.location, size: geo.size)
                            onMoveRonin(id, room.x, room.y)
                        } else {
                            onMoveCamera(drag, value.location)
                        }
                    }
                    .onEnded { _ in drag = nil }
            )
        }
    }

    private let pad: CGFloat = 28

    private func plan(x: Double, y: Double, size: CGSize) -> CGPoint {
        let nx = (x + 7) / 14
        let ny = 1 - (y / 18)
        return CGPoint(
            x: pad + (size.width - pad * 2) * nx,
            y: pad + (size.height - pad * 2) * ny
        )
    }

    private func unplan(_ point: CGPoint, size: CGSize) -> (x: Double, y: Double) {
        let nx = (point.x - pad) / max(1, size.width - pad * 2)
        let ny = (point.y - pad) / max(1, size.height - pad * 2)
        return (Double(nx) * 14 - 7, (1 - Double(ny)) * 18)
    }

    private func wedge(context: GraphicsContext, at: CGPoint, yaw: Double, degrees: Double, size: CGSize) {
        let reach = min(size.width, size.height) * 0.22
        let half = degrees * .pi / 180 / 2
        let base = (yaw - 90) * .pi / 180
        var path = Path()
        path.move(to: at)
        for step in 0...10 {
            let ang = base - half + (half * 2) * Double(step) / 10
            path.addLine(to: CGPoint(x: at.x + CGFloat(cos(ang)) * reach, y: at.y + CGFloat(sin(ang)) * reach))
        }
        path.closeSubpath()
        context.fill(path, with: .color(Color(red: 0.45, green: 0.62, blue: 0.85).opacity(0.28)))
    }

    private func mark(context: GraphicsContext, at: CGPoint, title: String) {
        let dot = Path(ellipseIn: CGRect(x: at.x - 6, y: at.y - 6, width: 12, height: 12))
        context.fill(dot, with: .color(.white))
        context.draw(Text(title).font(.caption2).foregroundStyle(.white), at: CGPoint(x: at.x, y: at.y - 16), anchor: .bottom)
    }

    private func defaultCamera(_ index: Int, count: Int, size: CGSize) -> CGPoint {
        let span = size.width - pad * 2
        let t = count <= 1 ? 0.5 : CGFloat(index) / CGFloat(count - 1)
        return CGPoint(x: pad + span * t, y: size.height * 0.72)
    }

    private func hit(_ point: CGPoint, size: CGSize) -> String? {
        for device in ronins {
            let spot = studio.stageSpot(for: device.id)
            let at = plan(x: spot.x, y: spot.y, size: size)
            if hypot(at.x - point.x, at.y - point.y) < 22 { return device.id.uuidString }
        }
        for (index, camera) in cameras.enumerated() {
            let at = spots[camera.id] ?? defaultCamera(index, count: cameras.count, size: size)
            if hypot(at.x - point.x, at.y - point.y) < 22 { return camera.id }
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
