import SwiftUI

/// 눌림과 선택이 바로 보이게 하는 버튼입니다. 어두운 화면에서 기본 버튼은 반응이 없어 보입니다.
struct DeskButtonStyle: ButtonStyle {
    var selected = false
    var tone: DeskTone = .normal
    var expand = false
    @Environment(\.isEnabled) private var enabled

    enum DeskTone {
        case normal
        case record
        case stop
    }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(.caption.weight(selected || pressed ? .bold : .semibold))
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: expand ? .infinity : nil, alignment: .leading)
            .foregroundStyle(ink(pressed))
            .background(fill(pressed), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(line(pressed), lineWidth: pressed || selected ? 2.5 : 1))
            .scaleEffect(pressed ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.35)
            .animation(.easeOut(duration: 0.08), value: pressed)
    }

    private func fill(_ pressed: Bool) -> Color {
        if pressed {
            switch tone {
            case .record: return Color(red: 0.86, green: 0.22, blue: 0.22)
            case .stop: return Color.white.opacity(0.28)
            case .normal: return Color(red: 0.72, green: 0.58, blue: 0.28)
            }
        }
        if selected { return Color(red: 0.36, green: 0.28, blue: 0.12) }
        return Color.white.opacity(0.06)
    }

    private func line(_ pressed: Bool) -> Color {
        if pressed || selected { return Color(red: 0.93, green: 0.78, blue: 0.42) }
        switch tone {
        case .record: return Color(red: 0.86, green: 0.28, blue: 0.28)
        case .stop, .normal: return Color.white.opacity(0.45)
        }
    }

    private func ink(_ pressed: Bool) -> Color {
        pressed ? .white : Color(red: 0.93, green: 0.94, blue: 0.95)
    }
}
