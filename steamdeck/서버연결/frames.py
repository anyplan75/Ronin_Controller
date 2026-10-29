"""DJI R SDK 프레임입니다. 애플 앱과 같은 검사합을 씁니다.

시작값은 0x3AA3 이고, 공식 모드 전환 예시와 같아야 합니다.
"""

from __future__ import annotations

KNOWN_MODE_SWITCH = "aa1b000100000000050057ee1d04000033ff0a01473936f4fae1d0"


def _table(poly: int, bits: int) -> list[int]:
    mask = (1 << bits) - 1
    table = []
    for index in range(256):
        crc = index
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ poly
            else:
                crc >>= 1
        table.append(crc & mask)
    return table


_CRC16 = _table(0xA001, 16)
_CRC32 = _table(0xEDB88320, 32)


def crc16(data: bytes) -> int:
    crc = 0x3AA3
    for byte in data:
        crc = ((crc >> 8) ^ _CRC16[(crc ^ byte) & 0xFF]) & 0xFFFF
    return crc


def crc32(data: bytes) -> int:
    crc = 0x3AA3
    for byte in data:
        crc = ((crc >> 8) ^ _CRC32[(crc ^ byte) & 0xFF]) & 0xFFFFFFFF
    return crc


def build(cmd_set: int, cmd_id: int, cmd_type: int, seq: int, payload: bytes) -> bytes:
    total = 12 + 2 + len(payload) + 4
    pkt = bytearray(total)
    pkt[0] = 0xAA
    pkt[1] = total & 0xFF
    pkt[2] = (total >> 8) & 0xFF
    pkt[3] = cmd_type & 0xFF
    pkt[8] = seq & 0xFF
    pkt[9] = (seq >> 8) & 0xFF
    header = crc16(bytes(pkt[:10]))
    pkt[10] = header & 0xFF
    pkt[11] = (header >> 8) & 0xFF
    pkt[12] = cmd_set & 0xFF
    pkt[13] = cmd_id & 0xFF
    pkt[14:14 + len(payload)] = payload
    tail = crc32(bytes(pkt[: total - 4]))
    pkt[total - 4] = tail & 0xFF
    pkt[total - 3] = (tail >> 8) & 0xFF
    pkt[total - 2] = (tail >> 16) & 0xFF
    pkt[total - 1] = (tail >> 24) & 0xFF
    return bytes(pkt)


def parse(raw: bytes) -> dict | None:
    if len(raw) < 16 or raw[0] != 0xAA:
        return None
    length = raw[1] | ((raw[2] & 0x03) << 8)
    if length != len(raw) or length > 256:
        return None
    if crc16(raw[:10]) != (raw[10] | (raw[11] << 8)):
        return None
    expect = crc32(raw[: length - 4])
    got = raw[length - 4] | (raw[length - 3] << 8) | (raw[length - 2] << 16) | (raw[length - 1] << 24)
    if expect != got:
        return None
    return {
        "cmd_set": raw[12],
        "cmd_id": raw[13],
        "cmd_type": raw[3],
        "seq": raw[8] | (raw[9] << 8),
        "payload": raw[14:length - 4],
        "is_response": (raw[3] & 0x20) != 0,
    }


def self_check() -> bool:
    payload = bytes([0x00, 0x00, 0x33, 0xFF, 0x0A, 0x01, 0x47, 0x39, 0x36])
    frame = build(0x1D, 0x04, 0x01, 5, payload)
    return frame.hex() == KNOWN_MODE_SWITCH and parse(frame) is not None


class FrameBuffer:
    def __init__(self) -> None:
        self.buf = bytearray()

    def append(self, data: bytes) -> list[dict]:
        self.buf.extend(data)
        frames = []
        while True:
            try:
                sof = self.buf.index(0xAA)
            except ValueError:
                self.buf.clear()
                break
            if sof:
                del self.buf[:sof]
            if len(self.buf) < 3:
                break
            length = self.buf[1] | ((self.buf[2] & 0x03) << 8)
            if length < 16 or length > 256:
                del self.buf[0]
                continue
            if len(self.buf) < length:
                break
            raw = bytes(self.buf[:length])
            del self.buf[:length]
            parsed = parse(raw)
            if parsed:
                frames.append(parsed)
        return frames
