import SwiftUI

/// 휠을 누르는 동안 그 로닌의 무대 방향입니다. 각도는 도입니다.
struct StageDrive: Equatable, Identifiable {
    var id: UUID { deviceId }
    var deviceId: UUID
    var yaw: Double
    var pitch: Double
}

/// RTA Station 무대와 같은 빈 방입니다.
/// 가로 14m, 깊이 18m, 높이 6.5m. 바닥 눈금은 2m, 앞쪽에는 낮은 단이 있습니다.
/// 주파수 그림, 바닥 열지도, 반사선, 마이크-스피커 연결선은 여기 그리지 않습니다.
enum StageRoom {
    static let width = 14.0
    static let length = 18.0
    static let height = 6.5
    /// 기판이 렌즈 화각을 알려 주지 않습니다. 스피커의 가로 공개 각도처럼 90°만 그립니다.
    static let fieldDegrees = 90.0

    static func place(index: Int, count: Int) -> (x: Double, y: Double, z: Double) {
        let span = min(width * 0.62, Double(max(count - 1, 1)) * 1.6)
        let t = count <= 1 ? 0.5 : Double(index) / Double(max(count - 1, 1))
        let x = -span / 2 + span * t
        return (x, 1.6, 1.6)
    }
}

/// 기판이 실제로 받는 짐벌 각도입니다. 이동 명령은 요 -180°~180°, 피치 -56°~146°에서 잘립니다.
enum RoninTravel {
    static let yawMin = -180.0
    static let yawMax = 180.0
    static let pitchMin = -56.0
    static let pitchMax = 146.0

    static func clampYaw(_ value: Double) -> Double {
        min(yawMax, max(yawMin, value))
    }

    static func clampPitch(_ value: Double) -> Double {
        min(pitchMax, max(pitchMin, value))
    }

    /// 스틱을 끝까지 밀면 그 방향의 끝 각도에 닿습니다. 가운데는 저장한 제자리입니다.
    static func yaw(from home: Double, stickRight: Double) -> Double {
        let base = clampYaw(home)
        let t = min(1, max(-1, stickRight))
        if t >= 0 {
            return base + t * (yawMax - base)
        }
        return base + t * (base - yawMin)
    }

    /// 아래로 밀면 피치가 커집니다. 기판에서 위는 음수입니다.
    static func pitch(from home: Double, stickDown: Double) -> Double {
        let base = clampPitch(home)
        let t = min(1, max(-1, stickDown))
        if t >= 0 {
            return base + t * (pitchMax - base)
        }
        return base + t * (base - pitchMin)
    }
}

enum StagePalette {
    static let paper = Color(red: 244 / 255, green: 239 / 255, blue: 230 / 255)
    static let ink = Color(red: 28 / 255, green: 25 / 255, blue: 21 / 255)
    static let rule = Color(red: 28 / 255, green: 25 / 255, blue: 21 / 255).opacity(0.12)
    static let box = Color(red: 28 / 255, green: 25 / 255, blue: 21 / 255).opacity(0.72)
    static let oxblood = Color(red: 122 / 255, green: 46 / 255, blue: 52 / 255)
    static let brass = Color(red: 138 / 255, green: 106 / 255, blue: 50 / 255)
    static let stageFill = Color(red: 56 / 255, green: 189 / 255, blue: 248 / 255).opacity(0.12)
    static let stageLine = Color(red: 56 / 255, green: 189 / 255, blue: 248 / 255).opacity(0.5)
    static let hitFill = Color(red: 28 / 255, green: 63 / 255, blue: 115 / 255)
    static let hitLine = Color(red: 244 / 255, green: 239 / 255, blue: 230 / 255)
}

private struct StageCamera {
    var yaw = -0.58
    var pitch = 0.46
    var zoom = 1.05
}

private struct StagePoint {
    var x: Double
    var y: Double
    var z: Double
}

/// 고른 장치의 무대 자리입니다. 오른쪽 설정에 둡니다.
struct StagePlacementControls: View {
    @EnvironmentObject private var studio: Studio
    let deviceId: UUID

