"""로닌 기판과 고프로 가족(직접 와이파이, 액션 5 프로 C3 중계)의 HTTP 입니다.

비밀번호가 주소에 들어가면 기록 문장에서는 가립니다.
"""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.parse
import urllib.request

from 화면코드.model import is_gopro_family


class CallError(Exception):
    pass


_PASS = re.compile(r"(pass=)[^&]*", re.IGNORECASE)


def redact(text: str) -> str:
    return _PASS.sub(r"\1***", text)


def build_url(host: str, port: int, path: str, query: dict | None = None) -> str:
    cleaned = (host or "").strip()
    if not cleaned or port <= 0:
        raise CallError("주소가 비어 있습니다.")
    if not path.startswith("/"):
        path = "/" + path
    url = f"http://{cleaned}:{int(port)}{path}"
    if query:
        items = []
        for key in sorted(query):
            value = query[key]
            if value is None:
                continue
            items.append(
                urllib.parse.quote(str(key), safe="")
                + "="
                + urllib.parse.quote(str(value), safe="")
            )
        if items:
            url += "?" + "&".join(items)
    return url


def http_get(host: str, port: int, path: str, query: dict | None = None, timeout: float = 4) -> str:
    url = build_url(host, port, path, query)
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            code = response.status
            body = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise CallError(redact(f"HTTP {error.code} {body.strip()}")) from None
    except urllib.error.URLError as error:
        raise CallError(redact(str(error.reason))) from None
    except TimeoutError:
        raise CallError("시간이 지나 응답이 없습니다.") from None
    if code >= 400:
        raise CallError(redact(f"HTTP {code} {body.strip()}"))
    return body


def parse_gopro_state(text: str) -> dict:
    live = {
        "encoding": None,
        "remaining_video": None,
        "remaining_photos": None,
        "busy": None,
        "sd_remaining": None,
        "settings": {},
        "error": "",
        "relay_ble": "",
    }
    try:
        raw = json.loads(text)
    except json.JSONDecodeError:
        live["error"] = text
        return live
    if not isinstance(raw, dict):
        live["error"] = text
        return live
    if isinstance(raw.get("relay_ble"), str):
        live["relay_ble"] = raw["relay_ble"]
    status = raw.get("status") if isinstance(raw.get("status"), dict) else {}
    settings = raw.get("settings") if isinstance(raw.get("settings"), dict) else {}
    live["encoding"] = _boolish(status.get("10"))
    live["busy"] = _boolish(status.get("8"))
    live["remaining_video"] = _intish(status.get("35"))
    live["remaining_photos"] = _intish(status.get("34"))
    live["sd_remaining"] = _intish(status.get("54"))
    parsed_settings = {}
    for key, value in settings.items():
        setting_id = _intish(key)
        option = _intish(value)
        if setting_id is not None and option is not None:
            parsed_settings[setting_id] = option
    live["settings"] = parsed_settings
    return live


def parse_ronin_status(text: str) -> dict:
    try:
        raw = json.loads(text)
    except json.JSONDecodeError as error:
        raise CallError("기판 상태를 읽지 못했습니다.") from error
    if not isinstance(raw, dict):
        raise CallError("기판 상태를 읽지 못했습니다.")
    return raw


def _intish(value):
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            return None
    return None


def _boolish(value):
    if isinstance(value, bool):
        return value
    number = _intish(value)
    if number is None:
        return None
    return number != 0


def ronin_command(device, path: str, query: dict | None = None, timeout: float = 4) -> str:
    return http_get(device.host, device.port, path, query, timeout)


def gopro_command(device, path: str, query: dict | None = None, timeout: float = 4) -> str:
    if not is_gopro_family(device.kind):
        raise CallError("이 장치는 고프로 통로가 아닙니다.")
    return http_get(device.host, device.port, path, query, timeout)
