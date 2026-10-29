import Foundation

// Open GoPro 파이썬 SDK에 공개된 설정 번호와 선택값만 넣었습니다.
// 카메라가 조합을 거절하면 화면의 응답 글이 그 사실을 보여 줍니다.
// 옵션 표를 확인하지 못한 항목(LED, 화면 밝기 등)은 일부러 빼 두었습니다.

struct GoProOption: Identifiable, Hashable, Sendable {
    var value: Int
    var label: String
    var id: Int { value }
}

struct GoProSettingSpec: Identifiable, Sendable {
    var id: Int
    var title: String
    var note: String
    var options: [GoProOption]
}

enum GoProCatalog {
    static let settings: [GoProSettingSpec] = [
        GoProSettingSpec(
            id: 2,
            title: "영상 해상도",
            note: "설정 번호 2. 기종과 모드에 따라 거절될 수 있습니다.",
            options: [
                GoProOption(value: 1, label: "4K"),
                GoProOption(value: 9, label: "1080p"),
                GoProOption(value: 4, label: "2.7K"),
                GoProOption(value: 12, label: "720p"),
                GoProOption(value: 7, label: "1440"),
                GoProOption(value: 18, label: "4K 4:3"),
                GoProOption(value: 24, label: "5K"),
                GoProOption(value: 25, label: "5K 4:3"),
                GoProOption(value: 100, label: "5.3K"),
                GoProOption(value: 27, label: "5.3K 4:3"),
                GoProOption(value: 31, label: "8K"),
                GoProOption(value: 6, label: "2.7K 4:3"),
                GoProOption(value: 37, label: "4K 1:1"),
                GoProOption(value: 36, label: "4K 21:9"),
                GoProOption(value: 109, label: "4K 9:16"),
                GoProOption(value: 110, label: "1080 9:16"),
            ]
        ),
        GoProSettingSpec(
            id: 3,
            title: "초당 프레임",
            note: "설정 번호 3. 일부 새 기종은 234번을 쓰지만, 그 선택값 표는 여기에 넣지 않았습니다.",
            options: [
                GoProOption(value: 10, label: "24"),
                GoProOption(value: 9, label: "25"),
                GoProOption(value: 8, label: "30"),
                GoProOption(value: 6, label: "50"),
                GoProOption(value: 5, label: "60"),
                GoProOption(value: 2, label: "100"),
                GoProOption(value: 1, label: "120"),
                GoProOption(value: 13, label: "200"),
                GoProOption(value: 0, label: "240"),
                GoProOption(value: 3, label: "90"),
                GoProOption(value: 17, label: "300"),
                GoProOption(value: 16, label: "360"),
                GoProOption(value: 15, label: "400"),
            ]
        ),
        GoProSettingSpec(
            id: 121,
            title: "영상 렌즈",
            note: "설정 번호 121.",
            options: [
                GoProOption(value: 0, label: "와이드"),
                GoProOption(value: 2, label: "내로우"),
                GoProOption(value: 3, label: "슈퍼뷰"),
                GoProOption(value: 4, label: "리니어"),
                GoProOption(value: 7, label: "맥스 슈퍼뷰"),
                GoProOption(value: 8, label: "리니어 + 수평"),
                GoProOption(value: 9, label: "하이퍼뷰"),
                GoProOption(value: 10, label: "리니어 호라이즌 락"),
                GoProOption(value: 11, label: "맥스 하이퍼뷰"),
                GoProOption(value: 12, label: "울트라 슈퍼뷰"),
                GoProOption(value: 13, label: "울트라 와이드"),
                GoProOption(value: 14, label: "울트라 리니어"),
                GoProOption(value: 104, label: "울트라 하이퍼뷰"),
            ]
        ),
        GoProSettingSpec(
            id: 135,
            title: "하이퍼스무스",
            note: "설정 번호 135.",
            options: [
                GoProOption(value: 0, label: "끄기"),
                GoProOption(value: 1, label: "낮음"),
                GoProOption(value: 2, label: "높음"),
                GoProOption(value: 3, label: "부스트"),
                GoProOption(value: 4, label: "자동 부스트"),
                GoProOption(value: 100, label: "스탠다드"),
            ]
        ),
        GoProSettingSpec(
            id: 108,
            title: "영상 화면비",
            note: "설정 번호 108.",
            options: [
                GoProOption(value: 0, label: "4:3"),
                GoProOption(value: 1, label: "16:9"),
                GoProOption(value: 3, label: "8:7"),
                GoProOption(value: 4, label: "9:16"),
                GoProOption(value: 5, label: "21:9"),
                GoProOption(value: 6, label: "1:1"),
            ]
        ),
        GoProSettingSpec(
            id: 182,
            title: "영상 비트레이트",
            note: "설정 번호 182.",
            options: [
                GoProOption(value: 0, label: "스탠다드"),
                GoProOption(value: 1, label: "높음"),
                GoProOption(value: 2, label: "최대"),
            ]
        ),
        GoProSettingSpec(
            id: 150,
            title: "영상 수평 유지",
            note: "설정 번호 150.",
            options: [
                GoProOption(value: 0, label: "끄기"),
                GoProOption(value: 2, label: "잠금"),
            ]
        ),
        GoProSettingSpec(
            id: 173,
            title: "영상 성능 모드",
            note: "설정 번호 173.",
            options: [
                GoProOption(value: 0, label: "최대 성능"),
                GoProOption(value: 1, label: "배터리 연장"),
                GoProOption(value: 2, label: "삼각대·고정"),
            ]
        ),
        GoProSettingSpec(
            id: 184,
            title: "색 프로파일",
            note: "설정 번호 184.",
            options: [
                GoProOption(value: 0, label: "스탠다드"),
                GoProOption(value: 1, label: "HDR"),
                GoProOption(value: 2, label: "로그"),
                GoProOption(value: 101, label: "HLG HDR"),
            ]
        ),
        GoProSettingSpec(
            id: 83,
            title: "GPS",
            note: "설정 번호 83.",
            options: [
                GoProOption(value: 0, label: "끄기"),
                GoProOption(value: 1, label: "켜기"),
            ]
        ),
        GoProSettingSpec(
            id: 167,
            title: "하인드사이트",
            note: "설정 번호 167. 녹화 직전 장면을 붙입니다.",
            options: [
                GoProOption(value: 4, label: "끄기"),
                GoProOption(value: 2, label: "15초"),
                GoProOption(value: 3, label: "30초"),
            ]
        ),
        GoProSettingSpec(
            id: 175,
            title: "컨트롤 모드",
            note: "설정 번호 175. 이지 또는 프로입니다.",
            options: [
                GoProOption(value: 0, label: "이지"),
                GoProOption(value: 1, label: "프로"),
            ]
        ),
        GoProSettingSpec(
            id: 194,
            title: "렌즈 구성",
            note: "설정 번호 194. 사진/영상 전환이 아닙니다. 한 렌즈와 360만 문서에 있습니다.",
            options: [
                GoProOption(value: 0, label: "한 렌즈"),
                GoProOption(value: 1, label: "360"),
            ]
        ),
    ]

    static func spec(_ id: Int) -> GoProSettingSpec? {
        settings.first { $0.id == id }
    }

    static func freshLook() -> GoProLook {
        GoProLook(
            settings: settings.map {
                GoProSettingChoice(settingId: $0.id, option: $0.options[0].value, enabled: false)
            },
            loadPresetId: nil,
            digitalZoomPercent: nil
        )
    }

    static func merged(_ look: GoProLook) -> GoProLook {
        var copy = look
        for spec in settings where !copy.settings.contains(where: { $0.settingId == spec.id }) {
            copy.settings.append(GoProSettingChoice(settingId: spec.id, option: spec.options[0].value, enabled: false))
        }
        return copy
    }
}
