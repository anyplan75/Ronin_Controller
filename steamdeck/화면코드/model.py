"""애플 앱과 같은 장치 목록과 프로필입니다. 비밀번호는 넣지 않습니다.

저장 열쇠 이름은 [로닌컨트롤]_profile 입니다.
다른 프로젝트 자료와 섞이지 않게 이 말머리를 유지합니다.
"""

from __future__ import annotations

import json
import random
import uuid
from dataclasses import dataclass, field
from pathlib import Path

KIND_RONIN = "ronin"
KIND_GOPRO = "gopro"
KIND_ACTION5 = "goproAction5"
KIND_OSMO = "osmoAction"
KIND_NOAPI = "osmoNoAPI"

KIND_TITLES = {
    KIND_RONIN: "로닌 기판 · CAN",
    KIND_GOPRO: "고프로 · 와이파이",
    KIND_ACTION5: "오즈모 액션 5 프로 · 블루투스",
    KIND_OSMO: "오즈모 액션 · 블루투스",
    KIND_NOAPI: "제어 API 없음",
}

# 장치 추가 메뉴. 애플 앱과 같은 다섯 줄입니다. 포켓·모바일·나노는 없습니다.
PRODUCTS = [
    ("ronin", "로닌 기판 · CAN", KIND_RONIN, "unknown"),
    ("goproWifi", "고프로 · 와이파이", KIND_GOPRO, "unknown"),
    ("action5Bluetooth", "오즈모 액션 5 프로 · 블루투스", KIND_ACTION5, "unknown"),
    ("osmoActionBluetooth", "오즈모 액션 · 블루투스", KIND_OSMO, "action4"),
    ("osmo360Bluetooth", "오즈모 360 · 블루투스", KIND_OSMO, "osmo360"),
]

OSMO_TITLES = {
    "action4": "오즈모 액션 4",
    "action5Pro": "오즈모 액션 5 프로",
    "action6": "오즈모 액션 6",
    "osmo360": "오즈모 360",
    "pocket": "오즈모 포켓",
    "mobile": "오즈모 모바일",
    "nano": "오즈모 나노",
    "unknown": "아직 모름",
}

OSMO_DEVICE_IDS = {
    "action4": 0xFF330000,
    "action5Pro": 0xFF440000,
    "action6": 0xFF550000,
    "osmo360": 0xFF660000,
}

ACTION_MODELS = ["action4", "action6"]
NOAPI_MODELS = ["pocket", "mobile", "nano", "unknown"]

ACTION_MODES = [
    (0x00, "슬로 모션"),
    (0x01, "비디오"),
    (0x02, "타임랩스"),
    (0x05, "사진"),
    (0x0A, "하이퍼랩스"),
    (0x1A, "라이브 스트림"),
    (0x23, "UVC 라이브"),
    (0x28, "슈퍼나이트"),
    (0x34, "피사체 추적"),
]
OSMO360_MODES = [
    (0x38, "360 영상"),
    (0x3A, "360 하이퍼랩스"),
    (0x3C, "셀피"),
    (0x3F, "360 사진"),
    (0x41, "부스트 영상"),
    (0x43, "보텍스"),
    (0x44, "360 슈퍼나이트"),
    (0x4A, "한 렌즈 슈퍼나이트"),
]

SHOTS = [
    "front", "wide", "tight", "verse", "chorus", "hero", "high", "hands",
    "reveal", "drop", "profile-l", "profile-r", "qtr-l", "qtr-r",
    "whip-l", "whip-r", "drift-l", "drift-r", "dutch-l", "dutch-r",
    "level", "sway", "push", "pull", "crash", "snap-wide", "snap-tight",
]
SHOT_TITLES = {
    "front": "정면", "wide": "와이드", "tight": "타이트", "verse": "벌스",
    "chorus": "코러스", "hero": "히어로", "high": "하이", "hands": "손",
    "reveal": "리빌", "drop": "드롭", "profile-l": "옆 왼쪽", "profile-r": "옆 오른쪽",
    "qtr-l": "3/4 왼쪽", "qtr-r": "3/4 오른쪽", "whip-l": "휩 왼쪽", "whip-r": "휩 오른쪽",
    "drift-l": "드리프트 왼쪽", "drift-r": "드리프트 오른쪽",
    "dutch-l": "더치 왼쪽", "dutch-r": "더치 오른쪽", "level": "수평",
    "sway": "스웨이", "push": "푸시", "pull": "풀", "crash": "크래시",
    "snap-wide": "줌 와이드", "snap-tight": "줌 타이트",
}