    var body: some View {
        let spot = studio.stageSpot(for: deviceId)
        VStack(spacing: 2) {
            meter("좌우", value: spot.x, range: -StageRoom.width * 0.48...StageRoom.width * 0.48, signed: true) {
                studio.moveStage(deviceId: deviceId, x: $0)
            }
            meter("깊이", value: spot.y, range: 0.4...StageRoom.length - 0.4, signed: false) {
                studio.moveStage(deviceId: deviceId, y: $0)
            }
            meter("높이", value: spot.z, range: 0.2...StageRoom.height - 0.3, signed: false) {
                studio.moveStage(deviceId: deviceId, z: $0)
            }
            meter("방향", value: spot.aimYaw, range: -180...180, signed: true, suffix: "°") {
                studio.moveStage(deviceId: deviceId, aimYaw: $0)
            }
        }
    }

    private func meter(
        _ title: String,
        value: Double,
        range: ClosedRange<Double>,
        signed: Bool,
        suffix: String = " m",
        set: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .frame(width: 34, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
                .tint(.accentColor)
            Text(readout(value, signed: signed, suffix: suffix))
                .frame(width: 52, alignment: .trailing)
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.primary)
    }

    private func readout(_ value: Double, signed: Bool, suffix: String) -> String {
        if suffix == "°" { return "\(Int(value.rounded()))°" }
        return String(format: signed ? "%+.1f" : "%.1f", value) + suffix
    }
}

/// 등록된 장치를 방에 두고, 바라보는 방향을 정하는 화면입니다.
struct StageBoard: View {
    @EnvironmentObject private var studio: Studio
    @Binding var selection: UUID?
    var drives: [StageDrive]

    @State private var camera = StageCamera()
    @State private var zoomBase = 1.05
    @State private var orbitFrom = CGSize.zero
    /// 0은 아직 모름, 1은 장치 고르기, 2는 방 돌리기입니다.
    @State private var dragKind = 0

    var body: some View {
        room
            .clipped()
            .background(StagePalette.paper)
            .overlay(alignment: .bottomLeading) {
                Text("빈 곳을 끌면 방이 돌아갑니다. 장치를 누르면 고릅니다.")
                    .font(.caption2)
                    .foregroundStyle(StagePalette.ink)
                    .padding(6)
                    .background(StagePalette.paper.opacity(0.88), in: RoundedRectangle(cornerRadius: 6))
                    .padding(6)
            }
            .onAppear {
                studio.ensureStageSpots()
                if selection == nil { selection = studio.profile.devices.first?.id }
            }
            .onChange(of: studio.profile.devices.map(\.id)) { _, ids in
                if let selection, !ids.contains(selection) {
                    self.selection = ids.first
                }
            }
        .task(id: drives.isEmpty) {
            while !Task.isCancelled {
                await studio.refreshMarks()
                let pause: UInt64 = drives.isEmpty ? 2_000_000_000 : 400_000_000
                try? await Task.sleep(nanoseconds: pause)
            }
        }
    }

