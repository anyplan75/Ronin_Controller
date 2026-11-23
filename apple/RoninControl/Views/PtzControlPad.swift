import SwiftUI

/// 참고 이미지형 PTZ·로닌 조작판입니다. 8방향 D-pad + Speed/Zoom/Focus + Iris + 프리셋 그리드.
struct PtzControlPad: View {
    var title: String = "PTZ"
    @Binding var speed: Double
    @Binding var zoom: Double
    @Binding var focus: Double
    @Binding var iris: Double
    var showFocus: Bool = true
    var showIris: Bool = true
    var showZoom: Bool = true
    /// false 이면 장면 그리드·이동경로를 숨기고 D-pad·슬라이더만(프리셋은 오른쪽 패널).
    var showSceneGrid: Bool = true
    var showMovePaths: Bool = true
    var padSize: CGFloat = 118
    var scenes: [PtzScene]
    var selectedScene: Int?
    var twoStep: Binding<Bool>
    var onNudge: (_ pan: Double, _ tilt: Double) -> Void
    var onStop: () -> Void
    /// 가운데 버튼: 제자리(홈). nil 이면 onStop 만 호출합니다.
    var onHome: (() -> Void)? = nil
    var onZoomChanged: (Double) -> Void
    var onFocusHold: (Int) -> Void
    var onFocusStop: () -> Void
    var onIrisStep: (Int) -> Void
    var onIrisAuto: () -> Void
    var onSelectScene: (Int) -> Void
    var onRecall: () -> Void
    var onStopPreset: () -> Void
    var movePaths: [PtzMovePath] = []
    var onRecallPath: ((PtzMovePath) -> Void)?
    var onAddPathStep: ((Int) -> Void)?
    var onClearPath: (() -> Void)?

    private let accent = Color(red: 0.18, green: 0.55, blue: 0.95)
    private let pad = Color(red: 0.16, green: 0.17, blue: 0.19)
    private let ink = Color.white.opacity(0.92)

    var body: some View {
        // 조종부 크게. 장면/이동 프리셋은 오른쪽 패널로 보냄(showSceneGrid/showMovePaths).
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ink)
            HStack(alignment: .center, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    eightWayPad
                        .frame(width: padSize, height: padSize)
                    HStack(alignment: .bottom, spacing: 10) {
                        verticalSlider(
                            top: "Fast",
                            bottom: "Slow",
                            label: "Speed",
                            value: $speed,
                            range: 0.15...1
                        )
                        if showZoom {
                            verticalSlider(
                                top: "Tele",
                                bottom: "Wide",
                                label: "Zoom",
                                value: Binding(
                                    get: { zoom },
                                    set: { zoom = $0; onZoomChanged($0) }
                                ),
                                range: 0...1
                            )
                        }
                        if showFocus {
                            focusHoldColumn
                        }
                        if showIris {
                            irisColumn
                        }
                    }
                }
                .padding(10)
                .background(pad, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .leading)

