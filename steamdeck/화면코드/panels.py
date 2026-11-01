"""오른쪽 칸의 상태, 설정, 프리셋, 장치 추가 줄입니다. 휠은 만들지 않습니다."""

from __future__ import annotations

from dataclasses import dataclass

from 화면코드.model import (
    GOPRO_SETTINGS,
    KIND_ACTION5,
    KIND_GOPRO,
    KIND_NOAPI,
    KIND_OSMO,
    KIND_RONIN,
    PRODUCTS,
    gopro_option_label,
    is_gopro_family,
    mode_name,
    osmo_models_for,
    osmo_status_name,
    resolution_name,
    fps_name,
    shot_title,
    uses_http,
    writable_modes,
)


@dataclass
class Row:
    id: str
    label: str
    value: str = ""
    y_label: str = ""
    on_y: object = None
    on_x: object = None
    text_key: str = ""


def status_lines(app) -> list[str]:
    device = app.studio.selected()
    if not device:
        return ["무대에서 장치를 고르면 상태와 설정이 여기에 나옵니다."]
    lines = [device.name, device.label()]
    if device.base_url():
        lines.append(device.base_url())
    elif uses_http(device.kind):
        lines.append("주소가 비어 있습니다.")
    if device.kind == KIND_RONIN:
        live = app.studio.ronin_live.get(device.id)
        if not live:
            lines.append("아직 상태를 읽지 못했습니다.")
        else:
            lines.append(f"랜 {'연결' if live.get('eth_link') else '끊김'}  CAN {live.get('twai') or '-'}")
            lines.append(
                f"요 {float(live.get('yaw') or 0):.1f}  롤 {float(live.get('roll') or 0):.1f}  피치 {float(live.get('pitch') or 0):.1f}"
            )
            lines.append("자세 " + ("유효" if live.get("attitude_valid") else "없음"))
            lines.append("녹화 명령 " + ("시작" if live.get("cam_recording") else "정지"))
            lines.append("소니 녹화 " + ("켜짐" if live.get("sony_recording") else "꺼짐"))
        lines.append("왼쪽 스틱이 이 로닌의 팬·틸트를 움직입니다. 놓으면 정지합니다.")
    elif is_gopro_family(device.kind):
        lines.append(app.studio.gopro_session.get(device.id) or "세션을 아직 확인하지 않았습니다.")
        live = app.studio.gopro_live.get(device.id)
        if live:
            if device.kind == KIND_GOPRO:
                lines.append(f"녹화 중 {'예' if live.get('encoding') else '아니오'}  바쁨 {'예' if live.get('busy') else '아니오'}")
                lines.append(f"남은 영상 {live.get('remaining_video') if live.get('remaining_video') is not None else '-'}  남은 사진 {live.get('remaining_photos') if live.get('remaining_photos') is not None else '-'}")
            if device.kind == KIND_ACTION5 and live.get("relay_ble"):
                lines.append(str(live["relay_ble"]))
            if live.get("error"):
                lines.append(str(live["error"]))
        if device.kind == KIND_ACTION5:
            lines.append("오즈모 액션 5 프로는 C3 중계 주소로만 붙습니다. 실시간 그림은 없습니다.")
        else:
            lines.append("이 고프로는 짐벌이 아닙니다. 스틱은 누르는 동안 화살표만 기울입니다.")
    elif device.kind == KIND_OSMO:
        live = app.studio.radio.snapshot(device.id)
        lines.append(live.get("phase") or "아직 상태가 없습니다.")
        if live.get("mode") is not None:
            lines.append("모드 " + mode_name(int(live["mode"])))
        if live.get("status") is not None:
            lines.append("상태 " + osmo_status_name(int(live["status"])))
        if live.get("resolution") is not None:
            lines.append(f"해상도 {resolution_name(int(live['resolution']))}  프레임 {fps_name(int(live.get('fps') or 0))}")
        if live.get("battery") is not None:
            lines.append(f"배터리 {live['battery']}")
        if live.get("last_error"):
            lines.append(str(live["last_error"]))
        lines.append("오즈모 액션·360은 블루투스입니다. 스틱은 그림의 방향만 바꿉니다.")
    else:
        lines.append("오즈모 포켓·모바일·나노는 제어 API가 없습니다.")
    x, y = app.stick
    lines.append(f"스틱 좌우 {x:+.2f}  상하 {-y:+.2f}")
    return lines


