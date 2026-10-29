"""스팀 덱 화면입니다. 가운데는 무대, 왼쪽은 장치, 오른쪽은 상태·설정·프리셋입니다.

화면 아래의 휠은 없습니다. 고른 장치는 왼쪽 스틱으로 움직입니다.
"""

from __future__ import annotations

import os
import time
import warnings

import pygame

import 경로
from 서버연결.osmo import OsmoRadio
from 서버연결.preview import GoProPreview
from 화면코드.model import KIND_GOPRO, KIND_RONIN, profile_path
from 화면코드.panels import build_rows, status_lines
from 화면코드.stage_draw import BRASS, INK, OXBLOOD, PAPER, draw_stage
from 화면코드.stick import stick_speed, visual_offsets
from 화면코드.studio import Studio

TABS = [
    ("status", "상태"),
    ("settings", "설정"),
    ("presets", "프리셋"),
    ("add", "장치 추가"),
]

SECRET_KEYS = {"sony-ssid", "sony-pass", "sony-host", "relay-ssid", "relay-pass"}


class Fonts:
    """글꼴을 그립니다. 파이썬 3.14의 pygame.font 순환 불러오기도 피합니다."""

    def __init__(self) -> None:
        path = 경로.root() / "화면코드" / "fonts" / "NotoSansKR-Regular.otf"
        self.path = str(path) if path.exists() else None
        self.cache = {}
        self._ft = None
        self.kind = "font"
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                pygame.font.Font(self.path, 12).render("가", True, (0, 0, 0))
        except Exception:
            import pygame._freetype as freetype
            if not freetype.get_init():
                freetype.init()
            self._ft = freetype
            self.kind = "ft"

    def render(self, size: int, text: str, color):
        font = self.cache.get(size)
        if font is None:
            if self.kind == "font":
                font = pygame.font.Font(self.path, size) if self.path else pygame.font.SysFont("sans", size)
            else:
                font = self._ft.Font(self.path, size)
            self.cache[size] = font
        if self.kind == "font":
            return font.render(text, True, color)
        image, _rect = font.render(text, color)
        return image