    private var room: some View {
        GeometryReader { geo in
            Canvas { context, size in
                paint(context: context, size: size)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if dragKind == 0 {
                            if let hit = pick(value.startLocation, in: geo.size) {
                                selection = hit
                                dragKind = 1
                            } else {
                                dragKind = 2
                                orbitFrom = value.translation
                            }
                        }
                        guard dragKind == 2 else { return }
                        let dx = value.translation.width - orbitFrom.width
                        let dy = value.translation.height - orbitFrom.height
                        orbitFrom = value.translation
                        camera.yaw += dx * 0.008
                        camera.pitch = min(1.48, max(0.08, camera.pitch + dy * 0.008))
                    }
                    .onEnded { _ in
                        dragKind = 0
                        orbitFrom = .zero
                    }
            )
            .onTapGesture { location in
                if let hit = pick(location, in: geo.size) {
                    selection = hit
                }
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        camera.zoom = min(2.4, max(0.55, zoomBase * value.magnification))
                    }
                    .onEnded { _ in
                        zoomBase = camera.zoom
                    }
            )
        }
    }

    private func paint(context: GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .color(StagePalette.paper))
        let halfW = StageRoom.width * 0.5
        let length = StageRoom.length
        let height = StageRoom.height

        var grid = Path()
        var x = -floor(halfW)
        while x <= floor(halfW) {
            let a = project(StagePoint(x: x, y: 0, z: 0), size: size)
            let b = project(StagePoint(x: x, y: length, z: 0), size: size)
            grid.move(to: a)
            grid.addLine(to: b)
            x += 2
        }
        var y = 0.0
        while y <= length {
            let a = project(StagePoint(x: -halfW, y: y, z: 0), size: size)
            let b = project(StagePoint(x: halfW, y: y, z: 0), size: size)
            grid.move(to: a)
            grid.addLine(to: b)
            y += 2
        }
        context.stroke(grid, with: .color(StagePalette.rule), lineWidth: 1)

        let corners = [
            StagePoint(x: -halfW, y: 0, z: 0), StagePoint(x: halfW, y: 0, z: 0),
            StagePoint(x: halfW, y: length, z: 0), StagePoint(x: -halfW, y: length, z: 0),
            StagePoint(x: -halfW, y: 0, z: height), StagePoint(x: halfW, y: 0, z: height),
            StagePoint(x: halfW, y: length, z: height), StagePoint(x: -halfW, y: length, z: height),
        ]
        let edges = [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]
        var roomBox = Path()
        for edge in edges {
            roomBox.move(to: project(corners[edge[0]], size: size))
            roomBox.addLine(to: project(corners[edge[1]], size: size))
        }
        context.stroke(roomBox, with: .color(StagePalette.box), lineWidth: 1.25)

        let deck = [
            StagePoint(x: -halfW * 0.7, y: 0.2, z: 0.4),
            StagePoint(x: halfW * 0.7, y: 0.2, z: 0.4),
            StagePoint(x: halfW * 0.7, y: 2.2, z: 0.4),
            StagePoint(x: -halfW * 0.7, y: 2.2, z: 0.4),
        ]
        var platform = Path()
        platform.move(to: project(deck[0], size: size))
        platform.addLine(to: project(deck[1], size: size))
        platform.addLine(to: project(deck[2], size: size))
        platform.addLine(to: project(deck[3], size: size))
        platform.closeSubpath()
        context.fill(platform, with: .color(StagePalette.stageFill))
        context.stroke(platform, with: .color(StagePalette.stageLine), lineWidth: 1)

        for device in studio.profile.devices {
            let spot = studio.stageSpot(for: device.id)
            let at = StagePoint(x: spot.x, y: spot.y, z: spot.z)
            let floor = project(StagePoint(x: spot.x, y: spot.y, z: 0), size: size)
            let top = project(at, size: size)
            var stem = Path()
            stem.move(to: floor)
            stem.addLine(to: top)
            context.stroke(stem, with: .color(StagePalette.ink.opacity(0.35)), lineWidth: 1)

            let yaw = spot.aimYaw * .pi / 180
            let tip = project(StagePoint(
                x: spot.x + sin(yaw) * 1.8,
                y: spot.y + cos(yaw) * 1.8,
                z: spot.z
            ), size: size)
            var aim = Path()
            aim.move(to: top)
            aim.addLine(to: tip)
            context.stroke(aim, with: .color(StagePalette.brass), lineWidth: 1.5)

            if device.kind == .ronin {
                if let drive = drives.first(where: { $0.deviceId == device.id }) {
                    paintCoverage(context: context, size: size, spot: spot, yaw: drive.yaw, pitch: drive.pitch)
                } else {
                    paintCoverage(
                        context: context,
                        size: size,
                        spot: spot,
                        yaw: spot.aimYaw + RoninTravel.clampYaw(spot.homeYaw),
                        pitch: -RoninTravel.clampPitch(spot.homePitch)
                    )
                }
            }

            let chosen = device.id == selection
            paintGlyph(context: context, device: device, at: top, aim: tip, chosen: chosen, recording: recordMark(device) != nil)
            if let mark = recordMark(device) {
                context.draw(
                    Text(mark).font(.system(size: 10, weight: .bold)).foregroundStyle(StagePalette.oxblood),
                    at: CGPoint(x: top.x, y: top.y - 28),
                    anchor: .bottom
                )
            }
            context.draw(
                Text(device.name).font(.system(size: 11, weight: chosen ? .bold : .semibold)).foregroundStyle(StagePalette.ink),
                at: CGPoint(x: top.x, y: top.y - 16),
                anchor: .bottom
            )
        }
    }

    /// 스피커 빔과 같습니다. 가운데 빛은 저장해 둔 제자리 방향입니다.
    private func paintCoverage(context: GraphicsContext, size: CGSize, spot: StageSpot, yaw: Double, pitch: Double) {
        let half = StageRoom.fieldDegrees * .pi / 180 / 2
        let yawRadians = yaw * .pi / 180
        let pitchRadians = pitch * .pi / 180
        let steps = 14
        let rings = 10
        var rays: [(ang: Double, dir: StagePoint, dist: Double)] = []
        for step in 0...steps {
            let ang = -half + (half * 2) * Double(step) / Double(steps)
            let heading = yawRadians + ang
            let dir = StagePoint(
                x: sin(heading) * cos(pitchRadians),
                y: cos(heading) * cos(pitchRadians),
                z: sin(pitchRadians)
            )
            let dist = roomExit(origin: StagePoint(x: spot.x, y: spot.y, z: spot.z), direction: dir)
            rays.append((ang, dir, dist))
        }
        func point(ray: (ang: Double, dir: StagePoint, dist: Double), distance: Double) -> CGPoint {
            project(StagePoint(
                x: spot.x + ray.dir.x * distance,
                y: spot.y + ray.dir.y * distance,
                z: spot.z + ray.dir.z * distance
            ), size: size)
        }
        for step in 0..<steps {
            let left = rays[step]
            let right = rays[step + 1]
            if left.dist <= 0.02 && right.dist <= 0.02 { continue }
            let onAxis = 1 - min(1, abs((left.ang + right.ang) / 2) / half)
            for ring in 0..<rings {
                let f0 = Double(ring) / Double(rings)
                let f1 = Double(ring + 1) / Double(rings)
                let near = 1 - (f0 + f1) / 2
                var cell = Path()
                cell.move(to: point(ray: left, distance: left.dist * f0))
                cell.addLine(to: point(ray: right, distance: right.dist * f0))
                cell.addLine(to: point(ray: right, distance: right.dist * f1))
                cell.addLine(to: point(ray: left, distance: left.dist * f1))
                cell.closeSubpath()
                context.fill(cell, with: .color(coverageColor(onAxis: onAxis, near: near)))
            }
        }
        for ray in rays where ray.dist > 0.02 {
            let hit = point(ray: ray, distance: ray.dist)
            let mark = Path(ellipseIn: CGRect(x: hit.x - 3.2, y: hit.y - 3.2, width: 6.4, height: 6.4))
            context.fill(mark, with: .color(StagePalette.hitFill))
            context.stroke(mark, with: .color(StagePalette.hitLine), lineWidth: 1)
        }
    }

    private func coverageColor(onAxis: Double, near: Double) -> Color {
        let loud = max(0, min(1, onAxis * near))
        let red = (32 + 208 * loud) / 255
        let blue = (32 + 208 * (1 - loud)) / 255
        let green = (36 * (1 - abs(loud - 0.5) * 2)) / 255
        let alpha = 0.28 + 0.48 * loud
        return Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    private func roomExit(origin: StagePoint, direction: StagePoint) -> Double {
        let halfW = StageRoom.width * 0.5
        let slabs: [(Double, Double, Double, Double)] = [
            (origin.x, direction.x, -halfW, halfW),
            (origin.y, direction.y, 0, StageRoom.length),
            (origin.z, direction.z, 0, StageRoom.height),
        ]
        var exit = Double.infinity
        for slab in slabs {
            let dir = slab.1
            if abs(dir) < 1e-8 {
                if slab.0 < slab.2 - 1e-4 || slab.0 > slab.3 + 1e-4 { return 0 }
                continue
            }
            var near = (slab.2 - slab.0) / dir
            var far = (slab.3 - slab.0) / dir
            if near > far { swap(&near, &far) }
            if far < exit { exit = far }
        }
        if !exit.isFinite || exit < 0 { return 0 }
        let limit = hypot(StageRoom.width, hypot(StageRoom.length, StageRoom.height))
        return min(exit, limit)
    }

    private func project(_ point: StagePoint, size: CGSize) -> CGPoint {
        let cx = 0.0
        let cy = StageRoom.length * 0.5
        let cz = StageRoom.height * 0.45
        let rx = point.x - cx
        let ry = point.y - cy
        let rz = point.z - cz
        let cosY = cos(camera.yaw)
        let sinY = sin(camera.yaw)
        let x1 = rx * cosY - ry * sinY
        let y1 = rx * sinY + ry * cosY
        let cosP = cos(camera.pitch)
        let sinP = sin(camera.pitch)
        let y2 = y1 * cosP - rz * sinP
        let z2 = y1 * sinP + rz * cosP
        let maxSpan = max(StageRoom.width, max(StageRoom.length, StageRoom.height))
        let fov = Double(min(size.width, size.height)) * 0.95 * camera.zoom
        let depth = max(2, maxSpan * 1.65 + y2)
        let sx = Double(size.width) * 0.5 + (x1 * fov) / depth
        let sy = Double(size.height) * 0.54 - (z2 * fov) / depth
        return CGPoint(x: sx, y: sy)
    }

    private func pick(_ location: CGPoint, in size: CGSize) -> UUID? {
        var best: UUID?
        var bestDistance = 18.0
        for device in studio.profile.devices {
            let spot = studio.stageSpot(for: device.id)
            let top = project(StagePoint(x: spot.x, y: spot.y, z: spot.z), size: size)
            let distance = hypot(top.x - location.x, top.y - location.y)
            if distance < bestDistance {
                bestDistance = distance
                best = device.id
            }
        }
        return best
    }

    /// 점은 그리지 않습니다. 고프로, 짐벌, 오즈모가 서로 다른 모양입니다. 렌즈가 제자리 방향을 봅니다.
    private func paintGlyph(
        context: GraphicsContext,
        device: DeviceRecord,
        at top: CGPoint,
        aim: CGPoint,
        chosen: Bool,
        recording: Bool
    ) {
        let angle = atan2(aim.y - top.y, aim.x - top.x)
        var mark = context
        mark.translateBy(x: top.x, y: top.y)
        mark.rotate(by: .radians(angle))
        let scale: CGFloat = chosen ? 1.25 : 1
        mark.scaleBy(x: scale, y: scale)
        let line = recording ? StagePalette.oxblood : StagePalette.ink
        switch device.kind {
        case .gopro:
            paintGoPro(mark, line: line)
        case .ronin:
            paintGimbal(mark, line: line)
        case .goproBridge:
            paintBridge(mark, line: line)
        case .goproAction5, .osmoAction, .osmoNoAPI:
            paintOsmo(mark, line: line, round: device.osmoModel == .osmo360)
        }
    }

    private func paintBridge(_ mark: GraphicsContext, line: Color) {
        let body = Path(roundedRect: CGRect(x: -16, y: -10, width: 28, height: 20), cornerRadius: 2)
        mark.fill(body, with: .color(StagePalette.oxblood.opacity(0.85)))
        mark.stroke(body, with: .color(line), lineWidth: 1.6)
        for index in 0..<4 {
            let dot = Path(ellipseIn: CGRect(x: CGFloat(-10 + index * 6), y: -3, width: 4, height: 4))
            mark.fill(dot, with: .color(StagePalette.paper))
        }
    }

    private func paintGoPro(_ mark: GraphicsContext, line: Color) {
        let body = Path(roundedRect: CGRect(x: -20, y: -8, width: 30, height: 16), cornerRadius: 3)
        mark.fill(body, with: .color(StagePalette.oxblood.opacity(0.9)))
        mark.stroke(body, with: .color(line), lineWidth: 1.6)
        let lens = Path(ellipseIn: CGRect(x: 8, y: -5.5, width: 11, height: 11))
        mark.fill(lens, with: .color(StagePalette.ink))
        mark.stroke(lens, with: .color(StagePalette.paper), lineWidth: 1)
        let glass = Path(ellipseIn: CGRect(x: 11, y: -2.5, width: 4, height: 4))
        mark.fill(glass, with: .color(StagePalette.paper))
    }

    private func paintGimbal(_ mark: GraphicsContext, line: Color) {
        var yoke = Path()
        yoke.addArc(center: .zero, radius: 13, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
        mark.stroke(yoke, with: .color(line), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        let arm = Path(roundedRect: CGRect(x: -1.4, y: 8, width: 2.8, height: 12), cornerRadius: 1)
        mark.fill(arm, with: .color(line))
        let camera = Path(roundedRect: CGRect(x: -7, y: -5, width: 16, height: 10), cornerRadius: 1.5)
        mark.fill(camera, with: .color(StagePalette.oxblood))
        mark.stroke(camera, with: .color(line), lineWidth: 1.2)
        let lens = Path(ellipseIn: CGRect(x: 7, y: -3.5, width: 7, height: 7))
        mark.fill(lens, with: .color(StagePalette.ink))
        mark.stroke(lens, with: .color(StagePalette.paper), lineWidth: 0.8)
    }

    private func paintOsmo(_ mark: GraphicsContext, line: Color, round: Bool) {
        if round {
            let ball = Path(ellipseIn: CGRect(x: -11, y: -11, width: 22, height: 22))
            mark.fill(ball, with: .color(StagePalette.oxblood.opacity(0.9)))
            mark.stroke(ball, with: .color(line), lineWidth: 1.6)
            let front = Path(ellipseIn: CGRect(x: 4, y: -4, width: 8, height: 8))
            let back = Path(ellipseIn: CGRect(x: -12, y: -4, width: 8, height: 8))
            mark.fill(front, with: .color(StagePalette.ink))
            mark.fill(back, with: .color(StagePalette.ink))
            return
        }
        let body = Path(roundedRect: CGRect(x: -9, y: -14, width: 18, height: 26), cornerRadius: 4)
        mark.fill(body, with: .color(StagePalette.oxblood.opacity(0.9)))
        mark.stroke(body, with: .color(line), lineWidth: 1.6)
        let lens = Path(ellipseIn: CGRect(x: 5, y: -5, width: 10, height: 10))
        mark.fill(lens, with: .color(StagePalette.ink))
        mark.stroke(lens, with: .color(StagePalette.paper), lineWidth: 1)
        let screen = Path(roundedRect: CGRect(x: -7, y: -10, width: 8, height: 12), cornerRadius: 1)
        mark.stroke(screen, with: .color(StagePalette.paper), lineWidth: 1)
    }

    /// 장치가 실제로 알려 준 녹화만 적습니다. 없는 상태는 대기라고 꾸미지 않습니다.
    private func recordMark(_ device: DeviceRecord) -> String? {
        switch device.kind {
        case .ronin:
            let live = studio.roninLive[device.id]
            if live?.sonyRecording == true { return "녹화" }
            if live?.camRecording == true { return "녹화 명령" }
            return nil
        case .gopro, .goproAction5:
            return studio.goproLive[device.id]?.encoding == true ? "녹화" : nil
        case .goproBridge:
            return nil
        case .osmoAction:
            guard let status = studio.radio.live[device.id]?.status else { return nil }
            if status == 3 || status == 5 { return OsmoCatalog.statusName(status) }
            return nil
        case .osmoNoAPI:
            return nil
        }
    }
}