def build_rows(app) -> list[Row]:
    if app.tab == "status":
        return _status(app)
    if app.tab == "settings":
        return _settings(app)
    if app.tab == "presets":
        return _presets(app)
    return _add(app)


def _status(app) -> list[Row]:
    studio = app.studio
    return [
        Row("refresh", "상태", "다시 읽기", "다시 읽기", studio.refresh),
        Row(
            "lead",
            "함께 여유",
            f"{studio.profile.lead_ms} ms",
            "",
            None,
            lambda delta: _bump_lead(studio, delta),
        ),
    ]


def _bump_lead(studio, delta: int) -> None:
    studio.profile.lead_ms = min(10000, max(0, studio.profile.lead_ms + delta * 50))
    studio.save()


def _settings(app) -> list[Row]:
    device = app.studio.selected()
    if not device:
        return [Row("none", "장치 없음", "X 또는 R1 로 고르세요")]
    rows = [
        Row("name", "이름", device.name, "이름 고치기", None, None, "name"),
        Row("enabled", "사용", "예" if device.enabled else "아니오", "", None, lambda delta: _toggle(app, "enabled")),
        Row("group", "함께 촬영", "예" if device.id in app.studio.profile.group_ids else "아니오", "", None, lambda delta: _toggle_group(app)),
    ]
    if device.kind != KIND_NOAPI:
        rows.append(Row("product", "종류", device.label(), "", None, lambda delta: _cycle_product(app, delta)))
    if uses_http(device.kind):
        rows.append(Row("host", "주소", device.host or "비어 있음", "주소 고치기", None, None, "host"))
        rows.append(Row("port", "포트", str(device.port), "", None, lambda delta: _bump_port(app, delta)))
    if device.kind == KIND_RONIN:
        rows.extend(_ronin_rows(app, device))
    elif is_gopro_family(device.kind):
        rows.extend(_gopro_rows(app, device))
    elif device.kind == KIND_OSMO:
        rows.extend(_osmo_rows(app, device))
    armed = app.arm_delete == device.id
    rows.append(Row(
        "delete",
        "이 장치 지우기",
        "한 번 더" if armed else "",
        "정말 지우기" if armed else "지우기",
        lambda: _delete(app, device.id),
    ))
    return rows


def _ronin_rows(app, device) -> list[Row]:
    studio = app.studio
    spot = studio.spot(device.id)
    rows = [
        Row("home-yaw", "제자리 요", f"{spot.home_yaw:.0f}°", "", None, lambda delta: studio.move_stage(device.id, home_yaw=spot.home_yaw + delta * 5)),
        Row("home-pitch", "제자리 피치", f"{spot.home_pitch:.0f}°", "", None, lambda delta: studio.move_stage(device.id, home_pitch=spot.home_pitch + delta * 5)),
        Row("aim", "무대 방향", f"{spot.aim_yaw:.0f}°", "", None, lambda delta: studio.move_stage(device.id, aim=spot.aim_yaw + delta * 5)),
        Row("go-home", "제자리로 이동", "", "제자리", studio.home),
        Row("remember", "지금 각도를 제자리로", "", "기억", studio.remember_home),
        Row("front", "기판 자세", "정면", "정면", lambda: studio._ronin(device, "/preset/front", {})),
        Row("down", "기판 자세", "아래", "아래", lambda: studio._ronin(device, "/preset/down", {})),
        Row("up", "기판 자세", "위", "위", lambda: studio._ronin(device, "/preset/up", {})),
        Row("center", "기판 자세", "중앙", "중앙", lambda: studio._ronin(device, "/recenter", {})),
    ]
    for name in studio.shot_names:
        rows.append(Row(f"shot-{name}", "기판 샷", shot_title(name), "이 샷", lambda name=name: studio.ronin_shot(name)))
    for preset in studio.profile.presets:
        rows.append(Row(f"look-{preset.id}", "이 로닌에 프리셋", preset.name, "적용", lambda preset=preset: studio.apply_ronin_look(preset)))
    rows.append(Row("sony-ssid", "소니 와이파이 이름", app.memory.get((device.id, "sony-ssid"), ""), "이름 고치기", None, None, "sony-ssid"))
    rows.append(Row("sony-pass", "소니 비밀번호", _mask(app.memory.get((device.id, "sony-pass"), "")), "비밀번호 고치기", None, None, "sony-pass"))
    rows.append(Row("sony-host", "소니 주소", app.memory.get((device.id, "sony-host"), "192.168.122.1"), "주소 고치기", None, None, "sony-host"))
    rows.append(Row("sony-save", "소니 연결", "기판에만 저장", "저장", lambda: studio.sony_connect(
        app.memory.get((device.id, "sony-ssid"), ""),
        app.memory.get((device.id, "sony-pass"), ""),
        app.memory.get((device.id, "sony-host"), "192.168.122.1"),
    )))
    return rows