class DeckApp:
    def __init__(self, profile_file: str | None = None) -> None:
        self.fonts = Fonts()
        self.radio = OsmoRadio()
        self.preview = GoProPreview()
        self.studio = Studio(profile_path(profile_file or os.environ.get("RONIN_DECK_PROFILE")), self.radio)
        self.tab = "status"
        self.row_id = ""
        self.stick = (0.0, 0.0)
        self.camera = {"yaw": -0.58, "pitch": 0.46, "zoom": 1.05}
        self.memory: dict[tuple[str, str], str] = {}
        self.setting_choice: dict[tuple[str, int], int] = {}
        self.zoom = 0
        self.osmo_mode = 0x01
        self.preset_index = 0
        self.arm_delete = ""
        self.typing = ""
        self.typing_original = ""
        self.preview_for = ""
        self.preview_on = False
        self.hot: list[tuple[pygame.Rect, object]] = []
        self.hits: list[tuple[str, float, float]] = []
        self.stage_rect = pygame.Rect(0, 0, 0, 0)
        self._drag = ""
        self._pad = None
        self._pad_name = ""
        self._buttons: dict[str, bool] = {}
        self._warned_host = False
        self._stage_dirty = False
        self._stage_save_at = 0.0
        self._l1_down = False
        self._l1_used = False
        self._bind_pad()

    def shutdown(self) -> None:
        self.studio.set_stick(None, 0, 0)
        if self._stage_dirty:
            self.studio.save()
        self.preview.stop()
        self.studio.bus.shutdown()

    def event(self, event) -> None:
        if event.type == pygame.KEYDOWN:
            self._key(event)
        elif event.type == pygame.TEXTINPUT and self.typing:
            self._type(event.text)
        elif event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
            self._press(event.pos)
        elif event.type == pygame.MOUSEBUTTONUP and event.button == 1:
            self._drag = ""
        elif event.type == pygame.MOUSEMOTION and self._drag == "orbit":
            self.camera["yaw"] += event.rel[0] * 0.008
            self.camera["pitch"] = min(1.48, max(0.08, self.camera["pitch"] + event.rel[1] * 0.008))
        elif event.type == pygame.MOUSEWHEEL:
            self.camera["zoom"] = min(2.4, max(0.55, self.camera["zoom"] + event.y * 0.08))

    def update(self, dt: float) -> None:
        self._poll_pad()
        keys = pygame.key.get_pressed()
        stick_x, stick_y = self._axes()
        if not self.typing:
            if keys[pygame.K_a] or keys[pygame.K_d] or keys[pygame.K_w] or keys[pygame.K_s]:
                stick_x += (1 if keys[pygame.K_d] else 0) - (1 if keys[pygame.K_a] else 0)
                stick_y += (1 if keys[pygame.K_s] else 0) - (1 if keys[pygame.K_w] else 0)
            if keys[pygame.K_l]:
                self._right_stick(1, 0, dt)
            if keys[pygame.K_j]:
                self._right_stick(-1, 0, dt)
            if keys[pygame.K_i]:
                self._right_stick(0, -1, dt)
            if keys[pygame.K_k]:
                self._right_stick(0, 1, dt)
            if keys[pygame.K_q]:
                self._height(-1, dt)
            if keys[pygame.K_e]:
                self._height(1, dt)
        stick_x = max(-1.0, min(1.0, stick_x))
        stick_y = max(-1.0, min(1.0, stick_y))
        self.stick = (stick_x, stick_y)
        yaw, _roll, pitch = stick_speed(stick_x, stick_y)
        device = self.studio.selected()
        if device and device.kind == KIND_RONIN:
            self.studio.set_stick(device, yaw, pitch)
            if (abs(yaw) > 1 or abs(pitch) > 1) and not device.base_url() and not self._warned_host:
                self.studio.note("주소가 비어 있습니다.")
                self._warned_host = True
        else:
            self.studio.set_stick(None, 0, 0)
        self._right_from_pad(dt)
        self.studio.tick()
        self._preview_follow()
        if self._stage_dirty and time.monotonic() >= self._stage_save_at:
            self.studio.save()
            self._stage_dirty = False
            self._stage_save_at = time.monotonic() + 0.5

    def draw(self, screen) -> None:
        screen.fill(PAPER)
        width, height = screen.get_size()
        left_w = 250 if width >= 1100 else 190
        right_w = 400 if width >= 1100 else 280
        self.stage_rect = pygame.Rect(left_w, 0, max(10, width - left_w - right_w), height)
        self.hot = []
        self._draw_devices(screen, pygame.Rect(0, 0, left_w, height))
        drives = self._drives()
        nudge = self._nudge()
        self.hits = draw_stage(screen, self.stage_rect, self.studio, self.camera, drives, nudge, self.fonts)
        self._draw_side(screen, pygame.Rect(width - right_w, 0, right_w, height))

    def confirm(self) -> None:
        if self.typing:
            self.typing = ""
            self.studio.save()
            return
        row = self._current()
        if row is None:
            return
        if row.text_key:
            self.typing = row.text_key
            self.typing_original = self._text_get(row.text_key)
            self.studio.note("글자를 입력하세요. Y 또는 Enter 로 끝냅니다. 비밀번호는 저장 파일에 넣지 않습니다.")
            return
        if row.on_y:
            row.on_y()

    def move_row(self, delta: int) -> None:
        rows = build_rows(self)
        if not rows:
            return
        ids = [row.id for row in rows]
        index = ids.index(self.row_id) if self.row_id in ids else 0
        self.row_id = ids[(index + delta) % len(ids)]

    def adjust(self, delta: int) -> None:
        if self.typing:
            return
        row = self._current()
        if row and row.on_x:
            row.on_x(delta)
        elif self.tab == "status":
            self.camera["yaw"] += delta * 0.08

    def _current(self):
        rows = build_rows(self)
        if not rows:
            return None
        for row in rows:
            if row.id == self.row_id:
                return row
        self.row_id = rows[0].id
        return rows[0]

    def _key(self, event) -> None:
        if self.typing:
            if event.key == pygame.K_RETURN:
                self.confirm()
            elif event.key == pygame.K_BACKSPACE:
                self._type_back()
            elif event.key == pygame.K_ESCAPE:
                self._text_set(self.typing, self.typing_original)
                self.typing = ""
            elif event.unicode and event.key not in (pygame.K_RETURN, pygame.K_ESCAPE):
                self._type(event.unicode)
            return
        if event.key in (pygame.K_UP,):
            self.move_row(-1)
        elif event.key in (pygame.K_DOWN,):
            self.move_row(1)
        elif event.key == pygame.K_LEFT:
            self.adjust(-1)
        elif event.key == pygame.K_RIGHT:
            self.adjust(1)
        elif event.key in (pygame.K_RETURN, pygame.K_SPACE):
            if event.key == pygame.K_SPACE:
                self._record()
            else:
                self.confirm()
        elif event.key == pygame.K_BACKSPACE:
            self.studio.stop_selected()
        elif event.key == pygame.K_z:
            self.studio.select_step(-1)
        elif event.key == pygame.K_x:
            self.studio.select_step(1)
        elif event.key == pygame.K_TAB:
            self._cycle_tab(1)
        elif event.key == pygame.K_p:
            self._practice()
        elif event.key == pygame.K_h:
            self.studio.home()
        elif event.key == pygame.K_LEFTBRACKET:
            self.camera["yaw"] -= 0.08
        elif event.key == pygame.K_RIGHTBRACKET:
            self.camera["yaw"] += 0.08
        elif event.key == pygame.K_F11:
            pygame.display.toggle_fullscreen()
        elif event.key == pygame.K_ESCAPE:
            self.studio.stop_selected()

    def _record(self) -> None:
        if self._held("leftshoulder"):
            self.studio.together(True)
        else:
            self.studio.record_toggle()

    def _stop_button(self) -> None:
        if self._held("leftshoulder"):
            self.studio.together(False)
        else:
            self.studio.stop_selected()

    def _practice(self) -> None:
        self.studio.profile.practice = not self.studio.profile.practice
        self.studio.save()
        self.studio.note("연습 모드입니다. 장치에 보내지 않습니다." if self.studio.profile.practice else "연습 모드를 껐습니다.")

    def _cycle_tab(self, delta: int) -> None:
        ids = [item[0] for item in TABS]
        index = ids.index(self.tab) if self.tab in ids else 0
        self.tab = ids[(index + delta) % len(ids)]
        self.row_id = ""

    def _press(self, pos) -> None:
        for rect, action in self.hot:
            if rect.collidepoint(pos):
                action()
                return
        if self.stage_rect.collidepoint(pos):
            for device_id, x, y in self.hits:
                if (x - pos[0]) ** 2 + (y - pos[1]) ** 2 < 28 ** 2:
                    self.studio.select(device_id)
                    self._drag = "device"
                    return
            self._drag = "orbit"

    def _draw_devices(self, screen, rect) -> None:
        pygame.draw.line(screen, INK, (rect.right - 1, 0), (rect.right - 1, rect.height), 1)
        self._blit(screen, 22, "장치", INK, (16, 14))
        y = 52
        for device in self.studio.profile.devices:
            chosen = device.id == self.studio.selected_id
            row = pygame.Rect(8, y, rect.width - 16, 46)
            if chosen:
                pygame.draw.rect(screen, (232, 214, 176), row, border_radius=6)
            mark = ""
            from 화면코드.model import record_mark
            live = self.studio.ronin_live.get(device.id)
            gopro = self.studio.gopro_live.get(device.id)
            osmo = self.studio.radio.snapshot(device.id).get("status")
            text = record_mark(device.kind, live, gopro, osmo)
            if text:
                mark = "  " + text
            self._blit(screen, 16, device.name + mark, OXBLOOD if text else INK, (16, y + 4))
            self._blit(screen, 13, device.label(), (90, 80, 70), (16, y + 24))
            self.hot.append((row, lambda device_id=device.id: self.studio.select(device_id)))
            y += 50
        if not self.studio.profile.devices:
            self._blit(screen, 15, "아직 장치가 없습니다.", INK, (16, 60))
        log_y = rect.height - 18 * min(5, len(self.studio.log)) - 12
        for line in reversed(self.studio.log[:5]):
            self._blit(screen, 12, line[:42], (90, 80, 70), (10, log_y))
            log_y += 16

    def _draw_side(self, screen, rect) -> None:
        pygame.draw.line(screen, INK, (rect.left, 0), (rect.left, rect.height), 1)
        x = rect.left + 8
        y = 8
        for tab_id, title in TABS:
            image = self.fonts.render(15, title, INK)
            box = pygame.Rect(x, y, image.get_width() + 16, 28)
            if tab_id == self.tab:
                pygame.draw.rect(screen, BRASS, box, border_radius=6)
            else:
                pygame.draw.rect(screen, PAPER, box, border_radius=6)
                pygame.draw.rect(screen, INK, box, 1, border_radius=6)
            screen.blit(image, (box.x + 8, box.y + 4))
            self.hot.append((box, lambda tab_id=tab_id: self._set_tab(tab_id)))
            x += box.width + 6
        body_top = 46
        if self.tab == "status" and self.studio.selected() and self.studio.selected().kind == KIND_GOPRO:
            self._draw_preview(screen, pygame.Rect(rect.left + 10, body_top, rect.width - 20, 160))
            body_top += 168
        if self.tab == "status":
            line_y = body_top
            for line in status_lines(self)[:8]:
                self._blit(screen, 14, line[:46], INK, (rect.left + 12, line_y))
                line_y += 18
            body_top = line_y + 8
        rows = build_rows(self)
        if rows and self.row_id not in [row.id for row in rows]:
            self.row_id = rows[0].id
        window = rows
        if len(rows) > 9:
            index = next((i for i, row in enumerate(rows) if row.id == self.row_id), 0)
            start = min(max(0, index - 4), len(rows) - 9)
            window = rows[start:start + 9]
        y = body_top
        for row in window:
            box = pygame.Rect(rect.left + 8, y, rect.width - 16, 36)
            if row.id == self.row_id:
                pygame.draw.rect(screen, (232, 214, 176), box, border_radius=4)
            self._blit(screen, 14, row.label[:16], INK, (box.x + 6, box.y + 2))
            self._blit(screen, 13, (row.value or "")[:22], (90, 80, 70), (box.x + 6, box.y + 18))
            if row.y_label:
                label = self.fonts.render(13, row.y_label, PAPER)
                button = pygame.Rect(box.right - label.get_width() - 16, box.y + 8, label.get_width() + 12, 20)
                pygame.draw.rect(screen, INK, button, border_radius=4)
                screen.blit(label, (button.x + 6, button.y + 2))
                self.hot.append((button, self.confirm if row.id == self.row_id else lambda row_id=row.id: self._activate(row_id)))
            self.hot.append((box, lambda row_id=row.id: self._focus(row_id)))
            y += 40
        footer = rect.bottom - 78
        pygame.draw.line(screen, (210, 200, 186), (rect.left + 8, footer), (rect.right - 8, footer), 1)
        practice = "연습 켜짐" if self.studio.profile.practice else "연습 꺼짐"
        pad = self._pad_name or "컨트롤러 없음. 키보드로 같은 동작을 합니다."
        current = self._current()
        y_name = current.y_label if current and current.y_label else "확인"
        self._blit(screen, 13, f"A 녹화   B 정지   Y {y_name}", INK, (rect.left + 10, footer + 6))
        self._blit(screen, 13, f"메뉴 탭   보기 {practice}", INK, (rect.left + 10, footer + 24))
        self._blit(screen, 12, "L1 제자리  L1+A 함께 시작  L1+B 함께 정지", (90, 80, 70), (rect.left + 10, footer + 42))
        self._blit(screen, 12, pad[:42], (90, 80, 70), (rect.left + 10, footer + 58))

    def _draw_preview(self, screen, rect) -> None:
        pygame.draw.rect(screen, PAPER, rect)
        pygame.draw.rect(screen, INK, rect, 1)
        frame, note, packets = self.preview.latest()
        if frame:
            width, height, raw = frame
            image = pygame.image.frombuffer(raw, (width, height), "RGB")
            fitted = pygame.transform.smoothscale(image, rect.size)
            screen.blit(fitted, rect.topleft)
        else:
            text = note or "카메라 영상을 기다리는 중입니다."
            if packets and "ffmpeg" in text:
                text = f"{text} ({packets})"
            self._blit(screen, 14, text[:40], INK, (rect.x + 8, rect.y + rect.height // 2 - 8))

    def _focus(self, row_id: str) -> None:
        self.row_id = row_id

    def _activate(self, row_id: str) -> None:
        self.row_id = row_id
        self.confirm()

    def _set_tab(self, tab_id: str) -> None:
        self.tab = tab_id
        self.row_id = ""

    def _drives(self) -> dict:
        drives = {}
        stick_x, stick_y = self.stick
        yaw_off, pitch_off = visual_offsets(stick_x, stick_y)
        selected = self.studio.selected_id
        for device in self.studio.profile.devices:
            if device.kind != KIND_RONIN:
                continue
            spot = self.studio.spot(device.id)
            live = self.studio.ronin_live.get(device.id) or {}
            if live.get("attitude_valid") and live.get("yaw") is not None and live.get("pitch") is not None:
                drives[device.id] = (spot.aim_yaw + float(live["yaw"]), -float(live["pitch"]))
            elif device.id == selected and (yaw_off or pitch_off):
                drives[device.id] = (spot.aim_yaw + spot.home_yaw + yaw_off, -spot.home_pitch + pitch_off)
        return drives

    def _nudge(self):
        device = self.studio.selected()
        if not device or device.kind == KIND_RONIN:
            return None
        yaw_off, pitch_off = visual_offsets(*self.stick)
        if not yaw_off and not pitch_off:
            return None
        return (device.id, yaw_off, pitch_off)

    def _right_from_pad(self, dt: float) -> None:
        if not self._pad:
            return
        rx = self._axis(pygame.CONTROLLER_AXIS_RIGHTX) 
        ry = self._axis(pygame.CONTROLLER_AXIS_RIGHTY)
        self._right_stick(rx, ry, dt)
        self._height(self._axis(pygame.CONTROLLER_AXIS_TRIGGERRIGHT) - self._axis(pygame.CONTROLLER_AXIS_TRIGGERLEFT), dt)

    def _right_stick(self, rx: float, ry: float, dt: float) -> None:
        if abs(rx) < 0.2 and abs(ry) < 0.2:
            return
        device = self.studio.selected()
        if not device:
            return
        spot = self.studio.spot(device.id)
        self.studio.move_stage(device.id, x=spot.x + rx * 1.6 * dt, y=spot.y + ry * 1.6 * dt, write=False)
        self._stage_dirty = True

    def _height(self, amount: float, dt: float) -> None:
        if abs(amount) < 0.2:
            return
        device = self.studio.selected()
        if not device:
            return
        spot = self.studio.spot(device.id)
        self.studio.move_stage(device.id, z=spot.z + amount * 0.8 * dt, write=False)
        self._stage_dirty = True

    def _preview_follow(self) -> None:
        device = self.studio.selected()
        want = bool(device and device.kind == KIND_GOPRO and device.base_url() and not self.studio.profile.practice and self.preview_on)
        if want and self.preview_for != device.id:
            self.preview.open(device)
            self.studio.preview_stream(True)
            self.preview_for = device.id
        elif not want and self.preview_for:
            if device and device.kind == KIND_GOPRO:
                self.studio.preview_stream(False)
            self.preview.stop()
            self.preview_for = ""

    def toggle_preview(self) -> None:
        self.preview_on = not self.preview_on
        self.studio.note("실시간 그림을 엽니다." if self.preview_on else "실시간 그림을 닫습니다.")

    def _text_get(self, key: str) -> str:
        device = self.studio.selected()
        preset = self._preset()
        if key == "name" and device:
            return device.name
        if key == "host" and device:
            return device.host
        if key == "preset-name" and preset:
            return preset.name
        if key == "preset-note" and preset:
            return preset.note
        if device and key in SECRET_KEYS:
            if key == "sony-host" and (device.id, key) not in self.memory:
                return "192.168.122.1"
            return self.memory.get((device.id, key), "")
        return ""

    def _text_set(self, key: str, value: str) -> None:
        device = self.studio.selected()
        preset = self._preset()
        if key in SECRET_KEYS and device:
            self.memory[(device.id, key)] = value
            return
        if key == "name" and device:
            device.name = value
        elif key == "host" and device:
            device.host = value
        elif key == "preset-name" and preset:
            preset.name = value
        elif key == "preset-note" and preset:
            preset.note = value
        self.studio.save()

    def _type(self, text: str) -> None:
        if not self.typing:
            return
        self._text_set(self.typing, self._text_get(self.typing) + text)

    def _type_back(self) -> None:
        if not self.typing:
            return
        self._text_set(self.typing, self._text_get(self.typing)[:-1])

    def _preset(self):
        presets = self.studio.profile.presets
        if not presets:
            return None
        return presets[self.preset_index % len(presets)]

    def _blit(self, screen, size, text, color, pos) -> None:
        screen.blit(self.fonts.render(size, text, color), pos)

    def _bind_pad(self) -> None:
        try:
            import pygame._sdl2.controller as sdlpad
            from pygame._sdl2.controller import Controller
        except ImportError:
            return
        sdlpad.init()
        pygame.joystick.init()
        chosen = None
        for index in range(pygame.joystick.get_count()):
            joy = pygame.joystick.Joystick(index)
            pad = None
            if sdlpad.is_controller(index):
                try:
                    pad = Controller(index)
                except pygame.error:
                    pad = None
            if pad is None:
                try:
                    pad = Controller.from_joystick(joy)
                except pygame.error:
                    continue
            name = f"{pad.name or ''} {joy.get_name() or ''}".strip()
            mapping = pad.get_mapping() or {}
            if "a" not in mapping and "steam deck" in name.lower():
                try:
                    pad.set_mapping({
                        "a": "b0", "b": "b1", "x": "b2", "y": "b3",
                        "back": "b6", "guide": "b8", "start": "b7",
                        "leftstick": "b9", "rightstick": "b10",
                        "leftshoulder": "b4", "rightshoulder": "b5",
                        "dpup": "h0.1", "dpdown": "h0.4", "dpleft": "h0.8", "dpright": "h0.2",
                        "leftx": "a0", "lefty": "a1", "rightx": "a3", "righty": "a4",
                        "lefttrigger": "a2", "righttrigger": "a5",
                    })
                except pygame.error:
                    pass
            chosen = pad
            self._pad_name = name or "게임패드"
            if "steam deck" in name.lower():
                break
        self._pad = chosen

    def _poll_pad(self) -> None:
        if not self._pad:
            return
        names = {
            "a": pygame.CONTROLLER_BUTTON_A,
            "b": pygame.CONTROLLER_BUTTON_B,
            "x": pygame.CONTROLLER_BUTTON_X,
            "y": pygame.CONTROLLER_BUTTON_Y,
            "back": pygame.CONTROLLER_BUTTON_BACK,
            "start": pygame.CONTROLLER_BUTTON_START,
            "leftshoulder": pygame.CONTROLLER_BUTTON_LEFTSHOULDER,
            "rightshoulder": pygame.CONTROLLER_BUTTON_RIGHTSHOULDER,
            "leftstick": pygame.CONTROLLER_BUTTON_LEFTSTICK,
            "rightstick": pygame.CONTROLLER_BUTTON_RIGHTSTICK,
            "up": pygame.CONTROLLER_BUTTON_DPAD_UP,
            "down": pygame.CONTROLLER_BUTTON_DPAD_DOWN,
            "left": pygame.CONTROLLER_BUTTON_DPAD_LEFT,
            "right": pygame.CONTROLLER_BUTTON_DPAD_RIGHT,
        }
        edges = {}
        for name, code in names.items():
            now = bool(self._pad.get_button(code))
            edges[name] = now and not self._buttons.get(name, False)
            self._buttons[name] = now
        if self.typing:
            if edges["b"]:
                self._type_back()
            if edges["y"] or edges["start"]:
                self.confirm()
            if edges["back"]:
                self._text_set(self.typing, self.typing_original)
                self.typing = ""
            return
        if edges["leftshoulder"]:
            self._l1_used = False
        if edges["a"]:
            if self._held("leftshoulder"):
                self._l1_used = True
                self.studio.together(True)
            else:
                self.studio.record_toggle()
        if edges["b"]:
            if self._held("leftshoulder"):
                self._l1_used = True
                self.studio.together(False)
            else:
                self.studio.stop_selected()
        if edges["x"]:
            self.studio.select_step(-1)
        if edges["rightshoulder"]:
            self.studio.select_step(1)
        if edges["y"]:
            self.confirm()
        if edges["up"]:
            self.move_row(-1)
        if edges["down"]:
            self.move_row(1)
        if edges["left"]:
            self.adjust(-1)
        if edges["right"]:
            self.adjust(1)
        if edges["start"]:
            self._cycle_tab(1)
        if edges["back"]:
            self._practice()
        was_down = self._l1_down
        self._l1_down = self._buttons.get("leftshoulder", False)
        if was_down and not self._l1_down and not self._l1_used:
            self.studio.home()
        if edges["leftstick"]:
            device = self.studio.selected()
            if device and device.kind == KIND_RONIN:
                self.studio.remember_home()
            elif device and device.kind == KIND_GOPRO:
                self.toggle_preview()
        if edges["rightstick"]:
            self.studio.photo()

    def _held(self, name: str) -> bool:
        return bool(self._buttons.get(name))

    def _axes(self) -> tuple[float, float]:
        if not self._pad:
            return 0.0, 0.0
        return self._axis(pygame.CONTROLLER_AXIS_LEFTX), self._axis(pygame.CONTROLLER_AXIS_LEFTY)

    def _axis(self, code: int) -> float:
        if not self._pad:
            return 0.0
        raw = self._pad.get_axis(code)
        if code in (pygame.CONTROLLER_AXIS_TRIGGERLEFT, pygame.CONTROLLER_AXIS_TRIGGERRIGHT):
            return max(0.0, min(1.0, raw / 32767))
        return max(-1.0, min(1.0, raw / 32767))


def on_steam_deck() -> bool:
    if os.environ.get("SteamDeck") == "1":
        return True
    try:
        name = open("/sys/devices/virtual/dmi/id/product_name", encoding="utf-8").read().lower()
    except OSError:
        return False
    return "jupiter" in name or "galileo" in name


def main() -> None:
    경로.ensure()
    pygame.init()
    pygame.display.set_caption("로닌 컨트롤")
    windowed = os.environ.get("RONIN_DECK_WINDOW") == "1" or not on_steam_deck()
    flags = 0 if windowed else pygame.FULLSCREEN
    screen = pygame.display.set_mode((1280, 800), flags)
    app = DeckApp()
    clock = pygame.time.Clock()
    running = True
    try:
        while running:
            dt = clock.tick(60) / 1000
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    running = False
                else:
                    app.event(event)
            app.update(dt)
            app.draw(screen)
            pygame.display.flip()
    finally:
        app.shutdown()
        pygame.quit()