# Open GoPro 에 공개된 설정 번호만 넣었습니다. 애플 앱의 표와 같습니다.
GOPRO_SETTINGS = [
    (2, "영상 해상도", [(1, "4K"), (9, "1080p"), (4, "2.7K"), (12, "720p"), (7, "1440"), (18, "4K 4:3"), (24, "5K"), (25, "5K 4:3"), (100, "5.3K"), (27, "5.3K 4:3"), (31, "8K"), (6, "2.7K 4:3"), (37, "4K 1:1"), (36, "4K 21:9"), (109, "4K 9:16"), (110, "1080 9:16")]),
    (3, "초당 프레임", [(10, "24"), (9, "25"), (8, "30"), (6, "50"), (5, "60"), (2, "100"), (1, "120"), (13, "200"), (0, "240"), (3, "90"), (17, "300"), (16, "360"), (15, "400")]),
    (121, "영상 렌즈", [(0, "와이드"), (2, "내로우"), (3, "슈퍼뷰"), (4, "리니어"), (7, "맥스 슈퍼뷰"), (8, "리니어 + 수평"), (9, "하이퍼뷰"), (10, "리니어 호라이즌 락"), (11, "맥스 하이퍼뷰"), (12, "울트라 슈퍼뷰"), (13, "울트라 와이드"), (14, "울트라 리니어"), (104, "울트라 하이퍼뷰")]),
    (135, "하이퍼스무스", [(0, "끄기"), (1, "낮음"), (2, "높음"), (3, "부스트"), (4, "자동 부스트"), (100, "스탠다드")]),
    (108, "영상 화면비", [(0, "4:3"), (1, "16:9"), (3, "8:7"), (4, "9:16"), (5, "21:9"), (6, "1:1")]),
    (182, "영상 비트레이트", [(0, "스탠다드"), (1, "높음"), (2, "최대")]),
    (150, "영상 수평 유지", [(0, "끄기"), (2, "잠금")]),
    (173, "영상 성능 모드", [(0, "최대 성능"), (1, "배터리 연장"), (2, "삼각대·고정")]),
    (184, "색 프로파일", [(0, "스탠다드"), (1, "HDR"), (2, "로그"), (101, "HLG HDR")]),
    (83, "GPS", [(0, "끄기"), (1, "켜기")]),
    (167, "하인드사이트", [(4, "끄기"), (2, "15초"), (3, "30초")]),
    (175, "컨트롤 모드", [(0, "이지"), (1, "프로")]),
    (194, "렌즈 구성", [(0, "한 렌즈"), (1, "360")]),
]

PROFILE_KEY = "[로닌컨트롤]_profile"
MAX_DEVICES = 8
ROOM_W = 14.0
ROOM_L = 18.0
ROOM_H = 6.5
FIELD_DEGREES = 90.0

STORAGE_NAME = "[로닌컨트롤]_profile.json"


def shot_title(name: str) -> str:
    return SHOT_TITLES.get(name, name)


def uses_http(kind: str) -> bool:
    return kind in (KIND_RONIN, KIND_GOPRO, KIND_ACTION5)


def is_gopro_family(kind: str) -> bool:
    return kind in (KIND_GOPRO, KIND_ACTION5)


def supports_live_view(kind: str) -> bool:
    """고프로 와이파이만 미리보기 그림을 줍니다. C3 중계와 오즈모, 로닌은 주지 않습니다."""
    return kind == KIND_GOPRO


def default_port(kind: str) -> int:
    if kind in (KIND_RONIN, KIND_ACTION5):
        return 80
    if kind == KIND_GOPRO:
        return 8080
    return 0


def default_host(kind: str) -> str:
    if kind == KIND_GOPRO:
        return "10.5.5.9"
    return ""


def link_label(kind: str, osmo_model: str) -> str:
    if kind == KIND_OSMO and osmo_model == "osmo360":
        return "오즈모 360 · 블루투스"
    return KIND_TITLES.get(kind, kind)


def osmo_supports_rsdk(model: str) -> bool:
    return model in OSMO_DEVICE_IDS


def osmo_models_for(kind: str, model: str) -> list[str]:
    if kind == KIND_OSMO:
        if model == "osmo360":
            return ["osmo360"]
        if model == "action5Pro":
            return ["action5Pro", *ACTION_MODELS]
        return list(ACTION_MODELS)
    if kind == KIND_NOAPI:
        return list(NOAPI_MODELS)
    return []


def writable_modes(model: str) -> list[tuple[int, str]]:
    if model == "osmo360":
        return ACTION_MODES + OSMO360_MODES
    return list(ACTION_MODES)


def mode_name(value: int) -> str:
    for code, title in ACTION_MODES + OSMO360_MODES:
        if code == value:
            return title
    return f"표에 없는 모드 {value}"