def _gopro_rows(app, device) -> list[Row]:
    studio = app.studio
    rows = []
    live_settings = (studio.gopro_live.get(device.id) or {}).get("settings") or {}
    for spec in GOPRO_SETTINGS:
        setting_id, title, options = spec
        chosen = app.setting_choice.get((device.id, setting_id), options[0][0])
        camera = live_settings.get(setting_id)
        value = gopro_option_label(setting_id, chosen)
        if camera is not None:
            value = f"{value}  (카메라 {camera})"
        rows.append(Row(
            f"set-{setting_id}",
            title,
            value,
            "보내기",
            lambda setting_id=setting_id, title=title, device_id=device.id, fallback=chosen: studio.gopro_setting(
                setting_id, app.setting_choice.get((device_id, setting_id), fallback), title
            ),
            lambda delta, setting_id=setting_id, options=options, device_id=device.id: _cycle_option(app, device_id, setting_id, options, delta),
        ))
    if device.kind == KIND_GOPRO:
        rows.append(Row(
            "zoom",
            "디지털 줌",
            f"{app.zoom}%",
            "줌 보내기",
            lambda: studio.gopro_zoom(app.zoom),
            lambda delta: _bump_zoom(app, delta),
        ))
        rows.append(Row("preview", "실시간 그림", "고프로 와이파이", "열기", lambda: app.toggle_preview()))
    else:
        rows.append(Row("relay", "C3 블루투스", "다시 붙기", "다시 붙기", studio.relay_pair))
        rows.append(Row("relay-ssid", "집 와이파이 이름", app.memory.get((device.id, "relay-ssid"), ""), "이름 고치기", None, None, "relay-ssid"))
        rows.append(Row("relay-pass", "집 와이파이 비밀번호", _mask(app.memory.get((device.id, "relay-pass"), "")), "비밀번호 고치기", None, None, "relay-pass"))
        rows.append(Row("relay-save", "중계 기판에 저장", "비밀번호는 프로필에 없음", "저장", lambda: studio.relay_wifi(
            app.memory.get((device.id, "relay-ssid"), ""),
            app.memory.get((device.id, "relay-pass"), ""),
        )))
    return rows


def _osmo_rows(app, device) -> list[Row]:
    studio = app.studio
    rows = []
    models = osmo_models_for(device.kind, device.osmo_model)
    if len(models) > 1:
        rows.append(Row("model", "기종", device.osmo_model, "", None, lambda delta: _cycle_model(app, models, delta)))
    rows.append(Row("scan", "블루투스 찾기", studio.radio.note, "찾기", studio.osmo_scan))
    for seen in studio.radio.seen:
        rows.append(Row(
            "seen-" + seen["identifier"],
            seen["name"],
            seen["identifier"],
            "이 카메라",
            lambda seen=seen: _pick_osmo(app, device, seen["identifier"]),
        ))
    rows.append(Row("pair", "처음 연결", "카메라 숫자 확인", "연결", lambda: studio.osmo_pair(0 if device.paired_once else 1)))
    rows.append(Row("repair", "확인 없이 다시", "", "다시 연결", lambda: studio.osmo_pair(0)))
    modes = writable_modes(device.osmo_model)
    current = next((item[1] for item in modes if item[0] == app.osmo_mode), mode_name(app.osmo_mode))
    rows.append(Row(
        "mode",
        "모드",
        current,
        "모드 보내기",
        lambda: studio.osmo_mode(app.osmo_mode),
        lambda delta: _cycle_mode(app, modes, delta),
    ))
    return rows


