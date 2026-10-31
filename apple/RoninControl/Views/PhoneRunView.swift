import SwiftUI

/// 아이폰 화면입니다. 카메라 와이파이에는 붙지 않습니다. C3가 들은 블루투스 광고 이름만 보여 줍니다.
struct PhoneRunView: View {
    @EnvironmentObject private var studio: Studio
    @State private var found: [NearbyGoPro] = []
    @State private var seek: PhoneSeek?
    @State private var connecting = false
    @State private var joiningMac = ""
    @State private var settingsCamera: UUID?

    private let canvas = StagePalette.paper
    private let rowFill = Color.white.opacity(0.72)

    private var board: DeviceRecord? {
        studio.profile.devices.first { $0.kind == .goproBridge && $0.enabled }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    controls
                    names
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
            .sheet(isPresented: settingsPresented) {
                settingsSheet
            }
        }
        .background(canvas)
        .foregroundStyle(StagePalette.ink)
        .preferredColorScheme(.light)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("카메라 와이파이 정보 화면에는 붙지 않습니다. 고프로는 장치 연결을 연 채로 두세요. 액션 5 프로에는 일반 블루투스 항목이 없습니다. 블루투스 리모컨 화면을 연 채로 두면, 그 동안 기판이 블루투스 리모컨으로 붙습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(connecting ? "연결 중" : "지금 연결") {
                Task { await connectNow() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(connecting || !joiningMac.isEmpty)
            HStack(spacing: 10) {
                Button("모두 녹화") { recordAll(true) }
                    .buttonStyle(.borderedProminent)
                Button("모두 정지") { recordAll(false) }
                    .buttonStyle(.bordered)
            }
            .disabled(board == nil)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var names: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("블루투스 이름")
                .font(.subheadline.weight(.semibold))
            if connecting {
                Text("기판이 페어링 중인 카메라를 찾는 중입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if found.isEmpty {
                Text(emptyLine)
                    .font(.subheadline)
                Text("고프로는 장치 연결, 액션 5 프로는 블루투스 리모컨을 연 뒤 지금 연결을 다시 누르세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(found, id: \.mac) { item in
                    nameRow(item)
                }
            }
            registeredNames
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyLine: String {
        switch seek {
        case .unreachable:
            return "기판에 닿지 못했습니다."
        case .nonePairing:
            return "기판에는 닿았고, 장치 연결이나 블루투스 리모컨 화면의 카메라는 없습니다."
        case .cameras, .none:
            return "아직 찾지 않았습니다. 지금 연결을 누르세요."
        }
    }

    @ViewBuilder private var registeredNames: some View {
        if let board {
            let saved = board.cameras.filter { BoardMac.isFull($0.mac) && !$0.advertisedName.isEmpty }
            let fresh = Set(found.map { BoardMac.normalize($0.mac) })
            let extra = saved.filter { !fresh.contains(BoardMac.normalize($0.mac)) }
            if !extra.isEmpty {
                Text("이미 연결한 카메라")
                    .font(.caption.weight(.semibold))
                    .padding(.top, 4)
                ForEach(extra) { camera in
                    HStack {
                        Text(camera.advertisedName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("설정") { settingsCamera = camera.id }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.bordered)
                    }
                    .font(.body)
                    .padding(8)
                    .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func nameRow(_ item: NearbyGoPro) -> some View {
        let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let busy = joiningMac == BoardMac.normalize(item.mac)
        return HStack {
            Button {
                Task { await join(item) }
            } label: {
                Text(busy ? "\(name) 연결 중" : name)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(busy || connecting)
            if let camera = savedCamera(item.mac) {
                Button("설정") { settingsCamera = camera.id }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
            }
        }
        .font(.body)
        .padding(8)
        .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func savedCamera(_ mac: String) -> BridgeCameraSlot? {
        board?.cameras.first { BoardMac.same($0.mac, mac) && !$0.advertisedName.isEmpty }
    }

    private func connectNow() async {
        connecting = true
        defer { connecting = false }
        guard let board = ensureBoard() else {
            seek = .unreachable
            found = []
            return
        }
        let result = await studio.phoneSeek(board.id)
        seek = result
        if case .cameras(let items) = result {
            found = items
        } else {
            found = []
        }
    }

    private func ensureBoard() -> DeviceRecord? {
        if let board { return board }
        let before = Set(studio.profile.devices.map(\.id))
        studio.addDevice(.goproBridge)
        return studio.profile.devices.first { $0.kind == .goproBridge && !before.contains($0.id) }
            ?? studio.profile.devices.first { $0.kind == .goproBridge }
    }

    private func join(_ item: NearbyGoPro) async {
        guard let board else { return }
        joiningMac = BoardMac.normalize(item.mac)
        defer { joiningMac = "" }
        await studio.phoneJoin(board.id, item)
    }

    private func recordAll(_ start: Bool) {
        guard let board else { return }
        Task { await studio.bridgeRecord(board, start: start) }
    }

    private var settingsPresented: Binding<Bool> {
        Binding(
            get: { settingsCamera != nil },
            set: { if !$0 { settingsCamera = nil } }
        )
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                if let board, let settingsCamera, board.cameras.contains(where: { $0.id == settingsCamera }) {
                    DeviceForm(radio: studio.radio, deviceId: board.id, cameraId: settingsCamera)
                } else {
                    Text("카메라를 먼저 연결하세요.")
                }
            }
            .navigationTitle("카메라 설정")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button("닫기") { settingsCamera = nil }
            }
        }
        .stagePopup()
    }
}
