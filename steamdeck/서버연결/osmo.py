"""오즈모 액션·360 블루투스입니다. 서비스 FFF0, 알림 FFF4, 쓰기 FFF5 입니다.

액션 5 프로는 여기가 아닙니다. 그 카메라는 C3 중계 기판의 HTTP 로만 붙습니다.
포켓·모바일·나노는 명령을 만들지 않습니다.
비밀번호는 이 통로에 없습니다.
"""

from __future__ import annotations

import random
import threading
import time

from 서버연결.frames import FrameBuffer, build, self_check
from 화면코드.model import OSMO_DEVICE_IDS, osmo_supports_rsdk, writable_modes

FFF0 = "0000fff0-0000-1000-8000-00805f9b34fb"
FFF4 = "0000fff4-0000-1000-8000-00805f9b34fb"
FFF5 = "0000fff5-0000-1000-8000-00805f9b34fb"


def le32(value: int) -> bytes:
    value &= 0xFFFFFFFF
    return bytes((value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF, (value >> 24) & 0xFF))


def mode_payload(device_id: int, mode: int) -> bytes:
    return le32(device_id) + bytes((mode & 0xFF, 0x01, 0x47, 0x39, 0x36))


def record_payload(device_id: int, start: bool) -> bytes:
    return le32(device_id) + bytes((0x00 if start else 0x01, 0, 0, 0, 0))


def connection_payload(sender_id: int, mac: list[int], verify_mode: int, verify: int) -> bytes:
    payload = bytearray(le32(sender_id))
    payload.append(min(6, len(mac)))
    mac16 = bytearray(16)
    for index, byte in enumerate(mac[:6]):
        mac16[index] = int(byte) & 0xFF
    payload.extend(mac16)
    payload.extend(le32(0))
    payload.append(0)
    payload.append(verify_mode & 0xFF)
    payload.append(verify & 0xFF)
    payload.append((verify >> 8) & 0xFF)
    payload.extend((0, 0, 0, 0))
    return bytes(payload)


def frames_ok() -> bool:
    return self_check()


