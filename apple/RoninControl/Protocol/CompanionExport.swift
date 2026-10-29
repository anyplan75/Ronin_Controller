import Foundation

enum CompanionExport {
    static func page(profile: StudioProfile) throws -> (Data, String) {
        let httpDevices = profile.devices.filter { $0.enabled && $0.kind.usesHTTP && !$0.baseURLText.isEmpty }
        var instances: [String: Any] = [:]
        var labels: [UUID: String] = [:]
        for (index, device) in httpDevices.enumerated() {
            let id = "roninhttp\(index + 1)"
            let label: String
            switch device.kind {
            case .gopro: label = "gopro\(index + 1)"
            case .goproAction5: label = "action5\(index + 1)"
            default: label = "ronin\(index + 1)"
            }
            labels[device.id] = id
            instances[id] = [
                "label": label,
                "config": [
                    "prefix": device.baseURLText,
                    "proxyAddress": "",
                    "authType": "none",
                    "authUser": "",
                    "rejectUnauthorized": true,
                    "insecureHTTPParser": false,
                ],
                "isFirstInit": false,
                "lastUpgradeIndex": 4,
                "moduleId": "generic-http",
                "enabled": true,
                "sortOrder": index,
            ] as [String: Any]
        }

        var controls: [String: [String: Any]] = [:]
        var cursor = 0
        func place(_ title: String, _ color: Int, _ actions: [[String: Any]]) {
            let row = cursor / 8
            let column = cursor % 8
            let rowKey = String(row)
            var line = controls[rowKey] ?? [:]
            line[String(column)] = button(title: title, color: color, actions: actions)
            controls[rowKey] = line
            cursor += 1
        }

        let lead = min(10000, max(0, profile.leadMs))
        place("함께 시작", 0x8C1D18, groupActions(profile, labels: labels, start: true, lead: lead))
        place("함께 정지", 0x1F3A5F, groupActions(profile, labels: labels, start: false, lead: lead))

        for preset in profile.presets {
            place(preset.name, 0x2E5339, presetActions(preset, profile: profile, labels: labels))
        }

        let page: [String: Any] = [
            "version": 12,
            "type": "page",
            "companionBuild": "ronin-control-1",
            "page": [
                "id": UUID().uuidString,
                "name": "로닌 컨트롤",
                "controls": controls,
                "gridSize": [
                    "minColumn": 0,
                    "maxColumn": 7,
                    "minRow": 0,
                    "maxRow": max(3, (cursor / 8) + 1),
                ],
            ] as [String: Any],
            "instances": instances,
            "connectionCollections": [],
            "oldPageNumber": 1,
            "imageLibrary": [],
            "imageLibraryCollections": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: page, options: [.prettyPrinted, .sortedKeys])
        let note = """
        컴패니언에서 페이지 가져오기를 하세요. 파일 형식 버전은 12이고, 연결은 generic-http 입니다.
        버튼 주소는 지금 프로필에 저장된 직접 주소입니다.
        함께 시작 버튼은 기판에 /sync/record?delay_ms=\(lead) 를 순서대로 보냅니다. 기판은 요청을 받은 뒤부터 셉니다.
        애플 앱의 함께 시작은 /sync/clock 으로 기판 시계를 읽어 at_ms 를 맞춥니다. 그게 더 정확합니다.
        고프로 · 와이파이 버튼은 카메라 주소(보통 10.5.5.9:8080)입니다.
        오즈모 액션 5 프로 · 블루투스 버튼은 C3 중계 기판 주소입니다. 로닌 기판 주소가 아니고, 고프로도 아닙니다.
        오즈모 블루투스는 컴패니언 HTTP 버튼으로 보낼 수 없어 페이지에 넣지 않았습니다.
        """
        return (data, note)
    }

