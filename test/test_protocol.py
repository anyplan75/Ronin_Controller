#!/usr/bin/env python3
"""프레임 시험과, 쓰지 않기로 한 블루투스 번호가 명령으로 들어가지 않았는지 확인합니다."""

import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def run(compiler_args, binary, label):
    subprocess.check_call(compiler_args)
    out = subprocess.check_output([binary], text=True)
    print(out.strip())
    if label not in out:
        raise SystemExit(f"{label} 결과가 없습니다")


def main():
    run(
        ["g++", "-std=c++17", "-Wall", "-Wextra", "-o", "/tmp/test_sync", "test/test_sync_schedule.cpp"],
        "/tmp/test_sync",
        "동기 시각 계산 통과",
    )
    run(
        ["g++", "-std=c++17", "-Wall", "-Wextra", "-o", "/tmp/test_gopro_frame", "test/test_gopro_frame.cpp"],
        "/tmp/test_gopro_frame",
        "고프로 프레임 통과",
    )

    swift = (ROOT / "apple/RoninControl/Protocol/DjiRFrame.swift").read_text()
    hex_line = "aa1b000100000000050057ee1d04000033ff0a01473936f4fae1d0"
    if hex_line not in swift:
        raise SystemExit("오즈모 공식 예시 프레임이 앱에 없습니다")

    profile = (ROOT / "apple/RoninControl/Model/Profile.swift").read_text()
    if "goproAction5" not in profile:
        raise SystemExit("액션 5 프로 장치 종류가 없습니다")

    banned_dirs = [ROOT / "src", ROOT / "apple"]
    for folder in banned_dirs:
        for path in folder.rglob("*"):
            if not path.is_file():
                continue
            if path.suffix.lower() not in {".swift", ".cpp", ".h", ".hpp", ".ino"}:
                continue
            text = path.read_text(errors="replace")
            if "FFE0" in text or "FFE1" in text:
                if "쓰지 않습니다" in text or "아닙니다" in text:
                    continue
                raise SystemExit(f"금지된 BLE 번호가 명령에 있습니다: {path}")
            if "0x03, 0x01, 0x01, 0x01" in text or "{0x03,0x01,0x01,0x01}" in text:
                raise SystemExit(f"옛 셔터 바이트가 있습니다: {path}")
    print("프로토콜 검사 통과")


if __name__ == "__main__":
    sys.exit(main())