class OsmoRadio:
    """한 번 붙인 세션을 유지합니다. 명령마다 끊지 않습니다."""

    def __init__(self) -> None:
        self.live: dict[str, dict] = {}
        self.seen: list[dict] = []
        self.scanning = False
        self.note = "블루투스를 아직 확인하지 않았습니다."
        self._links: dict[str, dict] = {}
        self._lock = threading.Lock()
        self._loop = None
        self._thread = None

    def snapshot(self, device_id: str) -> dict:
        with self._lock:
            return dict(self.live.get(device_id) or {})

    def _ensure_loop(self):
        if self._loop is not None:
            return self._loop
        import asyncio

        loop = asyncio.new_event_loop()

        def run():
            asyncio.set_event_loop(loop)
            loop.run_forever()

        thread = threading.Thread(target=run, name="osmo-ble", daemon=True)
        thread.start()
        self._loop = loop
        self._thread = thread
        return loop

    def _run(self, coro, timeout: float):
        import asyncio

        loop = self._ensure_loop()
        future = asyncio.run_coroutine_threadsafe(coro, loop)
        return future.result(timeout)

    def scan(self, seconds: float = 6) -> str:
        try:
            from bleak import BleakScanner
        except ImportError:
            self.note = "블루투스 꾸러미 bleak 이 없습니다. 설치 안내의 pip 줄을 먼저 실행하세요."
            return self.note
        self.scanning = True
        self.note = "카메라를 찾는 중입니다."

        async def work():
            devices = await BleakScanner.discover(timeout=seconds)
            found = []
            for item in devices:
                name = item.name or ""
                if not name:
                    continue
                found.append({"identifier": item.address, "name": name, "rssi": getattr(item, "rssi", 0) or 0})
            return found

        try:
            found = self._run(work(), seconds + 4)
        except Exception as error:
            self.scanning = False
            self.note = f"찾기에 실패했습니다. {error}"
            return self.note
        self.seen = found
        self.scanning = False
        self.note = f"찾은 기기 {len(found)}개. 오즈모 이름을 고르세요."
        return self.note

    def pair(self, device, sender_id: int, mac: list[int], verify_mode: int) -> str:
        if not osmo_supports_rsdk(device.osmo_model):
            return f"{device.name}: 이 기종은 공개 R SDK 에 없습니다."
        camera_id = OSMO_DEVICE_IDS.get(device.osmo_model)
        if camera_id is None:
            return f"{device.name}: 녹화 명령을 보낼 기기 번호가 없습니다."
        if not device.ble_identifier:
            return f"{device.name}: 먼저 카메라를 찾으세요."
        verify = random.randint(0, 9999)
        phase = "카메라 확인 창을 기다리는 중. 숫자 %d" % verify if verify_mode == 1 else "저장된 페어링으로 연결 중"
        self._publish(device.id, phase=phase, last_error="", ready=False)
        try:
            text = self._run(self._handshake(device, sender_id, mac, verify_mode, verify, camera_id), 40)
        except Exception as error:
            self._publish(device.id, phase="연결 실패", last_error=str(error), ready=False)
            return f"{device.name}: {error}"
        return f"{device.name}: {text}"

    def record(self, device, start: bool) -> str:
        camera_id = OSMO_DEVICE_IDS.get(device.osmo_model)
        if camera_id is None:
            return f"{device.name}: 녹화 명령을 보낼 기기 번호가 없습니다."
        label = "촬영 시작" if start else "촬영 중지"
        return self._command(device, 0x1D, 0x03, 0x01, record_payload(camera_id, start), label)

    def set_mode(self, device, mode: int) -> str:
        camera_id = OSMO_DEVICE_IDS.get(device.osmo_model)
        if camera_id is None:
            return "모드를 보낼 기기 번호가 없습니다."
        allowed = {item[0] for item in writable_modes(device.osmo_model)}
        if mode not in allowed:
            return "이 기종 문서에 없는 모드입니다."
        return self._command(device, 0x1D, 0x04, 0x01, mode_payload(camera_id, mode), "모드")

    def _command(self, device, cmd_set, cmd_id, cmd_type, payload: bytes, label: str) -> str:
        link = self._links.get(device.id)
        if not link or not link.get("ready"):
            return f"{device.name}: 먼저 블루투스 연결을 끝내세요."
        try:
            text = self._run(self._exchange(device.id, cmd_set, cmd_id, cmd_type, payload, label), 8)
        except Exception as error:
            return f"{device.name}: {error}"
        return f"{device.name}: {text}"

    async def _exchange(self, device_id, cmd_set, cmd_id, cmd_type, payload, label):
        link = self._links[device_id]
        seq = link["seq"]
        link["seq"] = (seq + 1) & 0xFFFF
        frame = build(cmd_set, cmd_id, cmd_type, seq, payload)
        await _write(link["client"], frame)
        reply = await self._wait(link, 4, lambda item: item["cmd_set"] == cmd_set and item["cmd_id"] == cmd_id and item["is_response"])
        code = reply["payload"][0] if reply["payload"] else 0xFF
        if code != 0:
            raise RuntimeError(f"{label} 거절 코드 {code}")
        return f"{label} 수락"

    async def _handshake(self, device, sender_id, mac, verify_mode, verify, camera_id):
        del camera_id
        client = await self._client(device)
        link = self._links[device.id]
        payload = connection_payload(sender_id, mac, verify_mode, verify)
        seq = link["seq"]
        link["seq"] = (seq + 1) & 0xFFFF
        frame = build(0x00, 0x19, 0x02, seq, payload)
        await _write(client, frame)
        deadline = time.monotonic() + 30
        approved = None
        while time.monotonic() < deadline:
            incoming = await self._wait(link, max(0.2, deadline - time.monotonic()), lambda _item: True)
            if incoming["cmd_set"] == 0x00 and incoming["cmd_id"] == 0x19 and not incoming["is_response"] and len(incoming["payload"]) >= 29:
                mode = incoming["payload"][26]
                data = incoming["payload"][27] | (incoming["payload"][28] << 8)
                if mode == 2:
                    if data != 0:
                        raise RuntimeError("카메라가 연결을 거절했습니다.")
                    approved = incoming
                    break
        if approved is None:
            raise RuntimeError("카메라의 연결 허용이 오지 않았습니다.")
        ack = bytearray(le32(sender_id))
        ack.append(0)
        ack.extend((0, 0, 0, 0))
        await _write(client, build(0x00, 0x19, 0x20, approved["seq"], bytes(ack)))
        link["ready"] = True
        self._publish(device.id, ready=True, phase="프로토콜 연결됨", last_error="")
        vseq = link["seq"]
        link["seq"] = (vseq + 1) & 0xFFFF
        await _write(client, build(0x00, 0x00, 0x02, vseq, b""))
        sub = link["seq"]
        link["seq"] = (sub + 1) & 0xFFFF
        await _write(client, build(0x1D, 0x05, 0x00, sub, bytes((3, 20, 0, 0, 0, 0))))
        return "프로토콜 연결됨"

    async def _client(self, device):
        from bleak import BleakClient

        link = self._links.get(device.id)
        if link and link.get("client") is not None:
            client = link["client"]
            if getattr(client, "is_connected", False):
                return client
        client = BleakClient(device.ble_identifier)
        await client.connect()
        buffer = FrameBuffer()
        inbox: list[dict] = []
        waiters: list[dict] = []

        def on_notify(_char, data: bytearray):
            for frame in buffer.append(bytes(data)):
                self._apply(device.id, frame)
                matched = False
                for waiter in list(waiters):
                    if waiter["match"](frame):
                        waiters.remove(waiter)
                        waiter["future"].set_result(frame)
                        matched = True
                        break
                if not matched:
                    inbox.append(frame)
                    if len(inbox) > 30:
                        del inbox[0]

        await client.start_notify(FFF4, on_notify)
        self._links[device.id] = {
            "client": client,
            "ready": False,
            "seq": 1,
            "inbox": inbox,
            "waiters": waiters,
        }
        return client

    async def _wait(self, link, timeout, match):
        import asyncio

        for index, frame in enumerate(list(link["inbox"])):
            if match(frame):
                del link["inbox"][index]
                return frame
        loop = asyncio.get_running_loop()
        future = loop.create_future()
        waiter = {"match": match, "future": future}
        link["waiters"].append(waiter)
        try:
            return await asyncio.wait_for(future, timeout=max(0.2, timeout))
        except asyncio.TimeoutError:
            if waiter in link["waiters"]:
                link["waiters"].remove(waiter)
            raise RuntimeError("응답 시간이 지났습니다.") from None

    def _apply(self, device_id: str, frame: dict) -> None:
        payload = frame["payload"]
        if frame["cmd_set"] == 0x1D and frame["cmd_id"] == 0x02 and len(payload) >= 5:
            battery = int(payload[37]) if len(payload) > 37 else None
            self._publish(
                device_id,
                mode=int(payload[0]),
                status=int(payload[1]),
                resolution=int(payload[2]),
                fps=int(payload[3]),
                eis=int(payload[4]),
                battery=battery,
            )
        elif frame["cmd_set"] == 0x1D and frame["cmd_id"] == 0x06 and len(payload) >= 3:
            length = min(int(payload[1]), 21)
            if len(payload) >= 2 + length:
                name = bytes(byte for byte in payload[2:2 + length] if byte).decode("utf-8", errors="replace")
                self._publish(device_id, mode_name=name)

    def _publish(self, device_id: str, **changes) -> None:
        with self._lock:
            item = dict(self.live.get(device_id) or {})
            item.update(changes)
            self.live[device_id] = item


async def _write(client, data: bytes) -> None:
    try:
        await client.write_gatt_char(FFF5, data, response=True)
        return
    except Exception:
        pass
    for offset in range(0, len(data), 20):
        await client.write_gatt_char(FFF5, data[offset:offset + 20], response=False)
