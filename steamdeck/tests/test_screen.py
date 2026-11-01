"""화면이 베이지 무대를 그리고, 휠 칸은 없는지 확인합니다."""

import os
import sys
import tempfile
import unittest
from pathlib import Path

os.environ.setdefault("SDL_VIDEODRIVER", "dummy")
os.environ.setdefault("SDL_AUDIODRIVER", "dummy")
os.environ.setdefault("RONIN_DECK_WINDOW", "1")

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pygame

import 경로

경로.ensure()

from 화면코드.app import DeckApp
from 화면코드.model import KIND_GOPRO, KIND_OSMO, KIND_RONIN


def _save_png(surface, path: Path) -> None:
    import struct
    import zlib

    width, height = surface.get_size()
    raw = pygame.image.tobytes(surface, "RGB")
    rows = bytearray()
    stride = width * 3
    for y in range(height):
        rows.append(0)
        rows.extend(raw[y * stride:(y + 1) * stride])

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 6))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


class ScreenTests(unittest.TestCase):
    def test_stage_has_devices_and_no_wheel_wording_only(self):
        pygame.init()
        pygame.display.set_mode((1280, 800))
        with tempfile.TemporaryDirectory() as folder:
            app = DeckApp(str(Path(folder) / "profile.json"))
            try:
                app.studio.profile.practice = True
                app.studio.add_device("ronin")
                app.studio.add_device("goproWifi")
                app.studio.add_device("osmo360Bluetooth")
                ronin = app.studio.profile.devices[0]
                gopro = app.studio.profile.devices[1]
                osmo = app.studio.profile.devices[2]
                self.assertEqual(ronin.kind, KIND_RONIN)
                self.assertEqual(gopro.kind, KIND_GOPRO)
                self.assertEqual(osmo.kind, KIND_OSMO)
                self.assertEqual(osmo.osmo_model, "osmo360")
                app.studio.ronin_live[ronin.id] = {
                    "yaw": 15, "roll": 0, "pitch": -8, "attitude_valid": True,
                    "cam_recording": True, "eth_link": True, "twai": "running",
                    "sony_recording": False,
                }
                app.studio.gopro_live[gopro.id] = {"encoding": True, "busy": False, "settings": {}}
                app.studio.select(ronin.id)
                app.tab = "settings"
                screen = pygame.Surface((1280, 800))
                app.draw(screen)
                path = Path("/tmp/ronin-deck-frame.png")
                _save_png(screen, path)
                self.assertGreater(path.stat().st_size, 1000)
                paper = screen.get_at((10, 10))
                self.assertGreater(paper.r, 230)
                self.assertGreater(paper.g, 220)
                self.assertLess(paper.b, paper.r)
                # 가운데 무대에 방 선이나 장치 색이 있어야 합니다.
                center = screen.get_at((640, 360))
                self.assertNotEqual((center.r, center.g, center.b), (0, 0, 0))
                app.memory[(ronin.id, "sony-pass")] = "do-not-store"
                app.studio.save()
                blob = Path(app.studio.path).read_text(encoding="utf-8")
                self.assertNotIn("do-not-store", blob)
                app.move_row(1)
                app.adjust(1)
                app.confirm()
            finally:
                app.shutdown()
                pygame.quit()


if __name__ == "__main__":
    unittest.main()