def osmo_status_name(value: int) -> str:
    names = {0: "화면 꺼짐", 1: "라이브 (녹화 전 포함)", 2: "재생", 3: "촬영 중", 5: "프리 레코드"}
    return names.get(value, f"표에 없는 번호 {value}")


def resolution_name(value: int) -> str:
    names = {
        10: "1080p", 16: "4K 16:9", 45: "2.7K 16:9", 66: "1080p 9:16",
        67: "2.7K 9:16", 95: "2.7K 4:3", 103: "4K 4:3", 109: "4K 9:16",
        4: "사진 L 또는 울트라 와이드", 3: "사진 M 또는 와이드", 2: "사진 스탠다드 12MP (360)",
    }
    return names.get(value, f"표에 없는 번호 {value}")


def fps_name(value: int) -> str:
    names = {1: "24", 2: "25", 3: "30", 4: "48", 5: "50", 6: "60", 7: "120", 8: "240", 10: "100", 19: "200"}
    return names.get(value, f"표에 없는 번호 {value}")


def record_mark(kind: str, ronin: dict | None, gopro: dict | None, osmo_status: int | None) -> str | None:
    """장치가 알려 준 녹화만 적습니다. 모르는 상태는 꾸미지 않습니다."""
    if kind == KIND_RONIN:
        if not ronin:
            return None
        if ronin.get("sony_recording") is True:
            return "녹화"
        if ronin.get("cam_recording") is True:
            return "녹화 명령"
        return None
    if is_gopro_family(kind):
        if gopro and gopro.get("encoding") is True:
            return "녹화"
        return None
    if kind == KIND_OSMO:
        if osmo_status == 3:
            return "촬영 중"
        if osmo_status == 5:
            return "프리 레코드"
        return None
    return None


def fresh_gopro_settings() -> list[dict]:
    return [
        {"settingId": spec[0], "option": spec[2][0][0], "enabled": False}
        for spec in GOPRO_SETTINGS
    ]


def gopro_option_label(setting_id: int, option: int) -> str:
    for spec in GOPRO_SETTINGS:
        if spec[0] == setting_id:
            for value, label in spec[2]:
                if value == option:
                    return label
            return str(option)
    return str(option)


@dataclass
class Device:
    id: str
    name: str
    kind: str
    osmo_model: str
    host: str
    port: int
    ble_identifier: str
    enabled: bool = True
    paired_once: bool = False

    def label(self) -> str:
        return link_label(self.kind, self.osmo_model)

    def base_url(self) -> str:
        host = self.host.strip()
        if not host or self.port <= 0:
            return ""
        return f"http://{host}:{self.port}"

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "kind": self.kind,
            "osmoModel": self.osmo_model,
            "host": self.host,
            "port": self.port,
            "bleIdentifier": self.ble_identifier,
            "enabled": self.enabled,
            "pairedOnce": self.paired_once,
        }

    @staticmethod
    def from_dict(raw: dict) -> "Device":
        return Device(
            id=str(raw["id"]),
            name=str(raw.get("name") or ""),
            kind=str(raw.get("kind") or KIND_RONIN),
            osmo_model=str(raw.get("osmoModel") or "unknown"),
            host=str(raw.get("host") or ""),
            port=int(raw.get("port") or 0),
            ble_identifier=str(raw.get("bleIdentifier") or ""),
            enabled=bool(raw.get("enabled", True)),
            paired_once=bool(raw.get("pairedOnce", False)),
        )


@dataclass
class Spot:
    device_id: str
    x: float
    y: float
    z: float
    aim_yaw: float
    home_yaw: float = 0.0
    home_pitch: float = 0.0

    def to_dict(self) -> dict:
        return {
            "deviceId": self.device_id,
            "x": self.x,
            "y": self.y,
            "z": self.z,
            "aimYaw": self.aim_yaw,
            "homeYaw": self.home_yaw,
            "homePitch": self.home_pitch,
        }

    @staticmethod
    def from_dict(raw: dict) -> "Spot":
        return Spot(
            device_id=str(raw["deviceId"]),
            x=float(raw["x"]),
            y=float(raw["y"]),
            z=float(raw["z"]),
            aim_yaw=float(raw["aimYaw"]),
            home_yaw=float(raw.get("homeYaw") or 0),
            home_pitch=float(raw.get("homePitch") or 0),
        )


def place_spot(index: int, count: int) -> tuple[float, float, float]:
    span = min(ROOM_W * 0.62, max(count - 1, 1) * 1.6)
    t = 0.5 if count <= 1 else index / max(count - 1, 1)
    x = -span / 2 + span * t
    return x, 1.6, 1.6


