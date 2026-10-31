import SwiftUI

/// 오른쪽 칸의 맨 위입니다. 고른 장치의 제품 사진과 녹화·출력 상태를 둡니다.
struct GearHeader: View {
    @EnvironmentObject private var studio: Studio
    var device: DeviceRecord
    var camera: BridgeCameraSlot?

    private var face: ProductFace {
        if camera == nil, device.kind == .gopro,
           let read = ProductFace.from(modelName: studio.goproLive[device.id]?.modelName ?? "") {
            return read
        }
        return ProductFace.inferred(device: device, camera: camera)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if camera == nil, device.kind == .goproBridge {
                Text("왼쪽에서 카메라를 고르면 그 기종 사진이 여기에 나옵니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                photo
                Text(face.title)
                    .font(.caption.weight(.semibold))
                Text(recordLine)
                Text(hdmiLine)
                Text(usbLine)
            }
        }
        .font(.caption2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var photo: some View {
        if let asset = face.assetName {
            Image(asset)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 150)
                .background(StagePalette.paper)
        } else {
            Text("\(face.title) 사진 없음")
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                .background(StagePalette.paper)
        }
    }

    private var recordLine: String {
        switch recordState {
        case true: return "녹화"
        case false: return "대기"
        case nil: return "녹화 아직 모름"
        }
    }

    private var hdmiLine: String {
        switch hdmiOut {
        case true: return "HDMI 출력"
        case false: return "HDMI 아님"
        case nil: return "HDMI 아직 모름"
        }
    }

    private var usbLine: String {
        switch usbOut {
        case true: return "USB 출력"
        case false: return "USB 아님"
        case nil: return "USB 아직 모름"
        }
    }

    /// 장치가 알려 준 녹화입니다. 명령을 보낸 기억만으로 녹화라고 하지 않습니다.
    private var recordState: Bool? {
        switch device.kind {
        case .ronin:
            return studio.roninLive[device.id]?.sonyRecording
        case .gopro, .goproAction5:
            return studio.goproLive[device.id]?.encoding
        case .osmoAction:
            guard let status = studio.radio.live[device.id]?.status else { return nil }
            if status == 3 || status == 5 { return true }
            if status == 1 { return false }
            return nil
        case .goproBridge, .osmoNoAPI:
            return nil
        }
    }

    private var hdmiOut: Bool? {
        switch device.kind {
        case .gopro, .goproAction5:
            return studio.goproLive[device.id]?.hdmiOut
        default:
            return nil
        }
    }

    private var usbOut: Bool? {
        switch device.kind {
        case .gopro, .goproAction5:
            return studio.goproLive[device.id]?.usbOut
        default:
            return nil
        }
    }
}
