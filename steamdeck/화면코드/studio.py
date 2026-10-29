"""장치 목록, 프리셋, 함께 촬영을 애플 앱과 같은 규칙으로 다룹니다."""

from __future__ import annotations

import time

from 서버연결.frames import self_check
from 서버연결.protocol import (
    CallError,
    gopro_command,
    http_get,
    parse_gopro_state,
    parse_ronin_status,
    ronin_command,
)
from 화면코드.bus import Bus, Result
from 화면코드.model import (
    KIND_ACTION5,
    KIND_GOPRO,
    KIND_NOAPI,
    KIND_OSMO,
    KIND_RONIN,
    MAX_DEVICES,
    PRODUCTS,
    Device,
    Preset,
    Spot,
    clamp_stage,
    fresh_gopro_settings,
    is_gopro_family,
    load_profile,
    new_id,
    new_ronin_look,
    place_spot,
    save_profile,
    uses_http,
)


class Studio:
    def __init__(self, path, radio) -> None:
        self.path = path
        self.profile = load_profile(path)
        self.radio = radio
        self.bus = Bus()
        self.log: list[str] = []
        self.shot_names = [
            "front", "wide", "tight", "verse", "chorus", "hero", "high", "hands",
            "reveal", "drop", "profile-l", "profile-r", "qtr-l", "qtr-r",
            "whip-l", "whip-r", "drift-l", "drift-r", "dutch-l", "dutch-r",
            "level", "sway", "push", "pull", "crash", "snap-wide", "snap-tight",
        ]
        self.ronin_live: dict[str, dict] = {}
        self.gopro_live: dict[str, dict] = {}
        self.gopro_session: dict[str, str] = {}
        self.record_hold: dict[str, tuple[bool, float]] = {}
        self.selected_id = self.profile.devices[0].id if self.profile.devices else ""
        self._next_refresh = 0.0
        self._next_keepalive = 0.0
        self.ensure_spots()
        if not self_check():
            self.note("프레임 검사가 실패했습니다. 오즈모 명령 형식이 공식 예시와 다릅니다.")

    def note(self, text: str) -> None:
        if not text:
            return
        stamp = time.strftime("%H:%M:%S")
        self.log.insert(0, f"{stamp}  {text}")
        del self.log[40:]

    def save(self) -> None:
        save_profile(self.path, self.profile)

    def device(self, device_id: str) -> Device | None:
        for item in self.profile.devices:
            if item.id == device_id:
                return item
        return None

    def selected(self) -> Device | None:
        return self.device(self.selected_id)

    def select(self, device_id: str) -> None:
        if self.device(device_id):
            self.selected_id = device_id

    def select_step(self, delta: int) -> None:
        devices = self.profile.devices
        if not devices:
            self.selected_id = ""
            return
        ids = [item.id for item in devices]
        if self.selected_id not in ids:
            self.selected_id = ids[0]
            return
        index = (ids.index(self.selected_id) + delta) % len(ids)
        self.selected_id = ids[index]

    def add_device(self, product_id: str) -> None:
        product = next((item for item in PRODUCTS if item[0] == product_id), None)
        if product is None:
            return
        if len(self.profile.devices) >= MAX_DEVICES:
            self.note("장치는 8대까지입니다.")
            return
        _pid, label, kind, model = product
        device = Device(
            id=new_id(),
            name=f"{label} {len(self.profile.devices) + 1}",
            kind=kind,
            osmo_model=model,
            host="10.5.5.9" if kind == KIND_GOPRO else "",
            port=80 if kind in (KIND_RONIN, KIND_ACTION5) else (8080 if kind == KIND_GOPRO else 0),
            ble_identifier="",
        )
        self.profile.devices.append(device)
        self.profile.group_ids.append(device.id)
        self.selected_id = device.id
        self.ensure_spots()
        self.save()
        self.note(f"{device.name} 을 등록했습니다.")

    def delete_device(self, device_id: str) -> None:
        self.profile.devices = [item for item in self.profile.devices if item.id != device_id]
        self.profile.group_ids = [item for item in self.profile.group_ids if item != device_id]
        self.profile.spots = [item for item in self.profile.spots if item.device_id != device_id]
        for preset in self.profile.presets:
            preset.device_ids = [item for item in preset.device_ids if item != device_id]
        if self.selected_id == device_id:
            self.selected_id = self.profile.devices[0].id if self.profile.devices else ""
        self.save()

    def ensure_spots(self) -> None:
        known = {item.id for item in self.profile.devices}
        self.profile.spots = [item for item in self.profile.spots if item.device_id in known]
        count = max(len(self.profile.devices), 1)
        have = {item.device_id for item in self.profile.spots}
        for index, device in enumerate(self.profile.devices):
            if device.id in have:
                continue
            x, y, z = place_spot(index, count)
            self.profile.spots.append(Spot(device.id, x, y, z, 0))

    def spot(self, device_id: str) -> Spot:
        for item in self.profile.spots:
            if item.device_id == device_id:
                return item
        index = next((i for i, item in enumerate(self.profile.devices) if item.id == device_id), 0)
        x, y, z = place_spot(index, max(len(self.profile.devices), 1))
        return Spot(device_id, x, y, z, 0)

    def move_stage(self, device_id: str, x=None, y=None, z=None, aim=None, home_yaw=None, home_pitch=None, write: bool = True) -> None:
        spot = self.spot(device_id)
        x, y, z, aim, home_yaw, home_pitch = clamp_stage(
            spot.x if x is None else x,
            spot.y if y is None else y,
            spot.z if z is None else z,
            spot.aim_yaw if aim is None else aim,
            spot.home_yaw if home_yaw is None else home_yaw,
            spot.home_pitch if home_pitch is None else home_pitch,
        )
        spot.x, spot.y, spot.z = x, y, z
        spot.aim_yaw, spot.home_yaw, spot.home_pitch = aim, home_yaw, home_pitch
        if not any(item.device_id == device_id for item in self.profile.spots):
            self.profile.spots.append(spot)
        if write:
            self.save()

    def grouped(self) -> list[Device]:
        chosen = set(self.profile.group_ids)
        return [item for item in self.profile.devices if item.enabled and item.id in chosen]

    def add_preset(self) -> None:
        preset = Preset(
            id=new_id(),
            name=f"프리셋 {len(self.profile.presets) + 1}",
            note="",
            device_ids=list(self.profile.group_ids),
            ronin=new_ronin_look(),
            gopro={"settings": fresh_gopro_settings(), "loadPresetId": None, "digitalZoomPercent": None},
            osmo={"mode": None},
            connections=[item.to_dict() for item in self.profile.devices],
        )
        self.profile.presets.append(preset)
        self.save()
        self.note(f"{preset.name} 을 만들었습니다.")

    def delete_preset(self, preset_id: str) -> None:
        self.profile.presets = [item for item in self.profile.presets if item.id != preset_id]
        self.save()

    def tick(self) -> None:
        for result in self.bus.pump():
            if result.note:
                self.note(result.note)
            if result.ronin:
                self.ronin_live[result.ronin[0]] = result.ronin[1]
            if result.gopro:
                self.gopro_live[result.gopro[0]] = result.gopro[1]
                if len(result.gopro) > 2 and result.gopro[2]:
                    self.gopro_session[result.gopro[0]] = result.gopro[2]
            if result.shots:
                self.shot_names = list(result.shots)
            if result.paired_id:
                paired = self.device(result.paired_id)
                if paired:
                    paired.paired_once = True
                    self.save()
        now = time.monotonic()
        if now >= self._next_refresh:
            self._next_refresh = now + 2.0
            self.refresh()
        if now >= self._next_keepalive:
            self._next_keepalive = now + 3.0
            self._keepalive()

    def refresh(self) -> None:
        if self.profile.practice:
            return
        for device in self.profile.devices:
            if not device.enabled or not device.base_url():
                continue
            if device.kind == KIND_RONIN:
                self.bus.submit(lambda device=device: self._read_ronin(device))
            elif is_gopro_family(device.kind):
                self.bus.submit(lambda device=device: self._read_gopro(device))

    def _read_ronin(self, device: Device) -> Result:
        text = ronin_command(device, "/status", timeout=2.5)
        status = parse_ronin_status(text)
        names = []
        try:
            shots = ronin_command(device, "/shots", timeout=2.5)
            import json
            raw = json.loads(shots)
            names = list(raw.get("shots") or [])
        except (CallError, ValueError):
            names = []
        return Result(ronin=(device.id, status), shots=names or None)

    def _read_gopro(self, device: Device) -> Result:
        text = gopro_command(device, "/gopro/camera/state")
        live = parse_gopro_state(text)
        return Result(gopro=(device.id, live, ""))

    def _keepalive(self) -> None:
        if self.profile.practice:
            return
        for device in self.profile.devices:
            if device.enabled and is_gopro_family(device.kind) and device.base_url():
                self.bus.submit(lambda device=device: self._keep(device))

    def _keep(self, device: Device) -> Result:
        try:
            gopro_command(device, "/gopro/camera/keep_alive", timeout=3)
            where = "중계 기판 세션" if device.kind == KIND_ACTION5 else "카메라 와이파이 세션"
            return Result(gopro=(device.id, self.gopro_live.get(device.id) or {}, f"{where} 유지 중"))
        except CallError:
            hint = "중계 기판에 붙지 못했습니다" if device.kind == KIND_ACTION5 else "카메라 와이파이에 붙지 못했습니다"
            return Result(gopro=(device.id, self.gopro_live.get(device.id) or {}, hint))

    def set_stick(self, device: Device | None, yaw: float, pitch: float) -> None:
        if device and device.kind == KIND_RONIN and device.enabled:
            self.bus.set_motion(device, yaw, pitch, self.profile.practice)
        else:
            self.bus.set_motion(None, 0, 0, self.profile.practice)

    def stop_selected(self) -> None:
        device = self.selected()
        if not device or device.kind != KIND_RONIN:
            self.bus.set_motion(None, 0, 0, self.profile.practice)
            return
        self.bus.set_motion(device, 0, 0, self.profile.practice)
        self._ronin(device, "/stop", {})

    def home(self) -> None:
        device = self.selected()
        if not device or device.kind != KIND_RONIN:
            self.note("제자리는 로닌 기판에만 보냅니다.")
            return
        spot = self.spot(device.id)
        self._ronin(device, "/move", {
            "yaw": f"{spot.home_yaw:.2f}",
            "roll": "0",
            "pitch": f"{spot.home_pitch:.2f}",
            "time": "1.2",
        })

    def remember_home(self) -> None:
        device = self.selected()
        if not device:
            return
        status = self.ronin_live.get(device.id) or {}
        if status.get("attitude_valid") is not True or status.get("yaw") is None or status.get("pitch") is None:
            self.note(f"{device.name} 각도를 아직 받지 못해 제자리로 기억하지 못했습니다.")
            return
        self.move_stage(device.id, home_yaw=float(status["yaw"]), home_pitch=float(status["pitch"]))
        self.note(f"{device.name} 제자리 요 {float(status['yaw']):.1f}° 피치 {float(status['pitch']):.1f}°")

    def record_toggle(self) -> None:
        device = self.selected()
        if not device:
            self.note("선택된 장치가 없습니다.")
            return
        start = self._next_record(device)
        self.record_hold[device.id] = (start, time.monotonic())
        self._record(device, start)

    def together(self, start: bool) -> None:
        devices = self.grouped()
        if not devices:
            self.note("선택된 장치가 없습니다.")
            return
        if self.profile.practice:
            names = ", ".join(item.name for item in devices)
            self.note(f"연습: 함께 {'시작' if start else '정지'}. {names}. 장치에 보내지 않았습니다.")
            return
        lead = min(10000, max(0, self.profile.lead_ms))
        self.note("함께 촬영을 보내는 중입니다.")
        self.bus.submit(lambda: self._together_work(devices, start, lead))

    def _together_work(self, devices, start: bool, lead: int) -> Result:
        lines = []
        ronins = [item for item in devices if item.kind == KIND_RONIN]
        samples = {}
        for device in ronins:
            try:
                begun = time.time()
                text = ronin_command(device, "/sync/clock", timeout=2)
                ended = time.time()
                import json
                millis = int(json.loads(text)["millis"])
                samples[device.id] = (millis, begun + (ended - begun) / 2)
            except (CallError, ValueError, KeyError):
                samples[device.id] = None
        when = time.time() + max(lead, 50) / 1000
        for device in ronins:
            lines.append(self._sync_ronin(device, start, when, samples.get(device.id), lead).note)
        for device in devices:
            if is_gopro_family(device.kind):
                lines.append(self._gopro_at(device, start, when).note)
        osmos = [item for item in devices if item.kind == KIND_OSMO]
        if len(osmos) > 1:
            lines.append("오즈모가 여러 대이면 블루투스 명령이 한 대씩 나가 시작이 조금 어긋날 수 있습니다.")
        for device in osmos:
            lines.append(self._osmo_at(device, start, when).note)
        for device in devices:
            if device.kind == KIND_NOAPI:
                lines.append(f"{device.name}: 공개된 제어 API가 없어 함께 {'시작' if start else '정지'}에서 빠졌습니다.")
        return Result(note=" | ".join(line for line in lines if line))

    def _sync_ronin(self, device, start, when, sample, lead) -> Result:
        action = "start" if start else "stop"
        try:
            if sample:
                delta = int((when - sample[1]) * 1000)
                at = (sample[0] + delta) % (2**32)
                text = ronin_command(device, "/sync/record", {"action": action, "at_ms": str(at)})
                return Result(note=f"{device.name} 기판 시계에 맞춤 {text}")
            text = ronin_command(device, "/sync/record", {"action": action, "delay_ms": str(lead)})
            return Result(note=f"{device.name} 시계를 못 읽어 delay_ms 로 보냄 {text}")
        except CallError as error:
            return Result(note=f"{device.name} {error}")

    def _gopro_at(self, device, start, when) -> Result:
        self._wait_until(when)
        try:
            text = gopro_command(device, f"/gopro/camera/shutter/{'start' if start else 'stop'}")
            return Result(note=f"{device.name} 고프로 셔터 {text or '보냄'}")
        except CallError as error:
            return Result(note=f"{device.name} {error}")

    def _osmo_at(self, device, start, when) -> Result:
        self._wait_until(when)
        return Result(note=self.radio.record(device, start))

    def _wait_until(self, when: float) -> None:
        delay = when - time.time()
        if delay > 0:
            time.sleep(delay)

    def _next_record(self, device: Device) -> bool:
        hold = self.record_hold.get(device.id)
        if hold and time.monotonic() - hold[1] < 1.5:
            return not hold[0]
        if device.kind == KIND_RONIN:
            live = self.ronin_live.get(device.id)
            if live:
                if live.get("sony_recording") is True or live.get("cam_recording") is True:
                    return False
                if live.get("cam_recording") is False or live.get("sony_recording") is False:
                    return True
        elif is_gopro_family(device.kind):
            live = self.gopro_live.get(device.id)
            if live and live.get("encoding") is not None:
                return not bool(live.get("encoding"))
        elif device.kind == KIND_OSMO:
            status = (self.radio.snapshot(device.id) or {}).get("status")
            if status in (3, 5):
                return False
            if status is not None:
                return True
        return True

    def _record(self, device: Device, start: bool) -> None:
        if device.kind == KIND_NOAPI:
            self.note(f"{device.name}: 공개된 제어 API가 없어 녹화를 보내지 않습니다.")
            return
        if self.profile.practice:
            self.note(f"연습: {device.name} {'시작' if start else '정지'}")
            return
        if device.kind == KIND_RONIN:
            self._ronin(device, "/record", {"action": "start" if start else "stop"})
        elif is_gopro_family(device.kind):
            path = f"/gopro/camera/shutter/{'start' if start else 'stop'}"
            self._gopro(device, path, None, "셔터 시작" if start else "셔터 정지")
        elif device.kind == KIND_OSMO:
            self.bus.submit(lambda: Result(note=self.radio.record(device, start)))

    def _ronin(self, device: Device, path: str, query: dict) -> None:
        if self.profile.practice:
            self.note(f"연습: {device.name} {path}")
            return
        if not uses_http(device.kind) or not device.base_url():
            self.note(f"{device.name} 주소가 비어 있습니다.")
            return

        def work() -> Result:
            text = ronin_command(device, path, query)
            return Result(note=f"{device.name} {path} {text}")

        self.bus.submit(work)

    def ronin_shot(self, name: str) -> None:
        device = self.selected()
        if not device or device.kind != KIND_RONIN:
            return
        self._ronin(device, f"/shot/{name}", {"t": "1.00"})

    def gopro_setting(self, setting_id: int, option: int, label: str) -> None:
        device = self.selected()
        if not device or not is_gopro_family(device.kind):
            return
        self._gopro(device, "/gopro/camera/setting", {"setting": str(setting_id), "option": str(option)}, label)

    def gopro_zoom(self, percent: int) -> None:
        device = self.selected()
        if not device or device.kind != KIND_GOPRO:
            self.note("디지털 줌은 고프로 와이파이에만 보냅니다.")
            return
        self._gopro(device, "/gopro/camera/digital_zoom", {"percent": str(max(0, min(100, percent)))}, "디지털 줌")

    def preview_stream(self, start: bool) -> None:
        device = self.selected()
        if not device or device.kind != KIND_GOPRO:
            self.note("실시간 그림은 고프로 와이파이만 엽니다.")
            return
        path = f"/gopro/camera/stream/{'start' if start else 'stop'}"
        self._gopro(device, path, None, "미리보기 시작" if start else "미리보기 정지", timeout=6)

    def relay_pair(self) -> None:
        device = self.selected()
        if not device or device.kind != KIND_ACTION5:
            return
        self._gopro(device, "/pair", None, "블루투스 다시 붙기", timeout=25)

    def relay_wifi(self, ssid: str, password: str) -> None:
        device = self.selected()
        if not device or device.kind != KIND_ACTION5:
            return
        if self.profile.practice:
            self.note("연습: 와이파이 저장은 보내지 않았습니다.")
            return
        self.bus.submit(lambda: Result(note=self._relay_wifi_work(device, ssid, password)))

    def _relay_wifi_work(self, device, ssid, password) -> str:
        try:
            http_get(device.host, device.port, "/wifi", {"ssid": ssid, "pass": password}, timeout=8)
        except CallError as error:
            return f"{device.name} {error}"
        return f"{device.name} 집 와이파이를 중계 기판에만 저장했습니다."

    def sony_connect(self, ssid: str, password: str, host: str) -> None:
        device = self.selected()
        if not device or device.kind != KIND_RONIN:
            return
        if self.profile.practice:
            self.note("연습: 소니 연결은 보내지 않았습니다.")
            return

        def work() -> Result:
            ronin_command(device, "/sony/connect", {"ssid": ssid, "pass": password, "host": host})
            return Result(note=f"{device.name} 소니 연결 요청을 보냈습니다. 비밀번호는 기판에만 저장됩니다.")

        self.bus.submit(work)

    def _gopro(self, device, path, query, label, timeout=4) -> None:
        if self.profile.practice:
            self.note(f"연습: {device.name} {label}")
            return
        if not device.base_url():
            self.note(f"{device.name} 주소가 비어 있습니다.")
            return

        def work() -> Result:
            text = gopro_command(device, path, query, timeout=timeout)
            return Result(note=f"{device.name} {label} {text or '보냄'}")

        self.bus.submit(work)

    def apply_preset(self, preset: Preset) -> None:
        if preset.device_ids:
            self.profile.group_ids = list(preset.device_ids)
            self.save()
        targets = self._targets(preset)
        if not targets:
            self.note("적용할 장치가 없습니다.")
            return
        if self.profile.practice:
            self.note("연습: " + preset.name + " 을 적용하는 척만 했습니다. " + ", ".join(item.name for item in targets))
            return
        for device in targets:
            self.bus.submit(lambda device=device: self._apply_one(preset, device))
        if preset.osmo.get("mode") is not None:
            for device in targets:
                if device.kind == KIND_OSMO:
                    mode = int(preset.osmo["mode"])
                    self.bus.submit(lambda device=device, mode=mode: Result(note=self.radio.set_mode(device, mode)))

    def apply_ronin_look(self, preset: Preset) -> None:
        device = self.selected()
        if not device or device.kind != KIND_RONIN:
            self.note("이 프리셋의 짐벌 동작은 로닌을 고른 뒤에 보냅니다.")
            return
        if self.profile.practice:
            self.note(f"연습: {device.name} {preset.name}")
            return
        self.bus.submit(lambda: self._apply_one(preset, device))

    def _targets(self, preset: Preset) -> list[Device]:
        enabled = [item for item in self.profile.devices if item.enabled]
        if not preset.device_ids:
            return enabled
        chosen = set(preset.device_ids)
        return [item for item in enabled if item.id in chosen]

    def _apply_one(self, preset: Preset, device: Device) -> Result:
        if device.kind == KIND_RONIN:
            parts = []
            shot = preset.ronin.get("shot") or ""
            if shot:
                scale = min(4, max(0.25, float(preset.ronin.get("timeScale") or 1)))
                try:
                    parts.append(ronin_command(device, f"/shot/{shot}", {"t": f"{scale:.2f}"}))
                except CallError:
                    parts.append("샷 실패")
            if preset.ronin.get("sendMove"):
                path = "/move" if preset.ronin.get("absolute", True) else "/relative"
                try:
                    parts.append(ronin_command(device, path, {
                        "yaw": str(preset.ronin.get("yaw") or 0),
                        "roll": str(preset.ronin.get("roll") or 0),
                        "pitch": str(preset.ronin.get("pitch") or 0),
                        "time": str(preset.ronin.get("seconds") or 1.5),
                    }))
                except CallError:
                    parts.append("이동 실패")
            if not parts:
                return Result(note="")
            return Result(note=f"{device.name} {' '.join(parts)}")
        if is_gopro_family(device.kind):
            parts = []
            for choice in preset.gopro.get("settings") or []:
                if not choice.get("enabled"):
                    continue
                try:
                    gopro_command(device, "/gopro/camera/setting", {
                        "setting": str(choice["settingId"]),
                        "option": str(choice["option"]),
                    })
                    parts.append(f"설정 {choice['settingId']}")
                except CallError:
                    parts.append(f"설정 {choice['settingId']} 실패")
            if device.kind == KIND_GOPRO:
                if preset.gopro.get("loadPresetId") is not None:
                    try:
                        gopro_command(device, "/gopro/camera/presets/load", {"id": str(preset.gopro["loadPresetId"])})
                        parts.append(f"카메라 프리셋 {preset.gopro['loadPresetId']}")
                    except CallError:
                        parts.append("프리셋 실패")
                if preset.gopro.get("digitalZoomPercent") is not None:
                    try:
                        gopro_command(device, "/gopro/camera/digital_zoom", {"percent": str(preset.gopro["digitalZoomPercent"])})
                        parts.append("디지털 줌")
                    except CallError:
                        parts.append("줌 실패")
            elif preset.gopro.get("loadPresetId") is not None or preset.gopro.get("digitalZoomPercent") is not None:
                parts.append("줌과 카메라 프리셋은 오즈모 액션 5 프로 중계에 없습니다")
            if not parts:
                return Result(note="")
            return Result(note=f"{device.name} {', '.join(parts)}")
        return Result(note="")

    def remember_connections(self, preset: Preset) -> None:
        preset.connections = [item.to_dict() for item in self.profile.devices]
        self.save()
        self.note(f"{preset.name} 에 지금 주소를 저장했습니다.")

    def restore_connections(self, preset: Preset) -> None:
        added = 0
        have = {item.id for item in self.profile.devices}
        for raw in preset.connections:
            if raw.get("id") in have:
                continue
            if len(self.profile.devices) >= MAX_DEVICES:
                self.note("8대를 넘어 더 가져오지 못했습니다.")
                break
            device = Device.from_dict(raw)
            self.profile.devices.append(device)
            if device.id not in self.profile.group_ids:
                self.profile.group_ids.append(device.id)
            added += 1
        self.ensure_spots()
        self.save()
        self.note("가져올 새 주소가 없습니다." if added == 0 else f"프리셋에서 주소 {added}개를 가져왔습니다.")

    def photo(self) -> None:
        device = self.selected()
        if not device or device.kind != KIND_RONIN:
            self.note("셔터는 로닌 기판의 CAN 사진 명령입니다.")
            return
        self._ronin(device, "/photo", {})

    def osmo_pair(self, verify: int) -> None:
        device = self.selected()
        if not device or device.kind != KIND_OSMO:
            return
        if self.profile.practice:
            self.note("연습: 블루투스 연결은 하지 않습니다.")
            return
        sender = self.profile.sender_id
        mac = list(self.profile.sender_mac)

        def work() -> Result:
            text = self.radio.pair(device, sender, mac, verify)
            paired = device.id if "프로토콜 연결됨" in text else ""
            return Result(note=text, paired_id=paired)

        self.bus.submit(work)

    def osmo_scan(self) -> None:
        if self.profile.practice:
            self.note("연습: 카메라 찾기는 하지 않습니다.")
            return
        self.bus.submit(lambda: Result(note=self.radio.scan()))

    def osmo_mode(self, mode: int) -> None:
        device = self.selected()
        if not device or device.kind != KIND_OSMO:
            return
        if self.profile.practice:
            self.note(f"연습: {device.name} 모드")
            return
        self.bus.submit(lambda: Result(note=self.radio.set_mode(device, mode)))