def _presets(app) -> list[Row]:
    studio = app.studio
    presets = studio.profile.presets
    if not presets:
        return [Row("new", "프리셋 없음", "", "새 프리셋", studio.add_preset)]
    index = app.preset_index % len(presets)
    preset = presets[index]
    rows = [Row(
        "picker",
        "프리셋",
        preset.name,
        "적용",
        lambda: studio.apply_preset(preset),
        lambda delta: _cycle_preset(app, delta),
    )]
    rows.append(Row("pname", "이름", preset.name, "이름 고치기", None, None, "preset-name"))
    rows.append(Row("pnote", "메모", preset.note, "메모 고치기", None, None, "preset-note"))
    rows.append(Row(
        "pshot",
        "로닌 샷",
        shot_title(preset.ronin.get("shot") or "") if preset.ronin.get("shot") else "보내지 않음",
        "",
        None,
        lambda delta: _cycle_shot(app, preset, delta),
    ))
    rows.append(Row("pscale", "시간 배율", f"{float(preset.ronin.get('timeScale') or 1):.2f}", "", None, lambda delta: _bump_preset(studio, preset, "timeScale", delta, 0.25, 0.25, 4)))
    rows.append(Row("pmove", "이동도 보내기", "예" if preset.ronin.get("sendMove") else "아니오", "", None, lambda delta: _toggle_preset(studio, preset, "sendMove")))
    rows.append(Row("pabs", "절대 각도", "예" if preset.ronin.get("absolute", True) else "아니오", "", None, lambda delta: _toggle_preset(studio, preset, "absolute")))
    for key, label, step in (("yaw", "요", 5), ("roll", "롤", 5), ("pitch", "피치", 5), ("seconds", "초", 0.5)):
        rows.append(Row(f"p-{key}", label, str(preset.ronin.get(key) or 0), "", None, lambda delta, key=key, step=step: _bump_preset(studio, preset, key, delta, step, -180 if key != "seconds" else 0.2, 180 if key != "seconds" else 20)))
    mode = preset.osmo.get("mode")
    rows.append(Row("pmode", "오즈모 모드", "보내지 않음" if mode is None else mode_name(int(mode)), "", None, lambda delta: _cycle_preset_mode(studio, preset, delta)))
    rows.append(Row("save-addr", "지금 주소 저장", "", "저장", lambda: studio.remember_connections(preset)))
    rows.append(Row("load-addr", "주소 가져오기", "", "가져오기", lambda: studio.restore_connections(preset)))
    rows.append(Row("pdel", "이 프리셋 지우기", "", "지우기", lambda: _delete_preset(app, preset.id)))
    rows.append(Row("new", "새 프리셋", "", "만들기", studio.add_preset))
    return rows


def _add(app) -> list[Row]:
    rows = []
    for product in PRODUCTS:
        rows.append(Row(product[0], product[1], "", "추가", lambda product_id=product[0]: app.studio.add_device(product_id)))
    rows.append(Row("hint", "최대 8대", "제어 API 없는 기종은 없습니다", ""))
    return rows


def _toggle(app, field: str) -> None:
    device = app.studio.selected()
    if not device:
        return
    setattr(device, field, not getattr(device, field))
    app.studio.save()


def _toggle_group(app) -> None:
    device = app.studio.selected()
    if not device:
        return
    if device.id in app.studio.profile.group_ids:
        app.studio.profile.group_ids = [item for item in app.studio.profile.group_ids if item != device.id]
    else:
        app.studio.profile.group_ids.append(device.id)
    app.studio.save()