def clamp_stage(x=None, y=None, z=None, aim=None, home_yaw=None, home_pitch=None):
    if x is not None:
        x = min(ROOM_W * 0.48, max(-ROOM_W * 0.48, x))
    if y is not None:
        y = min(ROOM_L - 0.4, max(0.4, y))
    if z is not None:
        z = min(ROOM_H - 0.3, max(0.2, z))
    if aim is not None:
        aim = min(180.0, max(-180.0, aim))
    if home_yaw is not None:
        home_yaw = min(180.0, max(-180.0, home_yaw))
    if home_pitch is not None:
        home_pitch = min(180.0, max(-180.0, home_pitch))
    return x, y, z, aim, home_yaw, home_pitch


@dataclass
class Preset:
    id: str
    name: str
    note: str
    device_ids: list[str]
    ronin: dict
    gopro: dict
    osmo: dict
    connections: list[dict] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "note": self.note,
            "deviceIds": list(self.device_ids),
            "ronin": self.ronin,
            "gopro": self.gopro,
            "osmo": self.osmo,
            "connections": self.connections,
        }

    @staticmethod
    def from_dict(raw: dict) -> "Preset":
        gopro = raw.get("gopro") or {}
        settings = gopro.get("settings") or fresh_gopro_settings()
        known = {item["settingId"] for item in settings}
        for extra in fresh_gopro_settings():
            if extra["settingId"] not in known:
                settings.append(extra)
        return Preset(
            id=str(raw["id"]),
            name=str(raw.get("name") or ""),
            note=str(raw.get("note") or ""),
            device_ids=[str(item) for item in raw.get("deviceIds") or []],
            ronin=dict(raw.get("ronin") or {}),
            gopro={
                "settings": settings,
                "loadPresetId": gopro.get("loadPresetId"),
                "digitalZoomPercent": gopro.get("digitalZoomPercent"),
            },
            osmo={"mode": (raw.get("osmo") or {}).get("mode")},
            connections=list(raw.get("connections") or []),
        )


def new_ronin_look() -> dict:
    return {
        "shot": "wide",
        "timeScale": 1,
        "sendMove": False,
        "yaw": 0,
        "roll": 0,
        "pitch": 0,
        "seconds": 1.5,
        "absolute": True,
    }


@dataclass
class Profile:
    version: int = 1
    devices: list[Device] = field(default_factory=list)
    presets: list[Preset] = field(default_factory=list)
    group_ids: list[str] = field(default_factory=list)
    lead_ms: int = 300
    practice: bool = False
    sender_id: int = 1
    sender_mac: list[int] = field(default_factory=lambda: [0, 0, 0, 0, 0, 0])
    spots: list[Spot] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "version": self.version,
            "devices": [item.to_dict() for item in self.devices],
            "presets": [item.to_dict() for item in self.presets],
            "groupIds": list(self.group_ids),
            "leadMs": self.lead_ms,
            "practice": self.practice,
            "senderId": self.sender_id,
            "senderMac": list(self.sender_mac),
            "stageSpots": [item.to_dict() for item in self.spots],
        }

    @staticmethod
    def make_new() -> "Profile":
        return Profile(
            sender_id=random.randint(1, 0x7FFFFFFF),
            sender_mac=[random.randint(0, 255) for _ in range(6)],
        )

    @staticmethod
    def from_dict(raw: dict) -> "Profile":
        return Profile(
            version=int(raw.get("version") or 1),
            devices=[Device.from_dict(item) for item in raw.get("devices") or []],
            presets=[Preset.from_dict(item) for item in raw.get("presets") or []],
            group_ids=[str(item) for item in raw.get("groupIds") or []],
            lead_ms=int(raw.get("leadMs") or 0),
            practice=bool(raw.get("practice", False)),
            sender_id=int(raw.get("senderId") or 1),
            sender_mac=[int(item) for item in (raw.get("senderMac") or [0, 0, 0, 0, 0, 0])],
            spots=[Spot.from_dict(item) for item in raw.get("stageSpots") or []],
        )


def profile_path(explicit: str | None = None) -> Path:
    if explicit:
        return Path(explicit)
    import os
    base = os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local" / "share"))
    folder = Path(base) / "ronin-deck"
    folder.mkdir(parents=True, exist_ok=True)
    return folder / STORAGE_NAME


def load_profile(path: Path) -> Profile:
    if not path.exists():
        return Profile.make_new()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return Profile.make_new()
    try:
        return Profile.from_dict(raw)
    except (KeyError, TypeError, ValueError):
        return Profile.make_new()


def save_profile(path: Path, profile: Profile) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(profile.to_dict(), ensure_ascii=False, indent=2), encoding="utf-8")


def new_id() -> str:
    return str(uuid.uuid4())
