import SwiftUI

/// 왼쪽 메뉴 세 칸입니다. PTZ · 고정캠 · 로닌.
enum StudioSideTab: String, CaseIterable, Identifiable {
    case ptz
    case fixedCam
    case ronin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ptz: return "PTZ"
        case .fixedCam: return "고정캠"
        case .ronin: return "로닌"
        }
    }
}

/// 기기 줄: 썸네일 이미지 + 이름 + 세부 상태 + 온라인/오프라인.
struct DeviceThumbCard: View {
    var title: String
    var subtitle: String
    var detail: String
    var symbol: String
    /// nil 이면 온라인 줄을 숨깁니다(등록 전 안내 등).
    var online: Bool?
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 58, height: 58)
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(Color.white.opacity(0.92))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.93, green: 0.94, blue: 0.95))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.78))
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let online {
                        Text(online ? "온라인" : "오프라인")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(online
                                             ? Color(red: 0.55, green: 0.85, blue: 0.55)
                                             : Color.white.opacity(0.5))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(DeskButtonStyle(selected: selected, expand: true))
    }
}

/// 왼쪽 탭 버튼 줄입니다.
struct StudioTabBar: View {
    @Binding var tab: StudioSideTab

    var body: some View {
        HStack(spacing: 6) {
            ForEach(StudioSideTab.allCases) { item in
                Button(item.title) { tab = item }
                    .buttonStyle(DeskButtonStyle(selected: tab == item, expand: true))
            }
        }
    }
}