    private static func groupActions(
        _ profile: StudioProfile,
        labels: [UUID: String],
        start: Bool,
        lead: Int
    ) -> [[String: Any]] {
        var actions: [[String: Any]] = []
        for device in profile.devices where device.enabled && labels[device.id] != nil {
            guard let connection = labels[device.id] else { continue }
            if device.kind == .ronin {
                let url = "\(device.baseURLText)/sync/record?action=\(start ? "start" : "stop")&delay_ms=\(lead)"
                actions.append(httpGet(connection, url))
            } else if device.kind.isGoProFamily {
                let url = "\(device.baseURLText)/gopro/camera/shutter/\(start ? "start" : "stop")"
                actions.append(httpGet(connection, url))
            }
        }
        return actions
    }

    private static func presetActions(
        _ preset: ShootPreset,
        profile: StudioProfile,
        labels: [UUID: String]
    ) -> [[String: Any]] {
        var actions: [[String: Any]] = []
        for device in profile.targets(for: preset) {
            guard let connection = labels[device.id] else { continue }
            switch device.kind {
            case .ronin:
                if !preset.ronin.shot.isEmpty {
                    let scale = String(format: "%.2f", min(4, max(0.25, preset.ronin.timeScale)))
                    actions.append(httpGet(connection, "\(device.baseURLText)/shot/\(preset.ronin.shot)?t=\(scale)"))
                }
                if preset.ronin.sendMove {
                    let path = preset.ronin.absolute ? "move" : "relative"
                    let query = String(
                        format: "yaw=%.1f&roll=%.1f&pitch=%.1f&time=%.1f",
                        preset.ronin.yaw, preset.ronin.roll, preset.ronin.pitch, preset.ronin.seconds
                    )
                    actions.append(httpGet(connection, "\(device.baseURLText)/\(path)?\(query)"))
                }
            case .gopro, .goproAction5:
                for choice in preset.gopro.settings where choice.enabled {
                    let url = "\(device.baseURLText)/gopro/camera/setting?setting=\(choice.settingId)&option=\(choice.option)"
                    actions.append(httpGet(connection, url))
                }
                if device.kind == .gopro {
                    if let id = preset.gopro.loadPresetId {
                        actions.append(httpGet(connection, "\(device.baseURLText)/gopro/camera/presets/load?id=\(id)"))
                    }
                    if let zoom = preset.gopro.digitalZoomPercent {
                        actions.append(httpGet(connection, "\(device.baseURLText)/gopro/camera/digital_zoom?percent=\(zoom)"))
                    }
                }
            case .osmoAction, .osmoNoAPI:
                break
            }
        }
        return actions
    }

    private static func httpGet(_ connectionId: String, _ url: String) -> [String: Any] {
        [
            "type": "action",
            "id": UUID().uuidString,
            "definitionId": "get",
            "connectionId": connectionId,
            "upgradeIndex": 0,
            "options": [
                "url": ["isExpression": false, "value": url],
                "header": ["isExpression": false, "value": ""],
                "jsonResultDataVariable": ["isExpression": false, "value": ""],
                "result_stringify": ["isExpression": false, "value": true],
                "statusCodeVariable": ["isExpression": false, "value": ""],
            ],
        ]
    }

    private static func button(title: String, color: Int, actions: [[String: Any]]) -> [String: Any] {
        let step = UUID().uuidString
        return [
            "type": "button",
            "style": [
                "text": title,
                "textExpression": false,
                "size": "14",
                "png64": NSNull(),
                "alignment": "center:center",
                "pngalignment": "center:center",
                "color": 0xFFFFFF,
                "bgcolor": color,
                "show_topbar": "default",
            ] as [String: Any],
            "options": [
                "stepAutoProgress": true,
                "rotaryActions": false,
            ],
            "feedbacks": [],
            "localVariables": [],
            "steps": [
                step: [
                    "action_sets": [
                        "down": actions,
                        "up": [],
                    ],
                    "options": ["runWhileHeld": []],
                ] as [String: Any],
            ],
        ]
    }
}
