import SwiftUI

/// 아이폰 화면입니다. 로닌과 짐벌 휠은 없습니다. C3 중계와 그 카메라만 다룹니다.
struct PhoneRunView: View {
    @EnvironmentObject private var studio: Studio
    @State private var selectedCamera: UUID?
    @State private var showSettings = false
    @State private var connecting = false

    private let canvas = StagePalette.paper
    private let rowFill = Color.white.opacity(0.72)

    private var board: DeviceRecord? {
        studio.profile.devices.first { $0.kind == .goproBridge && $0.enabled }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let board {
                        boardCard(board)
                        cameraList(board)
                    } else {
                        emptyBoard
                    }
                    LogList()
                        .padding(12)
                        .background(rowFill, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(16)
            }
            .background(canvas)
            .navigationTitle("C3 중계")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sheet(isPresented: $showSettings) {
                settingsSheet
            }
        }
        .background(canvas)
        .foregroundStyle(StagePalette.ink)
        .preferredColorScheme(.light)
    }

    private var emptyBoard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("이 폰은 C3 중계 기판만 연결합니다. 주소는 192.168.100.200 이고, 공유기가 없으면 Ronin-C3 입니다.")
                .font(.subheadline)
            Text("카메라는 고프로 11, 고프로 12, 액션 5 프로입니다. 블루투스로만 붙습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("C3 중계 넣기") { addRelay() }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private func boardCard(_ board: DeviceRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(board.name)
                .font(.headline)
            Text("맥 \(BoardMac.normalize(board.boardMac.isEmpty ? BoardMac.pluggedIn : board.boardMac))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(studio.bridgeWifiLine(board.id))
                .font(.caption)
            Text(studio.bridgeDirectLine(board.id))
                .font(.caption)
            Text(studio.bridgePhase[board.id] ?? "기판을 찾는 중입니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(connecting ? "연결 중" : "지금 연결") {
                connecting = true
                Task {
                    await studio.scanBoard(board.id)
                    connecting = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(connecting)
            HStack(spacing: 10) {
                Button("모두 녹화") {
                    Task { await studio.bridgeRecord(board, start: true) }
                }
                .buttonStyle(.borderedProminent)
                Button("모두 정지") {
                    Task { await studio.bridgeRecord(board, start: false) }
                }
                .buttonStyle(.bordered)
            }
            Text("세 대에 같은 버튼을 누릅니다. 기판 라디오가 하나라서 녹화는 한 대씩 이어서 나갑니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private func cameraList(_ board: DeviceRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("카메라")
                .font(.subheadline.weight(.semibold))
            Text("한 대를 고르면 그 카메라 설정만 엽니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if board.cameras.isEmpty {
                Text("카메라 칸이 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(board.cameras.enumerated()), id: \.element.id) { index, camera in
                cameraLine(board, index: index, camera: camera)
            }
            if board.cameras.count < 4 {
                Button("카메라 추가") { studio.addCamera(board.id) }
                    .font(.caption.weight(.semibold))
            }
            Button("주변 카메라 찾기") {
                Task { await studio.scanCameras(board.id) }
            }
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private func cameraLine(_ board: DeviceRecord, index: Int, camera: BridgeCameraSlot) -> some View {
        let picked = selectedCamera == camera.id
        let face = camera.face ?? ProductFace.inferred(device: board, camera: camera)
        let title = ProductFace.phoneCameras.contains(face) ? face.title : camera.role.title
        return HStack(spacing: 8) {
            Button {
                selectedCamera = camera.id
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1). \(title)")
                    Text(BoardMac.isFull(camera.mac) ? BoardMac.normalize(camera.mac) : "맥 없음")
                        .foregroundStyle(.secondary)
                    Text(studio.bridgeLive[board.id]?.attachment(for: camera) ?? "아직 읽지 못했습니다.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button("설정") {
                selectedCamera = camera.id
                showSettings = true
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
        }
        .font(.caption)
        .padding(8)
        .background(picked ? StagePalette.brass.opacity(0.28) : Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func addRelay() {
        let before = Set(studio.profile.devices.map(\.id))
        studio.addDevice(.goproBridge)
        guard let device = studio.profile.devices.first(where: { $0.kind == .goproBridge && !before.contains($0.id) }) else { return }
        let plan: [(ProductFace, BridgeCameraRole)] = [
            (.hero11, .gopro),
            (.hero12, .gopro),
            (.action5Pro, .action5),
        ]
        for _ in plan {
            studio.addCamera(device.id)
        }
        guard let index = studio.profile.devices.firstIndex(where: { $0.id == device.id }) else { return }
        var slots = studio.profile.devices[index].cameras
        for offset in slots.indices where offset < plan.count {
            slots[offset].face = plan[offset].0
            slots[offset].role = plan[offset].1
        }
        studio.profile.devices[index].cameras = slots
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                if let board, let selectedCamera, board.cameras.contains(where: { $0.id == selectedCamera }) {
                    DeviceForm(radio: studio.radio, deviceId: board.id, cameraId: selectedCamera)
                } else {
                    Text("카메라를 먼저 고르세요.")
                }
            }
            .navigationTitle("카메라 설정")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("닫기") { showSettings = false }
            }
        }
        .stagePopup()
    }
}
