import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#endif

enum FormFactor {
    static var phone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
}

enum Honest {
    static let ronin = "로닌은 별도 ESP32-POE 기판입니다. CAN 송신 GPIO13, 수신 GPIO16, 1Mbps, 웹은 80번입니다. 이 기판은 카메라 블루투스를 하지 않습니다."
    static let gopro = "HERO 등 액션 5 프로가 아닌 고프로는 이 기기가 카메라 와이파이에 직접 붙습니다. 기본 주소는 10.5.5.9 포트 8080, Open GoPro HTTP 입니다. 중계 컴퓨터가 없습니다."
    static let action5 = "액션 5 프로는 별도 중계 기판입니다. 앱은 그 기판의 집 와이파이 주소로만 HTTP를 보냅니다. 기판이 Open GoPro 블루투스(서비스 FEA6)를 한 번 붙여 유지합니다. 로닌 PoE가 아니고, 카메라 주소 10.5.5.9 도 아닙니다."
    static let osmo = "오즈모 액션·360은 이 기기가 카메라 블루투스(R SDK, FFF0)를 한 번 연결해 두고 그 세션으로 보냅니다. 고프로 프로토콜이 아닙니다."
    static let noAPI = "오즈모 포켓·모바일·나노는 공개된 제어 API가 없습니다. 목록에만 두고 명령은 보내지 않습니다."
    static let sync = "함께 시작은 로닌 기판의 시계에 CAN 녹화 명령을 맞춥니다. 고프로와 오즈모는 그 시각에 각자 직접 명령을 받습니다. 기판 시계만큼 딱 맞지는 않습니다."
}

struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension Studio {
    func deviceBinding(_ id: UUID) -> Binding<DeviceRecord> {
        Binding(
            get: {
                self.profile.devices.first(where: { $0.id == id }) ?? DeviceRecord(
                    id: id, name: "", kind: .ronin, osmoModel: .unknown,
                    host: "", port: 80, bleIdentifier: "", enabled: false, pairedOnce: false
                )
            },
            set: { newValue in
                guard let index = self.profile.devices.firstIndex(where: { $0.id == id }) else { return }
                self.profile.devices[index] = newValue
            }
        )
    }

    func presetBinding(_ id: UUID) -> Binding<ShootPreset> {
        Binding(
            get: {
                self.profile.presets.first(where: { $0.id == id }) ?? ShootPreset(
                    id: id, name: "", note: "", deviceIds: [],
                    ronin: RoninLook(shot: "wide", timeScale: 1, sendMove: false, yaw: 0, roll: 0, pitch: 0, seconds: 1.5, absolute: true),
                    gopro: GoProCatalog.freshLook(),
                    osmo: OsmoLook(mode: nil),
                    connections: []
                )
            },
            set: { newValue in
                guard let index = self.profile.presets.firstIndex(where: { $0.id == id }) else { return }
                self.profile.presets[index] = newValue
            }
        )
    }

    var practiceBinding: Binding<Bool> {
        Binding(get: { self.profile.practice }, set: { self.profile.practice = $0 })
    }

    var leadBinding: Binding<Int> {
        Binding(
            get: { self.profile.leadMs },
            set: { self.profile.leadMs = min(10000, max(0, $0)) }
        )
    }

    func groupBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { self.profile.groupIds.contains(id) },
            set: { on in
                if on {
                    if !self.profile.groupIds.contains(id) {
                        self.profile.groupIds.append(id)
                    }
                } else {
                    self.profile.groupIds.removeAll { $0 == id }
                }
            }
        )
    }
}

struct ApiBadge: View {
    var title: String
    var tint: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}

struct HoldButton: View {
    var title: String
    var press: () -> Void
    var release: () -> Void
    @State private var down = false

    var body: some View {
        Text(title)
            .font(.body.weight(.medium))
            .frame(minWidth: 88, minHeight: 40)
            .background(down ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !down {
                            down = true
                            press()
                        }
                    }
                    .onEnded { _ in
                        down = false
                        release()
                    }
            )
    }
}

struct GroupBar: View {
    @EnvironmentObject private var studio: Studio
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if studio.profile.practice {
                Text("연습 모드입니다. 명령을 장치에 보내지 않습니다.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if compact {
                Button("선택 장치 함께 시작") { Task { await studio.together(start: true) } }
                    .buttonStyle(.borderedProminent)
                Button("함께 정지") { Task { await studio.together(start: false) } }
                    .buttonStyle(.bordered)
                Stepper("여유 \(studio.profile.leadMs) ms", value: studio.leadBinding, in: 0...10000, step: 50)
                Toggle("연습", isOn: studio.practiceBinding)
            } else {
                HStack(spacing: 12) {
                    Button("선택 장치 함께 시작") { Task { await studio.together(start: true) } }
                        .buttonStyle(.borderedProminent)
                    Button("함께 정지") { Task { await studio.together(start: false) } }
                        .buttonStyle(.bordered)
                    Stepper("여유 \(studio.profile.leadMs) ms", value: studio.leadBinding, in: 0...10000, step: 50)
                    Toggle("연습", isOn: studio.practiceBinding)
                }
            }
            Text(Honest.sync)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LogList: View {
    @EnvironmentObject private var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !studio.frameOK {
                Text("오즈모 프레임 검사가 실패했습니다.")
                    .foregroundStyle(.red)
            }
            if studio.log.isEmpty {
                Text("아직 기록이 없습니다.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(studio.log.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

func readSecurityScoped(_ url: URL) -> Data? {
    let allowed = url.startAccessingSecurityScopedResource()
    defer { if allowed { url.stopAccessingSecurityScopedResource() } }
    return try? Data(contentsOf: url)
}
