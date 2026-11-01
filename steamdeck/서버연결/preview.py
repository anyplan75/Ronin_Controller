"""고프로 와이파이 미리보기입니다. 카메라가 UDP 8554로 보내는 MPEG-TS 만 받습니다.

그림으로 풀려면 리눅스의 ffmpeg 가 필요합니다.
없으면 가짜 영상을 그리지 않고 글만 남깁니다.
액션 5 프로 C3, 오즈모, 로닌에는 이 수신기를 켜지 않습니다.
"""

from __future__ import annotations

import shutil
import socket
import subprocess
import threading

from 화면코드.model import supports_live_view


class GoProPreview:
    def __init__(self) -> None:
        self.note = "실시간 그림을 기다리는 중입니다."
        self.frame = None
        self.packets = 0
        self._thread = None
        self._stop = threading.Event()
        self._lock = threading.Lock()

    def open(self, device) -> None:
        self.stop()
        if not supports_live_view(device.kind):
            self.note = "이 장치는 미리보기 그림을 주지 않습니다."
            return
        self._stop.clear()
        self.packets = 0
        self.frame = None
        self.note = "실시간 그림을 기다리는 중입니다."
        self._thread = threading.Thread(target=self._run, name="gopro-preview", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        thread = self._thread
        if thread and thread.is_alive():
            thread.join(timeout=0.6)
        self._thread = None
        with self._lock:
            self.frame = None

    def latest(self):
        with self._lock:
            return self.frame, self.note, self.packets

    def _run(self) -> None:
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            self._listen_only()
            return
        command = [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-fflags",
            "nobuffer",
            "-flags",
            "low_delay",
            "-i",
            "udp://0.0.0.0:8554?fifo_size=1000000&overrun_nonfatal=1",
            "-an",
            "-vf",
            "scale=320:180",
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgb24",
            "pipe:1",
        ]
        try:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError:
            self.note = "ffmpeg 를 실행하지 못했습니다. 가짜 영상은 보여 주지 않습니다."
            return
        width, height = 320, 180
        size = width * height * 3
        try:
            while not self._stop.is_set():
                chunk = _read_exact(process.stdout, size, self._stop)
                if chunk is None:
                    break
                self.packets += 1
                with self._lock:
                    self.frame = (width, height, chunk)
                    self.note = ""
        finally:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()

    def _listen_only(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.settimeout(0.4)
            sock.bind(("0.0.0.0", 8554))
        except OSError:
            self.note = "미리보기 포트 8554를 잡지 못했습니다. 가짜 영상은 보여 주지 않습니다."
            sock.close()
            return
        self.note = "ffmpeg 가 없어 그림을 풀지 못합니다. 스트림만 확인합니다."
        try:
            while not self._stop.is_set():
                try:
                    data, _addr = sock.recvfrom(2048)
                except socket.timeout:
                    continue
                if not data:
                    continue
                self.packets += 1
                if data[0] == 0x47 or (len(data) > 12 and data[12] == 0x47):
                    self.note = "스트림은 들어왔지만 ffmpeg 가 없어 그림으로 풀지 못했습니다."
        finally:
            sock.close()


def _read_exact(pipe, size: int, stop: threading.Event):
    if pipe is None:
        return None
    buf = bytearray()
    while len(buf) < size:
        if stop.is_set():
            return None
        piece = pipe.read(size - len(buf))
        if not piece:
            return None
        buf.extend(piece)
    return bytes(buf)