                if showSceneGrid {
                    presetBlock
                        .padding(8)
                        .background(pad, in: RoundedRectangle(cornerRadius: 10))
                }
            }

            if showMovePaths, !movePaths.isEmpty || onAddPathStep != nil {
                movePathBlock
                    .padding(8)
                    .background(pad, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var eightWayPad: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.55))
                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
            ForEach(PadDir.allCases) { dir in
                padWedge(dir)
            }
            VStack(spacing: 0) {
                Text("홈")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ink)
            }
            .frame(width: 48, height: 48)
            .background(Color(red: 0.28, green: 0.29, blue: 0.32), in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.45), lineWidth: 1.5))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { _ in
                        if let onHome {
                            onHome()
                        } else {
                            onStop()
                        }
                    }
            )
            .accessibilityLabel("제자리")
        }
    }

    /// 화살표 글자를 돌리지 않고 자리만 옮깁니다. (돌리면 ▲ 가 옆으로 누워 방향이 틀어집니다.)
    private func padWedge(_ dir: PadDir) -> some View {
        let rad = dir.degrees * .pi / 180
        return Text(dir.symbol)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(ink)
            .frame(width: 40, height: 40)
            .background(Color.white.opacity(0.08), in: Circle())
            .offset(x: CGFloat(sin(rad) * 40), y: CGFloat(-cos(rad) * 40))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onNudge(dir.pan, dir.tilt) }
                    .onEnded { _ in onStop() }
            )
            .accessibilityLabel(dir.label)
    }

    private func verticalSlider(top: String, bottom: String, label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        let track = max(84, padSize * 0.72)
        return VStack(spacing: 4) {
            Text(top).font(.caption2).foregroundStyle(.secondary)
            Slider(value: value, in: range)
                .rotationEffect(.degrees(-90))
                .frame(width: track, height: 24)
                .frame(width: 28, height: track)
                .tint(accent)
            Text(bottom).font(.caption2).foregroundStyle(.secondary)
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(ink)
        }
        .frame(width: 40)
    }

    private var focusHoldColumn: some View {
        VStack(spacing: 4) {
            Text("Far").font(.caption2).foregroundStyle(.secondary)
            Text("▲")
                .font(.caption2.weight(.bold))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in onFocusHold(1) }
                        .onEnded { _ in onFocusStop() }
                )
            Slider(value: $focus, in: 0...1)
                .rotationEffect(.degrees(-90))
                .frame(width: 70, height: 20)
                .frame(width: 26, height: 70)
                .tint(accent)
            Text("▼")
                .font(.caption2.weight(.bold))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in onFocusHold(-1) }
                        .onEnded { _ in onFocusStop() }
                )
            Text("Focus").font(.caption2.weight(.semibold)).foregroundStyle(ink)
        }
        .frame(width: 40)
    }

    private var irisColumn: some View {
        VStack(spacing: 6) {
            Button("+") { onIrisStep(1) }
                .buttonStyle(DeskButtonStyle())
                .frame(width: 36)
            Slider(value: $iris, in: 0...1)
                .rotationEffect(.degrees(-90))
                .frame(width: 70, height: 20)
                .frame(width: 26, height: 70)
                .tint(accent)
            Button("−") { onIrisStep(-1) }
                .buttonStyle(DeskButtonStyle())
                .frame(width: 36)
            Button("Auto") { onIrisAuto() }
                .buttonStyle(DeskButtonStyle(selected: true))
                .frame(width: 44)
            Text("Iris").font(.caption2.weight(.semibold)).foregroundStyle(ink)
        }
        .frame(width: 48)
    }

    private var presetBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("2 Step", isOn: twoStep)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                Spacer(minLength: 0)
                Button("Recall") { onRecall() }
                    .buttonStyle(DeskButtonStyle(selected: true))
                Button("Stop") { onStopPreset() }
                    .buttonStyle(DeskButtonStyle())
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Array(scenes.prefix(9))) { scene in
                    Button {
                        onSelectScene(scene.number)
                        if !twoStep.wrappedValue {
                            onRecall()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(scene.number)")
                                .font(.caption2.weight(.bold))
                            Text(scene.name)
                                .font(.caption2)
                                .lineLimit(1)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.black.opacity(0.55))
                                .frame(height: 22)
                                .overlay(
                                    Text(scene.saved ? "저장" : "빈칸")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                )
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedScene == scene.number ? accent.opacity(0.25) : Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(selectedScene == scene.number ? accent : Color.white.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!scene.saved && twoStep.wrappedValue == false)
                }
            }
        }
    }

    private var movePathBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("이동형 프리셋 (뮤비·생방)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ink)
            Text("정지 장면을 순서대로 불러 경로를 만듭니다. Recall 은 시퀀스, Stop 은 중단입니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let onAddPathStep {
                HStack {
                    ForEach([1, 2, 3, 4, 5], id: \.self) { n in
                        Button("+\(n)") { onAddPathStep(n) }
                            .buttonStyle(DeskButtonStyle())
                    }
                    if let onClearPath {
                        Button("경로 비우기") { onClearPath() }
                            .buttonStyle(DeskButtonStyle())
                    }
                }
            }
            ForEach(movePaths) { path in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(path.name).font(.caption.weight(.semibold))
                        Text(path.steps.map { "\($0.sceneNumber)" }.joined(separator: " → "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Recall") { onRecallPath?(path) }
                        .buttonStyle(DeskButtonStyle(selected: true))
                    Button("Stop") { onStopPreset() }
                        .buttonStyle(DeskButtonStyle())
                }
            }
        }
    }
}

private enum PadDir: Int, CaseIterable, Identifiable {
    case up, upRight, right, downRight, down, downLeft, left, upLeft
    var id: Int { rawValue }
    var degrees: Double {
        switch self {
        case .up: return 0
        case .upRight: return 45
        case .right: return 90
        case .downRight: return 135
        case .down: return 180
        case .downLeft: return 225
        case .left: return 270
        case .upLeft: return 315
        }
    }
    var pan: Double {
        switch self {
        case .left, .upLeft, .downLeft: return -1
        case .right, .upRight, .downRight: return 1
        default: return 0
        }
    }
    var tilt: Double {
        switch self {
        case .up, .upLeft, .upRight: return 1
        case .down, .downLeft, .downRight: return -1
        default: return 0
        }
    }
    var symbol: String {
        switch self {
        case .up: return "▲"
        case .down: return "▼"
        case .left: return "◀"
        case .right: return "▶"
        case .upLeft: return "↖"
        case .upRight: return "↗"
        case .downLeft: return "↙"
        case .downRight: return "↘"
        }
    }
    var label: String {
        switch self {
        case .up: return "위"
        case .down: return "아래"
        case .left: return "왼쪽"
        case .right: return "오른쪽"
        case .upLeft: return "왼쪽 위"
        case .upRight: return "오른쪽 위"
        case .downLeft: return "왼쪽 아래"
        case .downRight: return "오른쪽 아래"
        }
    }
}

#if os(macOS)
private extension ToggleStyle where Self == CheckboxToggleStyle {
    static var checkbox: CheckboxToggleStyle { CheckboxToggleStyle() }
}
#else
private struct SimpleCheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}
private extension ToggleStyle where Self == SimpleCheckToggleStyle {
    static var checkbox: SimpleCheckToggleStyle { SimpleCheckToggleStyle() }
}
#endif
