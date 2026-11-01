import SwiftUI

/// 아이폰 화면입니다. 맥과 같은 올리멕스 기판 웹소켓만 씁니다. 카메라 와이파이에는 붙지 않습니다.
struct PhoneRunView: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var link: BoardSocket
    @State private var selected: BoardCamera?
    @State private var showSettings = false
    @State private var fov = "와이드"
    @State private var resolution = "1080p"

    private let canvas = StagePalette.paper
    private let rowFill = Color.white.opacity(0.72)

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
            .navigationTitle("기판")
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

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("올리멕스 ESP32-PoE 한 장입니다. PoE는 192.168.0.150:81, 와이파이는 192.168.0.151:81 웹소켓입니다. 액션 카메라는 그 기판 블루투스입니다. 카메라 와이파이에는 붙지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("길", selection: laneBinding) {
                ForEach(BoardLane.allCases) { lane in
                    Text(lane.title).tag(lane)
                }
            }
            .pickerStyle(.segmented)
            Text(link.detail)
                .font(.subheadline.weight(.semibold))
            Button(link.state == .connecting ? "연결 중" : "지금 연결") {
                link.connect()
            }
            .buttonStyle(.borderedProminent)
            .disabled(link.state == .connecting)
            HStack(spacing: 10) {
                Button("모두 녹화") { Task { await studio.fieldRecord(group: "all", start: true) } }
                    .buttonStyle(.borderedProminent)
                Button("모두 정지") { Task { await studio.fieldRecord(group: "all", start: false) } }
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private var laneBinding: Binding<BoardLane> {
        Binding(
            get: { link.lane },
            set: { studio.chooseLane($0) }
        )
    }

    @ViewBuilder private var names: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("블루투스 이름")
                .font(.subheadline.weight(.semibold))
            if link.state == .connecting {
                Text("기판 81번 문을 여는 중입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if link.cameras.isEmpty {
                Text(emptyLine)
                    .font(.subheadline)
                Text("고프로는 장치 연결, 액션 5 프로는 블루투스 리모컨을 연 뒤 지금 연결을 다시 누르세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(link.cameras) { camera in
                    HStack {
                        Text(camera.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("설정") {
                            selected = camera
                            showSettings = true
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                    }
                    .font(.body)
                    .padding(8)
                    .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyLine: String {
        switch link.state {
        case .offline:
            return "기판에 닿지 못했습니다."
        case .connecting:
            return "기판 81번 문을 여는 중입니다."
        case .online:
            return "기판에는 닿았고, 블루투스로 붙은 카메라는 없습니다."
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                if let camera = selected {
                    Text(camera.name)
                    Text("블루투스 \(camera.ble)")
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
                            await studio.sendCameraSetting(
                                id: camera.id,
                                kind: camera.kind,
                                ble: camera.ble,
                                setting: "fov",
                                value: fov
                            )
                            await studio.sendCameraSetting(
                                id: camera.id,
                                kind: camera.kind,
                                ble: camera.ble,
                                setting: "resolution",
                                value: resolution
                            )
                        }
                    }
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
