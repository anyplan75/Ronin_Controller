import AVKit
import SwiftUI

/// 맥, 아이패드, 아이폰이 같이 여는 스튜디오 화면입니다. 위 운송, 왼쪽 탭(PTZ·고정캠·로닌), 가운데 평면도, 오른쪽 설정·프리셋, 아래는 탭별 미리보기 또는 조종판입니다.
struct StudioControlScreen: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var link: BoardSocket
    @EnvironmentObject private var c3Bag: C3SocketBag
    @State private var pick: DeskPick = .olimex
    @State private var sideTab: StudioSideTab = .ptz
    @State private var askC3Job = false
    @State private var fov = "와이드"
    @State private var yaw = 0.0
    @State private var pitch = 0.0
    /// 요(롤 모터). 팬(좌우)과 다른 축입니다.
    @State private var rollYaw = 0.0
    /// 키: "보드UUID-칸index" — 울란지마다 밝기·색온도를 따로 둡니다.
    @State private var lightLevel: [String: Double] = [:]
    @State private var lightKelvin: [String: Double] = [:]
    @State private var lightOnByKey: [String: Bool] = [:]
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
    @State private var goproChoice: [Int: Int] = [:]
    @State private var osmoMode = 0x01
    @State private var liveReady: [String: URL] = [:]
    @State private var absoluteTask: Task<Void, Never>?
    @State private var absolutePending: (PtzRecord, Double, Double, Double)?
    @State private var roninTask: Task<Void, Never>?
    @State private var roninPending: (Double, Double)?
    @State private var askVenueSave = false
    @State private var venueNameDraft = ""
    @State private var askVenueRename: UUID?
    @State private var venueRenameDraft = ""
    @State private var lightSendTask: [String: Task<Void, Never>] = [:]
    @State private var didLaunchBoards = false
    @State private var zoomHolding = false
    @State private var zoomSentAt = Date.distantPast
    @State private var ptzTwoStep = true
    @State private var ptzSelectedScene: [UUID: Int] = [:]
    @State private var ptzFocus: [UUID: Double] = [:]
    @State private var ptzIris: [UUID: Double] = [:]
    @State private var ptzSequenceTask: Task<Void, Never>?
    @State private var roninTwoStep = true
    @State private var roninSelectedScene = 1
    @State private var roninFocus = 0.5
    @State private var roninIris = 0.5
    @State private var roninZoomSlider = 0.0
    /// 로닌용 앱 쪽 정지 프리셋(보드 장면과 별개).
    @State private var roninScenes: [PtzScene] = (1...9).map { PtzScene.empty($0) }
    @State private var roninMovePath = PtzMovePath(name: "로닌 경로", steps: [])
    /// 고정캠 녹화 중 표시. 소켓 send 가 아니라 기판 BLE tally.note(또는 cameras[].recording) 성공 때만 넣습니다.
    @State private var camRecording: Set<String> = []
    /// 녹화/정지 요청을 보낸 뒤 BLE 답을 기다리는 카메라 id.
    @State private var camRecordPending: Set<String> = []
    /// 묶음 녹화 때 대별 답을 맞추기 위한 기대 시작/정지.
    @State private var camRecordWantStart: [String: Bool] = [:]

    private let ink = Color(red: 0.93, green: 0.94, blue: 0.95)
    private let panel = Color(red: 0.11, green: 0.12, blue: 0.14)
    private let canvas = Color(red: 0.07, green: 0.08, blue: 0.09)
    private let line = Color.white.opacity(0.14)
    private let record = Color(red: 0.86, green: 0.28, blue: 0.28)

    var body: some View {
        VStack(spacing: 0) {
            transport
            GeometryReader { geo in
                // 좌·우 패널은 위→아래 전체 높이. 중간만 평면도+하단 조종(하단 스크롤 없음).
                if geo.size.width < 760 {
                    HStack(spacing: 0) {
                        tabRail.frame(width: min(160, geo.size.width * 0.34))
                        VStack(spacing: 0) {
                            floor
                                .frame(maxHeight: .infinity)
                                .clipped()
                            bottomStage
                                .frame(height: bottomStageHeight(geo.size.height))
                        }
                        inspector.frame(width: min(180, geo.size.width * 0.34))
                    }
                } else {
                    HStack(spacing: 0) {
                        tabRail.frame(width: min(300, geo.size.width * 0.26))
                        VStack(spacing: 0) {
                            floor
                                .frame(maxHeight: .infinity)
                                .clipped()
                            bottomStage
                                .frame(height: bottomStageHeight(geo.size.height))
                        }
                        inspector.frame(width: min(320, geo.size.width * 0.26))
                    }
                }
            }
        }
        .background(canvas)
        .foregroundStyle(ink)
        .preferredColorScheme(.dark)
        .confirmationDialog("보드 자리", isPresented: $askC3Job, titleVisibility: .visible) {
            Button("OLED C3 · 로닌 RS2") {
                studio.registerBoardSlot(.oled)
                sideTab = .ronin
                if let board = studio.profile.c3Boards.first(where: { $0.boardSlot == .oled }) {
                    pick = .c3(board.id)
                }
            }
            Button("RMSID C3 · 로닌 SC") {
                studio.registerBoardSlot(.rmsid)
                sideTab = .ronin
                if let board = studio.profile.c3Boards.first(where: { $0.boardSlot == .rmsid }) {
                    pick = .c3(board.id)
                }
            }
            Button("S3 · 울란지 조명") {
                studio.registerBoardSlot(.s3)
                sideTab = .light
                if let board = studio.profile.c3Boards.first(where: { $0.boardSlot == .s3 }) {
                    pick = .c3(board.id)
                }
            }
            Button("자리 맞추기 (3대·중복 제거)") { studio.syncBoardRoles() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("슬롯·MAC·주소로 구분합니다. 고프로·액션5=올리멕스, 로닌=OLED/RMSID, 조명=S3.")
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
        .onReceive(c3Bag.objectWillChange) { _ in
            for board in studio.profile.c3Boards {
                let link = c3(board)
                guard link.state == .online else { continue }
                studio.applyBoardHello(boardId: board.id, slot: link.lastSlot, wifi: link.wifiMac, host: link.lastHost)
                if !link.wifiMac.isEmpty {
                    studio.rememberC3(board.id, wifi: link.wifiMac, hotspot: link.apMac)
                }
                if !link.lastSlot.isEmpty {
                    studio.boardLanAlive[link.lastSlot] = true
                }
            }
        }
        .task {
            guard !didLaunchBoards else { return }
            didLaunchBoards = true
            await studio.ensureBoardRolesOnLaunch()
            syncPickToTab(sideTab)
        }
        .onChange(of: pick) { _, next in
            if case .c3(let id) = next {
                // 이미 같은 보드 온라인이면 connect 가 바로 return — 불필요 재연결 없음.
                studio.reconnectC3(id)
            }
        }
        .onChange(of: sideTab) { _, tab in
            syncPickToTab(tab)
            ensureC3ForTab(tab)
        }
        .sheet(isPresented: $showPtz) {
            ptzSheet
        }
    }

    private func bottomStageHeight(_ total: CGFloat) -> CGFloat {
        switch sideTab {
        case .fixedCam:
            // UI3: 장면(미리보기) 축소 → 컨트롤 공간 확보
            return liveReady.isEmpty ? 48 : min(150, max(100, total * 0.16))
        case .ptz, .ronin:
            return min(260, max(190, total * 0.30))
        case .light:
            return min(220, max(160, total * 0.26))
        }
    }

    private func syncPickToTab(_ tab: StudioSideTab) {
        switch tab {
        case .ptz:
            if case .ptz = pick { return }
            if let first = studio.profile.ptzCameras.first {
                pick = .ptz(first.id)
            }
        case .fixedCam:
            switch pick {
            case .olimex, .camera: return
            default:
                pick = .olimex
            }
        case .ronin:
            if case .c3(let id) = pick,
               studio.profile.c3Boards.contains(where: { $0.id == id && $0.duty == .ronin }) {
                return
            }
            if let first = studio.profile.c3Boards.first(where: { $0.duty == .ronin }) {
                pick = .c3(first.id)
            }
        case .light:
            if case .c3(let id) = pick,
               studio.profile.c3Boards.contains(where: { $0.id == id && $0.duty == .light }) {
                return
            }
            if let first = studio.profile.c3Boards.first(where: { $0.duty == .light }) {
                pick = .c3(first.id)
            }
        }
    }

    /// 로닌·조명 탭: 해당 역할 보드를 **모두** 붙입니다(동시 연결).
    private func ensureC3ForTab(_ tab: StudioSideTab) {
        switch tab {
        case .ronin:
            for board in studio.profile.c3Boards where board.duty == .ronin && board.link.shoots {
                studio.reconnectC3(board.id)
            }
        case .light:
            for board in studio.profile.c3Boards where board.duty == .light && board.link.shoots {
                studio.reconnectC3(board.id)
            }
        default:
            break
        }
    }

    private func c3(_ board: C3BoardRecord) -> C3JobSocket { c3Bag.socket(for: board.id) }
    private func c3(_ id: UUID) -> C3JobSocket { c3Bag.socket(for: id) }

    private func c3OnlineText(for board: C3BoardRecord) -> (label: String, online: Bool?) {
        switch c3Bag.state(for: board.id) {
        case .online: return ("온라인", true)
        case .connecting: return ("연결 중", nil)
        case .offline:
            if board.link == .lan, let slot = board.boardSlot, studio.boardLanAlive[slot.rawValue] == false {
                return ("망 무응답 \(board.socketHost)", false)
            }
            return ("오프라인", false)
        }
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(recordCount)
                    .font(.headline)
                    .foregroundStyle(link.state == .online ? record : ink)
                Text(link.state == .online ? link.detail : "올리멕스 \(link.lane.title) 미연결")
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
                Button("모두 녹화") {
                    markGroupRecordPending(group: "all", start: true)
                    Task { await studio.fieldRecord(group: "all", start: true) }
                }
                .buttonStyle(DeskButtonStyle(tone: .record))
                Button("모두 정지") {
                    markGroupRecordPending(group: "all", start: false)
                    Task { await studio.fieldRecord(group: "all", start: false) }
                }
                .buttonStyle(DeskButtonStyle(tone: .stop))
            }
            HStack(spacing: 8) {
                ForEach(["A", "B", "C"], id: \.self) { name in
                    let count = studio.profile.cameraGroups[name]?.count ?? 0
                    Button("\(name) 묶음 \(count) 녹화") {
                        markGroupRecordPending(group: name, start: true)
                        Task { await studio.fieldRecord(group: name, start: true) }
                    }
                    .buttonStyle(DeskButtonStyle(selected: count > 0, tone: .record))
                    Button("정지") {
                        markGroupRecordPending(group: name, start: false)
                        Task { await studio.fieldRecord(group: name, start: false) }
                    }
                    .buttonStyle(DeskButtonStyle(tone: .stop))
                }
                Text("카메라 줄의 A·B·C가 묶음입니다. 빨간 테두리는 BLE 답 이후.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Text("지금 · \(studio.venues.currentName)")
                    Button("지금 장소 다시 저장") { studio.saveCurrentVenue() }
                    Button("새 이름으로 저장…") {
                        venueNameDraft = studio.venues.currentName == "이름 없는 장소" ? "" : studio.venues.currentName
                        askVenueSave = true
                    }
                    if !studio.venues.places.isEmpty {
                        Divider()
                        ForEach(studio.venues.places) { place in
                            Button {
                                studio.loadVenue(place.id)
                            } label: {
                                HStack {
                                    Text(place.name)
                                    if studio.venues.currentId == place.id {
                                        Text("✓")
                                    }
                                }
                            }
                        }
                        Divider()
                        ForEach(studio.venues.places) { place in
                            Button("이름 바꾸기 · \(place.name)") {
                                askVenueRename = place.id
                                venueRenameDraft = place.name
                            }
                            Button("삭제 · \(place.name)", role: .destructive) {
                                studio.deleteVenue(place.id)
                            }
                        }
                    }
                } label: {
                    Text("장소 · \(studio.venues.currentName)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.45), lineWidth: 1))
                }
                Menu {
                    Button("올리멕스 · 고프로·액션5") {
                        studio.registerOlimex()
                        sideTab = .fixedCam
                        pick = .olimex
                    }
                    Button("보드 (C3·S3)") { askC3Job = true }
                    Button("PTZ 카메라") {
                        sideTab = .ptz
                        showPtz = true
                    }
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
        .alert("장소 이름", isPresented: $askVenueSave) {
            TextField("예: 본당, FOH", text: $venueNameDraft)
            Button("저장") { studio.saveVenue(named: venueNameDraft) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("보드·무대·PTZ·카메라·로닌 설정을 이 이름으로 저장합니다.")
        }
        .alert("장소 이름 바꾸기", isPresented: Binding(
            get: { askVenueRename != nil },
            set: { if !$0 { askVenueRename = nil } }
        )) {
            TextField("새 이름", text: $venueRenameDraft)
            Button("바꾸기") {
                if let id = askVenueRename { studio.renameVenue(id, venueRenameDraft) }
                askVenueRename = nil
            }
            Button("취소", role: .cancel) { askVenueRename = nil }
        }
    }

    /// 올리멕스 녹화 수만. 오프라인이면 배지처럼 「오프라인」을 쓰지 않습니다(무엇이 오프라인인지 불명).
    private var recordCount: String {
        guard link.state == .online else { return "올리멕스 대기" }
        if let count = link.reportedRecording { return "녹화 \(count)" }
        return "올리멕스 온라인"
    }

    /// 왼쪽: 탭 3개 + 탭별 기기 등록·목록. 보드는 등록된 것만 보이고, 이후엔 온라인/오프라인만 갱신합니다.
    private var tabRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioTabBar(tab: $sideTab)
            tabRegisterRow
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    switch sideTab {
                    case .ptz:
                        ptzTabDevices
                    case .fixedCam:
                        fixedCamTabDevices
                    case .ronin:
                        roninTabDevices
                    case .light:
                        lightTabDevices
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(10)
        .background(panel)
        .overlay(alignment: .trailing) { Rectangle().fill(line).frame(width: 1) }
    }

    private var tabRegisterRow: some View {
        HStack(spacing: 8) {
            switch sideTab {
            case .ptz:
                Button("PTZ 등록") { showPtz = true }
                    .buttonStyle(DeskButtonStyle(selected: true, expand: true))
            case .fixedCam:
                VStack(alignment: .leading, spacing: 6) {
                    Button("올리멕스 등록") {
                        studio.registerOlimex()
                        pick = .olimex
                    }
                    .buttonStyle(DeskButtonStyle(selected: true, expand: true))
                    .disabled(studio.profile.olimexRegistered)
                    Text("고프로(5 블랙 포함)·액션5는 카메라 자체 와이파이가 아니라 올리멕스 블루투스로 붙습니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .ronin:
                Button("로닌 보드 등록") { askC3Job = true }
                    .buttonStyle(DeskButtonStyle(selected: true, expand: true))
            case .light:
                Button("조명 보드 등록") {
                    studio.registerBoardSlot(.s3)
                    if let board = studio.profile.c3Boards.first(where: { $0.boardSlot == .s3 }) {
                        pick = .c3(board.id)
                    }
                }
                .buttonStyle(DeskButtonStyle(selected: true, expand: true))
            }
        }
    }

    @ViewBuilder
    private var ptzTabDevices: some View {
        if studio.profile.ptzCameras.isEmpty {
            Text("등록한 PTZ만 목록에 나옵니다. 기본 IP는 192.168.10.203 입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ForEach(studio.profile.ptzCameras) { camera in
                DeviceThumbCard(
                    title: camera.name,
                    subtitle: camera.host,
                    detail: "ONVIF \(camera.onvifPort) · Visca \(camera.viscaPort) · HDMI 모름",
                    symbol: "arrow.up.and.down.and.arrow.left.and.right",
                    online: ptzOnline.contains(camera.id),
                    selected: pick == .ptz(camera.id)
                ) {
                    pick = .ptz(camera.id)
                }
                .contextMenu {
                    Button("삭제", role: .destructive) { studio.deletePtz(camera.id) }
                }
            }
        }
    }

    @ViewBuilder
    private var fixedCamTabDevices: some View {
        if !studio.profile.olimexRegistered {
            Text("올리멕스를 등록하면 보드가 나타나고, 이후엔 온라인/오프라인만 표시합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
            Text("고프로 5 블랙 등도 카메라 와이파이에 붙이지 않습니다. 올리멕스 BLE로만 붙습니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
        } else {
            DeviceThumbCard(
                title: studio.olimexTitle,
                subtitle: "보드 · 고프로·액션5 · BLE",
                detail: "\(link.lane.title) · \(shownOlimexAddress) · 녹화 \(link.reportedRecording == nil ? "모름" : "\(link.reportedRecording!)대")",
                symbol: "server.rack",
                online: link.state == .online,
                selected: pick == .olimex,
                recording: (link.reportedRecording ?? 0) > 0
            ) {
                pick = .olimex
            }
            Text("카메라 자체 와이파이 X · 올리멕스 블루투스(고프로 FEA6 / 액션5 FFF0)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if link.state != .online {
                Text("보드가 오프라인이면 카메라 이름이 비습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if link.cameras.isEmpty {
                Text("붙어 있는 고프로·액션5가 아직 없습니다. 카메라 와이파이가 아니라 올리멕스 BLE를 확인하세요.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(link.cameras) { camera in
                    HStack(alignment: .top, spacing: 6) {
                        DeviceThumbCard(
                            title: camera.name,
                            subtitle: camera.kind.isEmpty ? "고정캠" : camera.kind,
                            detail: camRecordDetail(camera),
                            symbol: cameraSymbol(camera),
                            online: true,
                            selected: pick == .camera(camera.id),
                            recording: camRecording.contains(camera.id)
                        ) {
                            pick = .camera(camera.id)
                        }
                        VStack(spacing: 4) {
                            Button("녹화") {
                                Task { await setCamRecording(camera, start: true) }
                            }
                            .buttonStyle(DeskButtonStyle(tone: .record))
                            .disabled(camRecordPending.contains(camera.id))
                            Button("정지") {
                                Task { await setCamRecording(camera, start: false) }
                            }
                            .buttonStyle(DeskButtonStyle(tone: .stop))
                            .disabled(camRecordPending.contains(camera.id))
                            ForEach(["A", "B", "C"], id: \.self) { name in
                                Button(name) { studio.toggleCameraGroup(name, camera.id) }
                                    .buttonStyle(DeskButtonStyle(selected: studio.cameraInGroup(name, camera.id)))
                            }
                        }
                    }
                }
            }
        }
    }

    private func camRecordDetail(_ camera: BoardCamera) -> String {
        if camRecordPending.contains(camera.id) { return "BLE 대기" }
        if camRecording.contains(camera.id) { return "녹화 중" }
        return "대기"
    }

    private func setCamRecording(_ camera: BoardCamera, start: Bool) async {
        camRecordPending.insert(camera.id)
        camRecordWantStart[camera.id] = start
        let ok = await studio.olimexCamera(camera, start: start)
        camRecordPending.remove(camera.id)
        camRecordWantStart.removeValue(forKey: camera.id)
        if ok {
            if start {
                camRecording.insert(camera.id)
            } else {
                camRecording.remove(camera.id)
            }
        }
        // 실패면 빨간 테두리를 바꾸지 않습니다(이전 실기 상태 유지).
    }

    /// 기판 cameras[].recording 또는 tally.note 로 빨간 테두리를 맞춥니다. 소켓 send 만으로는 바꾸지 않습니다.
    private func applyCamRecordingFromBoard(note: String? = nil) {
        for camera in link.cameras {
            if let reported = camera.recording {
                if reported {
                    camRecording.insert(camera.id)
                } else {
                    camRecording.remove(camera.id)
                }
                camRecordPending.remove(camera.id)
                camRecordWantStart.removeValue(forKey: camera.id)
                continue
            }
            guard let note, !note.isEmpty, note.contains(camera.name) else { continue }
            switch BoardSocket.tallyOutcome(note) {
            case .success:
                if let wantStart = camRecordWantStart[camera.id] {
                    if wantStart {
                        camRecording.insert(camera.id)
                    } else {
                        camRecording.remove(camera.id)
                    }
                }
                camRecordPending.remove(camera.id)
                camRecordWantStart.removeValue(forKey: camera.id)
            case .failure:
                camRecordPending.remove(camera.id)
                camRecordWantStart.removeValue(forKey: camera.id)
            case .unknown:
                break
            }
        }
    }

    private func markGroupRecordPending(group: String, start: Bool) {
        let ids = group == "all" ? link.cameras.map(\.id) : (studio.profile.cameraGroups[group] ?? [])
        for id in ids {
            camRecordPending.insert(id)
            camRecordWantStart[id] = start
        }
        // 답이 안 오는 대는 20초 뒤 대기 표시만 해제합니다. 빨간 테두리는 바꾸지 않습니다.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            for id in ids where camRecordPending.contains(id) {
                camRecordPending.remove(id)
            }
        }
    }

    @ViewBuilder
    private var roninTabDevices: some View {
        let boards = studio.profile.c3Boards.filter { $0.duty == .ronin }
        if boards.isEmpty {
            Text("OLED(RS2)·RMSID(SC)를 등록하면 보드가 나타납니다. 등록 후엔 온라인/오프라인만 봅니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ForEach(boards) { board in
                let status = c3OnlineText(for: board)
                DeviceThumbCard(
                    title: board.listTitle,
                    subtitle: "\(board.roleTitle) · \(status.label)",
                    detail: "\(board.socketHost) · \(board.wifiMac.isEmpty ? "MAC 없음" : board.wifiMac)\(board.gimbalName.isEmpty ? "" : " · \(board.gimbalName)")",
                    symbol: "rotate.3d",
                    online: status.online,
                    selected: pick == .c3(board.id)
                ) {
                    pick = .c3(board.id)
                }
                .contextMenu {
                    Button("삭제", role: .destructive) { studio.deleteC3(board.id) }
                }
            }
        }
    }

    @ViewBuilder
    private var lightTabDevices: some View {
        let boards = studio.profile.c3Boards.filter { $0.duty == .light }
        if boards.isEmpty {
            Text("S3(울란지)를 등록하면 보드가 나타납니다. 등록 후엔 온라인/오프라인만 봅니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
        } else {
            ForEach(boards) { board in
                let status = c3OnlineText(for: board)
                DeviceThumbCard(
                    title: board.listTitle,
                    subtitle: "\(board.roleTitle) · \(status.label)",
                    detail: "\(board.socketHost) · \(board.wifiMac.isEmpty ? "MAC 없음" : board.wifiMac)",
                    symbol: "lightbulb.fill",
                    online: status.online,
                    selected: pick == .c3(board.id)
                ) {
                    pick = .c3(board.id)
                }
                .contextMenu {
                    Button("삭제", role: .destructive) { studio.deleteC3(board.id) }
                }
            }
        }
    }

    /// 하단: 고정캠=미리보기, PTZ·로닌=조종판, 조명=울란지 제어. 스크롤 없음.
    private var bottomStage: some View {
        Group {
            switch sideTab {
            case .fixedCam:
                liveStrip
            case .ptz:
                VStack(alignment: .leading, spacing: 8) {
                    if case .ptz(let id) = pick,
                       let camera = studio.profile.ptzCameras.first(where: { $0.id == id }) {
                        ptzControlStage(camera)
                    } else {
                        Text("왼쪽에서 PTZ를 고르면 아래에 조종판이 열립니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(panel)
                .overlay(alignment: .top) { Rectangle().fill(line).frame(height: 1) }
                .clipped()
            case .ronin:
                VStack(alignment: .leading, spacing: 8) {
                    if case .c3(let id) = pick,
                       let board = studio.profile.c3Boards.first(where: { $0.id == id && $0.duty == .ronin }) {
                        roninControlStage(board)
                    } else {
                        Text("왼쪽에서 로닌 보드를 고르면 아래에 조종판이 열립니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(panel)
                .overlay(alignment: .top) { Rectangle().fill(line).frame(height: 1) }
                .clipped()
            case .light:
                VStack(alignment: .leading, spacing: 8) {
                    if case .c3(let id) = pick,
                       let board = studio.profile.c3Boards.first(where: { $0.id == id && $0.duty == .light }) {
                        lightControlStage(board)
                    } else {
                        Text("왼쪽에서 조명 보드를 고르면 아래에 울란지 제어가 열립니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(panel)
                .overlay(alignment: .top) { Rectangle().fill(line).frame(height: 1) }
                .clipped()
            }
        }
    }

    private func ptzControlStage(_ camera: PtzRecord) -> some View {
        let pose = ptzPose[camera.id] ?? PtzPose()
        return PtzControlPad(
            title: "PTZ · \(camera.name)",
            speed: $stickSpeed,
            zoom: Binding(
                get: { ptzPose[camera.id]?.zoom ?? 0 },
                set: {
                    setPose(camera.id, zoom: $0)
                    sendAbsolute(camera)
                }
            ),
            focus: Binding(
                get: { ptzFocus[camera.id] ?? 0.5 },
                set: { ptzFocus[camera.id] = $0 }
            ),
            iris: Binding(
                get: { ptzIris[camera.id] ?? 0.5 },
                set: { ptzIris[camera.id] = $0 }
            ),
            showFocus: false,
            scenes: Array(PtzScene.ten(camera.scenes).prefix(9)),
            selectedScene: ptzSelectedScene[camera.id],
            twoStep: $ptzTwoStep,
            onNudge: { pan, tilt in steer(camera, pan: pan * stickSpeed, tilt: tilt * stickSpeed, zoom: 0) },
            onStop: { halt(camera) },
            onHome: {
                setPose(camera.id, yaw: 0, pitch: 0)
                sendAbsolute(camera)
            },
            onZoomChanged: { value in
                setPose(camera.id, zoom: value)
                sendAbsolute(camera)
            },
            onFocusHold: { dir in
                Task { _ = await Visca.focus(host: camera.host, port: UInt16(camera.viscaPort), direction: dir) }
            },
            onFocusStop: {
                Task { _ = await Visca.focus(host: camera.host, port: UInt16(camera.viscaPort), direction: 0) }
            },
            onIrisStep: { dir in
                Task { _ = await Visca.iris(host: camera.host, port: UInt16(camera.viscaPort), direction: dir) }
            },
            onIrisAuto: {
                Task { _ = await Visca.iris(host: camera.host, port: UInt16(camera.viscaPort), direction: 0, auto: true) }
            },
            onSelectScene: { number in
                ptzSelectedScene[camera.id] = number
            },
            onRecall: {
                let number = ptzSelectedScene[camera.id] ?? 1
                let saved = PtzScene.ten(camera.scenes).first { $0.number == number }
                guard let saved, saved.saved else {
                    studio.note("장면 \(number) 은 아직 저장되지 않았습니다.")
                    return
                }
                setPose(camera.id, yaw: saved.pan, pitch: saved.tilt, zoom: saved.zoom)
                Task { _ = await studio.recallPtzScene(camera.id, number: number) }
            },
            onStopPreset: {
                ptzSequenceTask?.cancel()
                halt(camera)
            },
            movePaths: camera.movePaths,
            onRecallPath: { path in
                ptzSequenceTask?.cancel()
                ptzSequenceTask = Task {
                    await studio.recallPtzMovePath(camera.id, path: path)
                }
            },
            onAddPathStep: { number in
                studio.appendPtzMoveStep(camera.id, sceneNumber: number)
            },
            onClearPath: {
                studio.clearPtzMovePath(camera.id)
            }
        )
        .onChange(of: studio.ptzRecallTick) { _, _ in
            guard let aim = studio.ptzLive[camera.id] else { return }
            setPose(camera.id, yaw: aim.pan, pitch: aim.tilt, zoom: aim.zoom)
        }
        .task(id: camera.id) { await refreshPtz(camera) }
        .accessibilityLabel("PTZ 조종 \(camera.name) 팬 \(Int(pose.yaw)) 틸트 \(Int(pose.pitch))")
    }

    private func roninControlStage(_ board: C3BoardRecord) -> some View {
        PtzControlPad(
            title: "로닌 · \(board.listTitle)",
            speed: $stickSpeed,
            zoom: $roninZoomSlider,
            focus: $roninFocus,
            iris: $roninIris,
            showFocus: false,
            showIris: false,
            showZoom: board.boardSlot == .oled,
            scenes: roninScenes,
            selectedScene: roninSelectedScene,
            twoStep: $roninTwoStep,
            onNudge: { pan, tilt in steerRonin(pan: pan * stickSpeed, tilt: tilt * stickSpeed) },
            onStop: {},
            onHome: {
                yaw = 0
                pitch = 0
                queueRonin(yaw: 0, pitch: 0, home: true)
            },
            onZoomChanged: { value in
                guard board.boardSlot == .oled else { return }
                let speed = Int(((value - 0.5) * 1600).rounded())
                Task { await studio.zoomRonin(speed: speed, boardId: board.id, quiet: true) }
            },
            onFocusHold: { _ in },
            onFocusStop: {},
            onIrisStep: { _ in },
            onIrisAuto: {},
            onSelectScene: { number in
                roninSelectedScene = number
            },
            onRecall: {
                let scene = roninScenes.first { $0.number == roninSelectedScene }
                guard let scene, scene.saved else {
                    studio.note("로닌 장면 \(roninSelectedScene) 은 아직 저장되지 않았습니다.")
                    return
                }
                yaw = scene.pan
                pitch = scene.tilt
                queueRonin(yaw: yaw, pitch: pitch)
            },
            onStopPreset: {
                ptzSequenceTask?.cancel()
                yaw = 0
                pitch = 0
                queueRonin(yaw: 0, pitch: 0, home: true)
            },
            movePaths: roninMovePath.steps.isEmpty ? [] : [roninMovePath],
            onRecallPath: { path in
                ptzSequenceTask?.cancel()
                ptzSequenceTask = Task {
                    for step in path.steps {
                        if Task.isCancelled { break }
                        if let scene = roninScenes.first(where: { $0.number == step.sceneNumber }), scene.saved {
                            yaw = scene.pan
                            pitch = scene.tilt
                            queueRonin(yaw: yaw, pitch: pitch)
                        }
                        try? await Task.sleep(nanoseconds: UInt64(max(0.3, step.dwellSeconds) * 1_000_000_000))
                    }
                }
            },
            onAddPathStep: { number in
                if let idx = roninScenes.firstIndex(where: { $0.number == number }) {
                    roninScenes[idx].pan = yaw
                    roninScenes[idx].tilt = pitch
                    roninScenes[idx].zoom = roninZoomSlider
                    roninScenes[idx].saved = true
                    roninScenes[idx].name = "로닌 \(number)"
                }
                roninMovePath.steps.append(PtzMoveStep(sceneNumber: number, dwellSeconds: 2))
                studio.note("로닌 경로에 장면 \(number) 을 넣었습니다.")
            },
            onClearPath: {
                roninMovePath.steps = []
                studio.note("로닌 이동 경로를 비웠습니다.")
            }
        )
    }

    /// 하단 조명 조종: 울란지 2대면 옆으로 나란히.
    private func lightControlStage(_ board: C3BoardRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("울란지 · \(board.listTitle)")
                    .font(.subheadline.weight(.semibold))
                Text(c3OnlineText(for: board).label)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Button("스캔") {
                    Task { await studio.scanUlanziLights(board.id) }
                }
                .buttonStyle(DeskButtonStyle())
                if c3(board).savedLights.count > 1 {
                    Button("묶음") {
                        let first = c3(board).savedLights[0]
                        let key = lightKey(board.id, first.index)
                        Task {
                            await studio.setAllLights(
                                board.id,
                                brightness: Int(lightLevel[key] ?? 40),
                                kelvin: Int(lightKelvin[key] ?? 4500),
                                on: lightOnByKey[key] ?? true
                            )
                        }
                    }
                    .buttonStyle(DeskButtonStyle())
                }
            }
            if !c3(board).gimbals.isEmpty {
                HStack(spacing: 6) {
                    ForEach(c3(board).gimbals) { light in
                        Button("붙이기 · \(light.name)") {
                            Task { await studio.pairUlanziLight(board.id, name: light.name, id: light.id) }
                        }
                        .buttonStyle(DeskButtonStyle(selected: c3(board).savedLights.contains(where: { $0.name == light.name })))
                    }
                }
            }
            if c3(board).savedLights.isEmpty {
                Text("저장된 울란지가 없습니다. 스캔 후 붙이거나 보드가 예전에 저장한 2대를 기다리세요.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(c3(board).savedLights) { light in
                        lightUnitPane(board.id, light)
                    }
                }
            }
        }
    }

    private func lightUnitPane(_ boardId: UUID, _ light: SavedLight) -> some View {
        let key = lightKey(boardId, light.index)
        return VStack(alignment: .leading, spacing: 4) {
            Text("칸 \(light.index) · \(light.name)")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text("밝기 \(Int(lightLevel[key] ?? 40))")
                .font(.caption2)
            Slider(value: Binding(
                get: { lightLevel[key] ?? 40 },
                set: { lightLevel[key] = $0; queueLight(boardId, index: light.index) }
            ), in: 0...100, step: 1)
            Text("색온도 \(Int(lightKelvin[key] ?? 4500))K")
                .font(.caption2)
            Slider(value: Binding(
                get: { lightKelvin[key] ?? 4500 },
                set: { lightKelvin[key] = $0; queueLight(boardId, index: light.index) }
            ), in: 2700...6500, step: 100)
            Toggle(isOn: Binding(
                get: { lightOnByKey[key] ?? true },
                set: { next in
                    lightOnByKey[key] = next
                    Task {
                        await studio.setLight(
                            boardId,
                            index: light.index,
                            brightness: Int(lightLevel[key] ?? 40),
                            kelvin: Int(lightKelvin[key] ?? 4500),
                            on: next
                        )
                    }
                }
            )) {
                Text(lightOnByKey[key] ?? true ? "켜짐" : "꺼짐")
                    .font(.caption2)
            }
            .toggleStyle(.switch)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var selectedMark: String? {
        switch pick {
        case .olimex: return nil
        case .c3(let id): return id.uuidString
        case .camera(let id): return id
        case .ptz(let id): return id.uuidString
        }
    }

    /// 무대에 그릴 울란지 대(저장 2대면 2개). 보드 자리 기준으로 옆으로 벌립니다.
    private var stageLightUnits: [(id: String, name: String, boardId: UUID, index: Int)] {
        var rows: [(id: String, name: String, boardId: UUID, index: Int)] = []
        for board in studio.profile.c3Boards where board.duty == .light {
            let lights: [SavedLight]
            if c3Bag.state(for: board.id) == .online, !c3(board).savedLights.isEmpty {
                lights = c3(board).savedLights
            } else {
                lights = []
            }
            if lights.isEmpty {
                rows.append((id: board.id.uuidString, name: board.name, boardId: board.id, index: 0))
            } else {
                for light in lights {
                    rows.append((id: "\(board.id.uuidString)-\(light.index)", name: light.name, boardId: board.id, index: light.index))
                }
            }
        }
        return rows
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
            liveC3: studio.profile.c3Boards.first(where: { c3Bag.state(for: $0.id) == .online })?.id,
            onTool: { floorTool = $0 },
            onMoveCamera: { id, x, y in cameraMeters[id] = CGPoint(x: x, y: y) },
            onMoveGimbal: { id, x, y in studio.moveStage(deviceId: id, x: x, y: y) },
            ptz: studio.profile.ptzCameras,
            ptzPose: ptzPose,
            ptzOnline: ptzOnline,
            onMovePtz: { id, x, y in studio.moveStage(deviceId: id, x: x, y: y) },
            onAim: { id, heading in aimOnStage(id, heading: heading) },
            camRecording: camRecording,
            lightUnits: stageLightUnits
        )
        .onChange(of: link.tallyNote) { _, note in
            if !note.isEmpty { studio.note(note) }
            applyCamRecordingFromBoard(note: note)
        }
        .onChange(of: link.cameras) { _, _ in
            applyCamRecordingFromBoard()
        }
        .background(canvas)
    }

    private var liveStrip: some View {
        let playing = link.cameras.filter { liveReady[$0.id] != nil }
        return VStack(alignment: .leading, spacing: 8) {
            if playing.isEmpty {
                Text(link.state == .online ? "실시간 그림 없음" : "올리멕스 미연결 · 미리보기 없음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(playing) { camera in
                            if let url = liveReady[camera.id] {
                                LivePicture(title: camera.name, url: url, recording: camRecording.contains(camera.id))
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: playing.isEmpty ? 44 : 360)
        .background(panel)
        .overlay(alignment: .top) { Rectangle().fill(line).frame(height: 1) }
        .task(id: link.cameras.map(\.id).joined(separator: ",")) { await probeLive() }
    }

    private func probeLive() async {
        var next: [String: URL] = [:]
        #if os(macOS)
        if link.state == .online {
            for camera in link.cameras {
                let safe = camera.id.replacingOccurrences(of: ":", with: "")
                let candidates = [camera.id, safe, camera.name.replacingOccurrences(of: " ", with: "")]
                for name in candidates {
                    guard let url = URL(string: "http://127.0.0.1:8888/\(name)/index.m3u8") else { continue }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 1.2
                    if let (_, response) = try? await URLSession.shared.data(for: request),
                       let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        next[camera.id] = url
                        break
                    }
                }
            }
        }
        #endif
        liveReady = next
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // UI3: 오른쪽 = 이동형 프리셋만(최대 20). 설정·장면 중복 제거.
                Text("이동형 프리셋")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                switch sideTab {
                case .ptz:
                    if case .ptz(let id) = pick,
                       let camera = studio.profile.ptzCameras.first(where: { $0.id == id }) {
                        travelPresetBank(camera: camera)
                    } else {
                        Text("왼쪽 PTZ를 고르면 경로 프리셋이 열립니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .ronin:
                    roninTravelPresetBank
                case .fixedCam:
                    switch pick {
                    case .olimex:
                        olimexInspector
                    case .camera(let id):
                        if let camera = link.cameras.first(where: { $0.id == id }) {
                            cameraInspector(camera)
                        }
                    default:
                        olimexInspector
                    }
                case .light:
                    if case .c3(let id) = pick,
                       let board = studio.profile.c3Boards.first(where: { $0.id == id && $0.duty == .light }) {
                        lightInspector(board)
                    } else {
                        Text("왼쪽 조명 목록에서 보드를 고르세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

    /// 뮤직뱅크형 PTZ 이동 경로(최대 20).
    private func travelPresetBank(camera: PtzRecord) -> some View {
        let paths = Array(camera.movePaths.prefix(Studio.maxTravelPresets))
        let scenes = Array(PtzScene.ten(camera.scenes).prefix(9))
        return VStack(alignment: .leading, spacing: 8) {
            Text("\(camera.name) · \(paths.count)/\(Studio.maxTravelPresets)")
                .font(.headline)
            Text("정지 장면을 순서대로 넣어 카메라 워킹을 만듭니다. Recall=재생, Stop=중단.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("경로 추가") {
                _ = studio.addPtzMovePath(camera.id)
            }
            .buttonStyle(DeskButtonStyle(selected: true, expand: true))
            .disabled(camera.movePaths.count >= Studio.maxTravelPresets)
            ForEach(paths) { path in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(path.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Recall") {
                            ptzSequenceTask?.cancel()
                            ptzSequenceTask = Task { await studio.recallPtzMovePath(camera.id, path: path) }
                        }
                        .buttonStyle(DeskButtonStyle(selected: true))
                        Button("Stop") {
                            ptzSequenceTask?.cancel()
                            halt(camera)
                        }
                        .buttonStyle(DeskButtonStyle())
                        Button("삭제") { studio.deletePtzMovePath(camera.id, pathId: path.id) }
                            .buttonStyle(DeskButtonStyle())
                    }
                    Text(path.steps.isEmpty ? "빈 경로" : path.steps.map { "\($0.sceneNumber)" }.joined(separator: " → "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    HStack {
                        ForEach(scenes.filter(\.saved).prefix(6)) { scene in
                            Button("+\(scene.number)") {
                                studio.appendPtzMoveStep(camera.id, sceneNumber: scene.number, pathId: path.id)
                            }
                            .buttonStyle(DeskButtonStyle())
                        }
                        Button("비우기") { studio.clearPtzMovePath(camera.id, pathId: path.id) }
                            .buttonStyle(DeskButtonStyle())
                    }
                }
                .padding(8)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("장면 저장·기본 시선은 아래 조종판 Recall/저장에서 합니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var roninTravelPresetBank: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("로닌 워킹 · \(roninMovePath.steps.count)칸")
                .font(.headline)
            Text(roninMovePath.steps.isEmpty
                  ? "아래 조종판에서 장면 번호를 경로에 넣으세요."
                  : roninMovePath.steps.map { "\($0.sceneNumber)" }.joined(separator: " → "))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            HStack {
                Button("Recall") {
                    guard let board = selectedRoninBoard else { return }
                    ptzSequenceTask?.cancel()
                    ptzSequenceTask = Task {
                        for step in roninMovePath.steps {
                            if Task.isCancelled { break }
                            let scene = roninScenes.first { $0.number == step.sceneNumber }
                            guard let scene, scene.saved else { continue }
                            await studio.nudgeRonin(yaw: scene.pan, pitch: scene.tilt, quiet: true, boardId: board.id)
                            try? await Task.sleep(nanoseconds: UInt64(max(0.3, step.dwellSeconds) * 1_000_000_000))
                        }
                    }
                }
                .buttonStyle(DeskButtonStyle(selected: true))
                Button("Stop") { ptzSequenceTask?.cancel() }
                    .buttonStyle(DeskButtonStyle())
                Button("비우기") {
                    roninMovePath.steps = []
                    studio.note("로닌 이동 경로를 비웠습니다.")
                }
                .buttonStyle(DeskButtonStyle())
            }
            if let board = selectedRoninBoard {
                Text(c3OnlineText(for: board).label)
                    .font(.caption.weight(.semibold))
                Button("지금 연결 · \(board.listTitle)") { studio.reconnectC3(board.id) }
                    .buttonStyle(DeskButtonStyle(expand: true))
                Button("로닌 보드 전부 연결") { studio.reconnectAllC3() }
                    .buttonStyle(DeskButtonStyle(selected: true, expand: true))
            }
        }
    }

    private var selectedRoninBoard: C3BoardRecord? {
        if case .c3(let id) = pick,
           let board = studio.profile.c3Boards.first(where: { $0.id == id && $0.duty == .ronin }) {
            return board
        }
        return studio.profile.c3Boards.first(where: { $0.duty == .ronin })
    }

    private var olimexInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("올리멕스 · 고프로·액션5", systemImage: "server.rack")
                .font(.headline)
            Text("역할 고프로·액션5")
                .font(.caption.weight(.semibold))
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
            Text("고프로·액션5만 이 기판입니다. 로닌은 OLED/RMSID C3, 울란지 조명은 S3 입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("고프로 5 블랙 포함: 카메라 자체 와이파이에 붙이지 않습니다. 올리멕스 블루투스로만 붙습니다.")
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
            Label(board.listTitle, systemImage: board.duty == .light ? "lightbulb.fill" : "rotate.3d")
                .font(.headline)
            Text("역할 \(board.roleTitle)")
                .font(.caption.weight(.semibold))
            TextField("기판 이름", text: Binding(get: { board.name }, set: { studio.renameC3(board.id, $0) }))
                .textFieldStyle(.roundedBorder)
            Text(board.boardSlot.map { "슬롯 \($0.rawValue) · \($0.boardTitle)" } ?? "슬롯 미정 · \(board.duty.title)")
                .font(.caption)
            Text("\(board.link.title) · \(c3OnlineText(for: board).label) · \(board.socketHost):82")
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
            Button(c3Bag.state(for: board.id) == .connecting ? "연결 중" : "지금 연결") {
                studio.reconnectC3(board.id)
            }
            .buttonStyle(DeskButtonStyle(selected: c3Bag.state(for: board.id) == .online, expand: true))
            .disabled(c3Bag.state(for: board.id) == .connecting || !board.link.shoots)
            Button("망 다시 확인 (.152/.154)") {
                studio.recheckC3Lan()
            }
            .buttonStyle(DeskButtonStyle(expand: true))
            if board.duty == .ronin {
                let spot = studio.stageSpot(for: board.id)
                Text("로닌 설정 · 프리셋")
                    .font(.subheadline.weight(.semibold))
                Text("로닌은 C3 블루투스로 붙입니다. CAN 배선이 아닙니다. 조종판은 아래 칸입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(board.gimbalName.isEmpty
                     ? (c3(board).pairedName.isEmpty ? "아직 붙인 로닌 이름이 없습니다." : "붙음 \(c3(board).pairedName)")
                     : "붙일 이름 \(board.gimbalName)\(c3(board).pairedName.isEmpty ? "" : " · 지금 \(c3(board).pairedName)")")
                    .font(.caption.weight(.semibold))
                Button("로닌 블루투스 스캔") {
                    Task { await studio.scanRoninGimbals(board.id) }
                }
                .buttonStyle(DeskButtonStyle(expand: true))
                if c3(board).gimbals.isEmpty {
                    Text("스캔하면 RS·SC 등 로닌 이름이 나옵니다. 오프라인이면 붙인 뒤 바로 스캔합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(c3(board).gimbals) { gimbal in
                        Button("붙이기 · \(gimbal.name)") {
                            Task { await studio.pairRoninGimbal(name: gimbal.name, id: gimbal.id, boardId: board.id) }
                        }
                        .buttonStyle(DeskButtonStyle(selected: board.gimbalName == gimbal.name || c3(board).pairedName == gimbal.name, expand: true))
                    }
                }
                if !board.gimbalName.isEmpty {
                    Button("저장 이름으로 다시 붙이기") {
                        Task { await studio.pairRoninGimbal(name: board.gimbalName, boardId: board.id) }
                    }
                    .buttonStyle(DeskButtonStyle(expand: true))
                }
                Text("기본 시선 팬 \(Int(spot.homeYaw))°, 틸트 \(Int(spot.homePitch))° · 팬 \(Int(wrapDegrees(spot.homeYaw + yaw)))° · 틸트 \(Int(spot.homePitch + pitch))°")
                    .font(.caption.weight(.semibold))
                Text("요 \(Int(rollYaw))° (롤·팬과 다름)")
                Slider(value: Binding(get: { rollYaw }, set: { next in
                    rollYaw = next
                    Task { await studio.nudgeRoninYaw(roll: next, boardId: board.id, quiet: true) }
                }), in: -30...30, step: 1)
                Text("프리셋")
                    .font(.caption.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
                    ForEach(roninScenes) { scene in
                        Button {
                            roninSelectedScene = scene.number
                        } label: {
                            VStack(spacing: 2) {
                                Text("\(scene.number)").font(.caption.weight(.bold))
                                Text(scene.saved ? (scene.name.isEmpty ? "저장됨" : scene.name) : "빈칸")
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(6)
                        }
                        .buttonStyle(DeskButtonStyle(selected: roninSelectedScene == scene.number, expand: true))
                    }
                }
                Toggle("2단 조작", isOn: $roninTwoStep)
                    .font(.caption)
                Button("지금 각을 장면 \(roninSelectedScene) 에 저장") {
                    if let idx = roninScenes.firstIndex(where: { $0.number == roninSelectedScene }) {
                        roninScenes[idx].pan = yaw
                        roninScenes[idx].tilt = pitch
                        roninScenes[idx].zoom = roninZoomSlider
                        roninScenes[idx].saved = true
                        roninScenes[idx].name = "로닌 \(roninSelectedScene)"
                        studio.note("로닌 장면 \(roninSelectedScene) 을 저장했습니다.")
                    }
                }
                .buttonStyle(DeskButtonStyle(selected: true, expand: true))
                if board.boardSlot == .rmsid {
                    Text("SC 줌은 아직 없습니다. UI·프로토콜 자리만 두었고, 나중에 켭니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("기본 시선 고정") {
                    studio.setHomeAim(board.id, yaw: wrapDegrees(spot.homeYaw + yaw), pitch: spot.homePitch + pitch)
                    yaw = 0
                    pitch = 0
                }
                .buttonStyle(DeskButtonStyle(selected: true, expand: true))
            } else {
                Text("조명 제어는 아래 칸입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func lightInspector(_ board: C3BoardRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(board.listTitle, systemImage: "lightbulb.fill")
                .font(.headline)
            Text("역할 \(board.roleTitle)")
                .font(.caption.weight(.semibold))
            TextField("기판 이름", text: Binding(get: { board.name }, set: { studio.renameC3(board.id, $0) }))
                .textFieldStyle(.roundedBorder)
            Text("\(board.link.title) · \(c3OnlineText(for: board).label) · \(board.socketHost):82")
                .font(.caption.weight(.semibold))
                .textSelection(.enabled)
            Text("와이파이 MAC \(board.wifiMac.isEmpty ? "아직 없음" : board.wifiMac)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Picker("연결", selection: Binding(get: { board.link }, set: { studio.chooseC3Mode(board.id, $0) })) {
                ForEach(BoardLane.c3Choices) { lane in
                    Text(lane.title).tag(lane)
                }
            }
            Button(c3Bag.state(for: board.id) == .connecting ? "연결 중" : "지금 연결") {
                studio.reconnectC3(board.id)
            }
            .buttonStyle(DeskButtonStyle(selected: c3Bag.state(for: board.id) == .online, expand: true))
            .disabled(c3Bag.state(for: board.id) == .connecting || !board.link.shoots)
            Text("울란지 VL120BI·VL200BI 입니다. 밝기·색온도·켜기/끄기는 아래 칸에서 조작합니다. ack true 일 때만 성공입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !c3(board).savedLights.isEmpty {
                Text("저장 \(c3(board).savedLights.count)대 · \(c3(board).savedLights.map(\.name).joined(separator: ", "))")
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private func cameraInspector(_ camera: BoardCamera) -> some View {
        let osmo = camera.ble == "FFF0" || camera.kind == "osmo"
        return VStack(alignment: .leading, spacing: 8) {
            Text(camera.name).font(.headline)
            Text(osmo ? "오즈모 액션 · 블루투스 리모컨 FFF0" : "오픈 고프로 · FEA6")
                .font(.caption)
                .foregroundStyle(.secondary)
            if osmo {
                Text("쓸 수 있는 것은 모드입니다. 해상도·프레임·흔들림 보정은 이 명령으로 바꾸지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("모드", selection: $osmoMode) {
                    ForEach(OsmoCatalog.actionModes, id: \.0) { item in
                        Text(item.1).tag(item.0)
                    }
                }
                Button("모드 보내기") {
                    Task {
                        await studio.sendCameraSetting(id: camera.id, name: camera.name, kind: camera.kind, ble: camera.ble, setting: "mode", value: String(osmoMode))
                    }
                }
                .buttonStyle(DeskButtonStyle(selected: true, expand: true))
            } else {
                Text("오픈 고프로에 공개된 설정 번호입니다. 카메라가 거절하면 로그에 상태 0이 아니라고 남습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(GoProCatalog.settings) { spec in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(spec.title).font(.caption.weight(.semibold))
                        HStack {
                            Picker(spec.title, selection: Binding(
                                get: { goproChoice[spec.id] ?? spec.options[0].value },
                                set: { goproChoice[spec.id] = $0 }
                            )) {
                                ForEach(spec.options) { option in
                                    Text(option.label).tag(option.value)
                                }
                            }
                            .labelsHidden()
                            Button("보내기") {
                                let value = goproChoice[spec.id] ?? spec.options[0].value
                                Task {
                                    await studio.sendCameraSetting(id: camera.id, name: camera.name, kind: camera.kind, ble: camera.ble, setting: String(spec.id), value: String(value))
                                }
                            }
                            .buttonStyle(DeskButtonStyle())
                        }
                    }
                }
            }
            HStack {
                Button("녹화") { Task { await setCamRecording(camera, start: true) } }
                    .buttonStyle(DeskButtonStyle(tone: .record))
                    .disabled(camRecordPending.contains(camera.id))
                Button("정지") { Task { await setCamRecording(camera, start: false) } }
                    .buttonStyle(DeskButtonStyle(tone: .stop))
                    .disabled(camRecordPending.contains(camera.id))
            }
            if camRecordPending.contains(camera.id) {
                Text("올리멕스 BLE 답 대기 · 아직 녹화로 두지 않음")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if camRecording.contains(camera.id) {
                Text("녹화 중 · 빨간 테두리(기판 BLE 확인)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(record)
            }
            HStack {
                Button("탈리 켜기") { Task { await studio.tally(camera, on: true) } }
                    .buttonStyle(DeskButtonStyle())
                Button("탈리 끄기") { Task { await studio.tally(camera, on: false) } }
                    .buttonStyle(DeskButtonStyle(tone: .stop))
            }
            Text(osmo
                 ? "액션 5 전면 탈리 명령은 없습니다. 앱도 전면 켜짐을 확인하지 못합니다. 빨간 테두리는 녹화가 시작될 때만 카메라가 켭니다. 울란지 조명과는 별개입니다."
                 : "고프로 탈리는 LED 설정 91입니다. 기판이 상태 0으로 답하기 전에는 켜졌다고 하지 않습니다. 전면 화면 글자는 그리지 않고, 앱도 전면 표시를 보지 못합니다. 울란지 조명과는 별개입니다.")
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
        let spot = studio.stageSpot(for: camera.id)
        let scenes = Array(PtzScene.ten(camera.scenes).prefix(9))
        return VStack(alignment: .leading, spacing: 8) {
            Label("PTZ 설정 · 프리셋", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.headline)
            TextField("카메라 이름", text: Binding(get: { camera.name }, set: { studio.renamePtz(camera.id, $0) }))
                .textFieldStyle(.roundedBorder)
            Text("\(camera.host) · ONVIF \(camera.onvifPort) · Visca \(camera.viscaPort)")
                .font(.caption.weight(.semibold))
            Text(ptzOnline.contains(camera.id) ? "온라인" : "오프라인")
                .font(.caption.weight(.bold))
                .foregroundStyle(ptzOnline.contains(camera.id)
                                 ? Color(red: 0.55, green: 0.85, blue: 0.55)
                                 : Color.white.opacity(0.55))
            Text("MAC \(camera.mac.isEmpty ? "아직 없음" : camera.mac)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text(camera.endpoint.isEmpty ? "ONVIF 주소를 찾는 중입니다." : camera.endpoint)
                .font(.caption)
                .textSelection(.enabled)
            Text("기본 시선 \(Int(spot.homeYaw))° · 팬 \(Int(wrapDegrees(spot.homeYaw + pose.yaw)))° · 틸트 \(Int(pose.pitch))° · 줌 \(String(format: "%.2f", pose.zoom))")
                .font(.caption.weight(.semibold))
            Text("조종판은 아래 칸입니다. 여기서는 설정과 장면 저장만 합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("프리셋")
                .font(.caption.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
                ForEach(scenes) { scene in
                    Button {
                        ptzSelectedScene[camera.id] = scene.number
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(scene.number)").font(.caption.weight(.bold))
                            Text(scene.saved ? (scene.name.isEmpty ? "저장됨" : scene.name) : "빈칸")
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(6)
                    }
                    .buttonStyle(DeskButtonStyle(selected: ptzSelectedScene[camera.id] == scene.number, expand: true))
                }
            }
            Toggle("2단 조작", isOn: $ptzTwoStep)
                .font(.caption)
            Button("지금 각을 장면 \(ptzSelectedScene[camera.id] ?? 1) 에 저장") {
                let number = ptzSelectedScene[camera.id] ?? 1
                let current = ptzPose[camera.id] ?? PtzPose()
                Task { await studio.savePtzScene(camera.id, number: number, pan: current.yaw, tilt: current.pitch, zoom: current.zoom) }
            }
            .buttonStyle(DeskButtonStyle(selected: true, expand: true))
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

    private var selectedRoninId: UUID? {
        if case .c3(let id) = pick,
           let board = studio.profile.c3Boards.first(where: { $0.id == id && $0.duty == .ronin }) {
            return board.id
        }
        return studio.roninC3?.id
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

    private func holdZoom(speed: Int, boardId: UUID) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                let now = Date()
                if !zoomHolding {
                    zoomHolding = true
                    zoomSentAt = now
                    Task { await studio.zoomRonin(speed: speed, boardId: boardId, quiet: true) }
                } else if now.timeIntervalSince(zoomSentAt) >= 0.45 {
                    zoomSentAt = now
                    Task { await studio.zoomRonin(speed: speed, boardId: boardId, quiet: true) }
                }
            }
            .onEnded { _ in
                zoomHolding = false
                Task { await studio.zoomRonin(speed: 0, boardId: boardId, quiet: true) }
            }
    }

    private func queueRonin(yaw: Double, pitch: Double, home: Bool = false) {
        roninPending = (yaw, pitch)
        let sendHome = home
        let boardId = selectedRoninId
        guard roninTask == nil else { return }
        roninTask = Task {
            while let next = roninPending {
                roninPending = nil
                await studio.nudgeRonin(yaw: next.0, pitch: next.1, quiet: true, home: sendHome && next.0 == 0 && next.1 == 0, boardId: boardId)
                // 펌웨어가 빠르게 ack 하면 큐 간격도 짧게(체감 <0.5s).
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            roninTask = nil
            if let pending = roninPending {
                queueRonin(yaw: pending.0, pitch: pending.1)
            }
        }
    }

    private func lightKey(_ boardId: UUID, _ index: Int) -> String {
        "\(boardId.uuidString)-\(index)"
    }

    /// 칸별 슬라이더: 최신값만 남기고 바로 보냅니다(짧은 간격으로 펌웨어 덮어쓰기와 맞춤).
    private func queueLight(_ boardId: UUID, index: Int) {
        let key = lightKey(boardId, index)
        lightSendTask[key]?.cancel()
        lightSendTask[key] = Task {
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            let brightness = Int(lightLevel[key] ?? 40)
            let kelvin = Int(lightKelvin[key] ?? 4500)
            let on = lightOnByKey[key] ?? true
            await studio.setLight(boardId, index: index, brightness: brightness, kelvin: kelvin, on: on, quiet: true)
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
                        sideTab = .ptz
                        if let last = studio.profile.ptzCameras.last {
                            pick = .ptz(last.id)
                        }
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
    var camRecording: Set<String> = []
    /// 울란지 대별 표시. 2대면 무대에 2개.
    var lightUnits: [(id: String, name: String, boardId: UUID, index: Int)] = []
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
                let lightRows = lightUnits.isEmpty
                    ? studio.profile.c3Boards.filter { $0.duty == .light }.map { (id: $0.id.uuidString, name: $0.name, boardId: $0.id, index: 0) }
                    : lightUnits
                let lightsByBoard = Dictionary(grouping: lightRows, by: \.boardId)
                for (boardId, units) in lightsByBoard {
                    let spot = studio.stageSpot(for: boardId)
                    let count = max(units.count, 1)
                    for (i, unit) in units.enumerated() {
                        let spread = count <= 1 ? 0.0 : (Double(i) - Double(count - 1) / 2.0) * 1.4
                        paint(
                            context: context,
                            size: size,
                            x: spot.x + spread,
                            y: spot.y,
                            aim: 0,
                            pitch: 0,
                            title: unit.name,
                            mark: "lightbulb.fill",
                            chosen: selected == boardId.uuidString,
                            useLens: false,
                            online: liveC3 == boardId
                        )
                    }
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
                        online: camerasOnline,
                        recording: camRecording.contains(camera.id)
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

    private func paint(context: GraphicsContext, size: CGSize, x: Double, y: Double, aim: Double, pitch: Double, title: String, mark: String, chosen: Bool, useLens: Bool, degrees: Double? = nil, throwMeters: Double? = nil, online: Bool = true, recording: Bool = false) {
        let at = plan(x: x, y: y, size: size)
        let fov = degrees ?? lens.degrees
        let reachBase = throwMeters ?? lens.throwMeters
        let reach = useLens ? reachBase * max(0.2, cos(pitch * .pi / 180)) : 1.8
        let recordRed = Color(red: 0.86, green: 0.28, blue: 0.28)
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
        let strokeColor: Color = recording ? recordRed : (chosen ? .white : .white.opacity(0.4))
        context.stroke(Path(roundedRect: box, cornerRadius: 8), with: .color(strokeColor), lineWidth: recording ? 3 : (chosen ? 2 : 1))
        let side = min(width, height) * 0.55
        var icon = context.resolve(Image(systemName: mark))
        icon.shading = .color(.white)
        context.draw(icon, in: CGRect(x: at.x - side / 2, y: at.y - side / 2 - 4, width: side, height: side))
        let state = recording ? "녹화" : (online ? "온라인" : "오프라인")
        let stateColor: Color = recording ? recordRed : (online ? Color(red: 0.55, green: 0.85, blue: 0.55) : Color.white.opacity(0.55))
        context.draw(Text(state).font(.caption2.weight(.bold)).foregroundStyle(stateColor), at: CGPoint(x: at.x, y: box.maxY - 2), anchor: .bottom)
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

/// 목록이 200으로 확인된 주소만 재생합니다.
private struct LivePicture: View {
    var title: String
    var url: URL
    var recording: Bool = false
    @State private var player: AVPlayer?
    private let recordRed = Color(red: 0.86, green: 0.28, blue: 0.28)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            VideoPlayer(player: player)
                .frame(width: 360, height: 200)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(recording ? recordRed : Color.white.opacity(0.2), lineWidth: recording ? 3 : 1)
                )
        }
        .onAppear {
            let next = AVPlayer(url: url)
            player = next
            next.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}
