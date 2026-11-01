"""장치 모델, 스틱, 프레임이 애플 앱과 같은지 확인합니다."""

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import 경로

경로.ensure()

from 서버연결.frames import build, self_check
from 서버연결.osmo import mode_payload as osmo_mode_payload
from 서버연결.protocol import build_url, parse_gopro_state, redact
from 화면코드.model import (
    KIND_ACTION5,
    KIND_GOPRO,
    KIND_OSMO,
    KIND_RONIN,
    PRODUCTS,
    Profile,
    load_profile,
    record_mark,
    save_profile,
    supports_live_view,
)
from 화면코드.stage_math import room_exit
from 화면코드.stick import stick_speed, visual_offsets
from 서버연결.osmo import OsmoRadio
from 화면코드.studio import Studio


class ModelTests(unittest.TestCase):
    def test_products_match_apple_menu(self):
        labels = [item[1] for item in PRODUCTS]
        self.assertEqual(labels, [
            "로닌 기판 · CAN",
            "고프로 · 와이파이",
            "오즈모 액션 5 프로 · 블루투스",
            "오즈모 액션 · 블루투스",
            "오즈모 360 · 블루투스",
        ])
        self.assertEqual(PRODUCTS[2][2], KIND_ACTION5)

    def test_live_view_is_gopro_wifi_only(self):
        self.assertTrue(supports_live_view(KIND_GOPRO))
        self.assertFalse(supports_live_view(KIND_ACTION5))
        self.assertFalse(supports_live_view(KIND_RONIN))
        self.assertFalse(supports_live_view(KIND_OSMO))

    def test_profile_roundtrip_has_no_password(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "[로닌컨트롤]_profile.json"
            profile = Profile.make_new()
            save_profile(path, profile)
            loaded = load_profile(path)
            raw = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(loaded.to_dict()["version"], raw["version"])
            self.assertEqual(raw["stageSpots"], [])
            blob = json.dumps(raw)
            self.assertNotIn("password", blob.lower())
            self.assertNotIn("pass", blob.lower())
            self.assertIn("[로닌컨트롤]_profile.json", path.name)

    def test_apple_profile_fields(self):
        raw = {
            "version": 1,
            "devices": [{
                "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                "name": "중계",
                "kind": "goproAction5",
                "osmoModel": "unknown",
                "host": "192.168.0.20",
                "port": 80,
                "bleIdentifier": "",
                "enabled": True,
                "pairedOnce": False,
            }],
            "presets": [],
            "groupIds": ["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"],
            "leadMs": 300,
            "practice": False,
            "senderId": 7,
            "senderMac": [1, 2, 3, 4, 5, 6],
        }
        profile = Profile.from_dict(raw)
        self.assertEqual(profile.devices[0].kind, KIND_ACTION5)
        self.assertEqual(profile.devices[0].port, 80)
        self.assertEqual(profile.spots, [])
        again = profile.to_dict()
        self.assertEqual(again["devices"][0]["kind"], "goproAction5")
        self.assertNotIn("password", json.dumps(again).lower())

    def test_record_marks(self):
        self.assertEqual(record_mark(KIND_RONIN, {"sony_recording": True}, None, None), "녹화")
        self.assertEqual(record_mark(KIND_RONIN, {"cam_recording": True}, None, None), "녹화 명령")
        self.assertIsNone(record_mark(KIND_RONIN, {"cam_recording": False}, None, None))
        self.assertEqual(record_mark(KIND_GOPRO, None, {"encoding": True}, None), "녹화")
        self.assertIsNone(record_mark(KIND_ACTION5, None, {"encoding": False}, None))
        self.assertEqual(record_mark(KIND_OSMO, None, None, 3), "촬영 중")
        self.assertEqual(record_mark(KIND_OSMO, None, None, 5), "프리 레코드")
        self.assertIsNone(record_mark(KIND_OSMO, None, None, 1))

    def test_stick_matches_board_signs(self):
        yaw, roll, pitch = stick_speed(1, 0)
        self.assertGreater(yaw, 0)
        self.assertEqual(roll, 0)
        self.assertEqual(pitch, 0)
        yaw, roll, pitch = stick_speed(0, -1)
        self.assertEqual(yaw, 0)
        self.assertLess(pitch, 0)
        self.assertEqual(stick_speed(0.05, -0.05), (0.0, 0.0, 0.0))
        pan, tilt = visual_offsets(0, -1)
        self.assertEqual(pan, 0)
        self.assertEqual(tilt, 12)

    def test_room_exit_hits_far_wall(self):
        self.assertAlmostEqual(room_exit((0, 1, 1.6), (0, 1, 0)), 17)

    def test_frame_matches_official_example(self):
        self.assertTrue(self_check())
        payload = osmo_mode_payload(0xFF330000, 0x0A)
        self.assertEqual(payload, bytes([0x00, 0x00, 0x33, 0xFF, 0x0A, 0x01, 0x47, 0x39, 0x36]))
        self.assertEqual(build(0x1D, 0x04, 0x01, 5, payload).hex(), 
                         "aa1b000100000000050057ee1d04000033ff0a01473936f4fae1d0")

    def test_gopro_state_and_redacted_url(self):
        live = parse_gopro_state('{"status":{"10":1,"8":0,"35":12},"settings":{"2":9},"relay_ble":"연결됨"}')
        self.assertTrue(live["encoding"])
        self.assertEqual(live["remaining_video"], 12)
        self.assertEqual(live["settings"][2], 9)
        self.assertEqual(live["relay_ble"], "연결됨")
        url = build_url("192.168.0.8", 80, "/wifi", {"pass": "secret", "ssid": "house"})
        self.assertIn("pass=secret", url)
        self.assertNotIn("secret", redact(url))
        self.assertLess(url.index("pass="), url.index("ssid="))

    def test_add_device_stops_at_eight(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "profile.json"
            studio = Studio(path, OsmoRadio())
            try:
                studio.profile.practice = True
                for _ in range(9):
                    studio.add_device("ronin")
                self.assertEqual(len(studio.profile.devices), 8)
                studio.add_device("action5Bluetooth")
                self.assertTrue(any("8대" in line for line in studio.log))
            finally:
                studio.bus.shutdown()


if __name__ == "__main__":
    unittest.main()