def _cycle_product(app, delta: int) -> None:
    device = app.studio.selected()
    if not device:
        return
    ids = [item[0] for item in PRODUCTS]
    current = _product_id(device)
    index = ids.index(current) if current in ids else 0
    product = PRODUCTS[(index + delta) % len(PRODUCTS)]
    device.kind = product[2]
    device.osmo_model = product[3]
    device.port = 80 if device.kind in (KIND_RONIN, KIND_ACTION5) else (8080 if device.kind == KIND_GOPRO else 0)
    if device.kind == KIND_GOPRO and not device.host:
        device.host = "10.5.5.9"
    if device.kind == KIND_ACTION5 and device.host == "10.5.5.9":
        device.host = ""
    app.studio.save()


def _product_id(device) -> str:
    if device.kind == KIND_RONIN:
        return "ronin"
    if device.kind == KIND_GOPRO:
        return "goproWifi"
    if device.kind == KIND_ACTION5:
        return "action5Bluetooth"
    if device.kind == KIND_OSMO and device.osmo_model == "osmo360":
        return "osmo360Bluetooth"
    if device.kind == KIND_OSMO:
        return "osmoActionBluetooth"
    return ""


def _bump_port(app, delta: int) -> None:
    device = app.studio.selected()
    if device:
        device.port = min(65535, max(1, device.port + delta))
        app.studio.save()


def _cycle_option(app, device_id, setting_id, options, delta: int) -> None:
    values = [item[0] for item in options]
    current = app.setting_choice.get((device_id, setting_id), values[0])
    index = values.index(current) if current in values else 0
    app.setting_choice[(device_id, setting_id)] = values[(index + delta) % len(values)]


def _bump_zoom(app, delta: int) -> None:
    app.zoom = min(100, max(0, app.zoom + delta))


def _cycle_model(app, models, delta: int) -> None:
    device = app.studio.selected()
    if not device:
        return
    index = models.index(device.osmo_model) if device.osmo_model in models else 0
    device.osmo_model = models[(index + delta) % len(models)]
    app.studio.save()


def _pick_osmo(app, device, identifier: str) -> None:
    device.ble_identifier = identifier
    app.studio.save()
    app.studio.note(f"{device.name} 카메라를 골랐습니다.")


def _cycle_mode(app, modes, delta: int) -> None:
    values = [item[0] for item in modes]
    index = values.index(app.osmo_mode) if app.osmo_mode in values else 0
    app.osmo_mode = values[(index + delta) % len(values)]


def _cycle_preset(app, delta: int) -> None:
    count = len(app.studio.profile.presets)
    if count:
        app.preset_index = (app.preset_index + delta) % count


def _cycle_shot(app, preset, delta: int) -> None:
    shots = [""] + list(app.studio.shot_names)
    current = preset.ronin.get("shot") or ""
    index = shots.index(current) if current in shots else 0
    preset.ronin["shot"] = shots[(index + delta) % len(shots)]
    app.studio.save()


def _bump_preset(studio, preset, key, delta, step, low, high) -> None:
    preset.ronin[key] = max(low, min(high, float(preset.ronin.get(key) or 0) + delta * step))
    studio.save()


def _toggle_preset(studio, preset, key) -> None:
    preset.ronin[key] = not bool(preset.ronin.get(key))
    studio.save()


def _cycle_preset_mode(studio, preset, delta: int) -> None:
    modes = [None] + [item[0] for item in writable_modes("osmo360")]
    current = preset.osmo.get("mode")
    index = modes.index(current) if current in modes else 0
    preset.osmo["mode"] = modes[(index + delta) % len(modes)]
    studio.save()


def _delete(app, device_id: str) -> None:
    if app.arm_delete == device_id:
        app.studio.delete_device(device_id)
        app.arm_delete = ""
        app.studio.note("장치를 지웠습니다.")
    else:
        app.arm_delete = device_id
        app.studio.note("한 번 더 확인을 누르면 이 장치를 지웁니다.")


def _delete_preset(app, preset_id: str) -> None:
    app.studio.delete_preset(preset_id)
    app.preset_index = 0


def _mask(text: str) -> str:
    if not text:
        return "비어 있음"
    return "•" * min(8, len(text))
