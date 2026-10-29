"""장치로 보내는 일과, 스틱이 누르는 동안의 속도 명령을 나눕니다."""

from __future__ import annotations

import queue
import threading
import time

from 서버연결.protocol import CallError, http_get


class Result:
    def __init__(self, note: str = "", ronin=None, gopro=None, shots=None, paired_id: str = ""):
        self.note = note
        self.ronin = ronin
        self.gopro = gopro
        self.shots = shots
        self.paired_id = paired_id


class Bus:
    def __init__(self) -> None:
        self.jobs: queue.Queue = queue.Queue()
        self.results: queue.Queue = queue.Queue()
        self._stop = threading.Event()
        self._motion = {
            "id": "",
            "host": "",
            "port": 0,
            "name": "",
            "yaw": 0.0,
            "pitch": 0.0,
            "practice": True,
        }
        self._lock = threading.Lock()
        self._worker = threading.Thread(target=self._run_jobs, name="ronin-http", daemon=True)
        self._mover = threading.Thread(target=self._run_motion, name="ronin-stick", daemon=True)
        self._worker.start()
        self._mover.start()

    def submit(self, work) -> None:
        self.jobs.put(work)

    def pump(self) -> list[Result]:
        found = []
        while True:
            try:
                found.append(self.results.get_nowait())
            except queue.Empty:
                return found

    def set_motion(self, device, yaw: float, pitch: float, practice: bool) -> None:
        with self._lock:
            self._motion = {
                "id": device.id if device else "",
                "host": device.host if device else "",
                "port": device.port if device else 0,
                "name": device.name if device else "",
                "yaw": yaw,
                "pitch": pitch,
                "practice": practice,
            }

    def shutdown(self) -> None:
        with self._lock:
            self._motion = {
                "id": self._motion.get("id", ""),
                "host": self._motion.get("host", ""),
                "port": self._motion.get("port", 0),
                "name": self._motion.get("name", ""),
                "yaw": 0.0,
                "pitch": 0.0,
                "practice": False,
            }
        time.sleep(0.2)
        self._stop.set()

    def _run_jobs(self) -> None:
        while not self._stop.is_set():
            try:
                work = self.jobs.get(timeout=0.1)
            except queue.Empty:
                continue
            try:
                result = work()
                if not isinstance(result, Result):
                    result = Result(note=str(result or ""))
            except CallError as error:
                result = Result(note=str(error))
            except Exception as error:
                result = Result(note=str(error))
            self.results.put(result)

    def _run_motion(self) -> None:
        last_key = None
        last_send = 0.0
        last_error = 0.0
        while not self._stop.is_set():
            with self._lock:
                snap = dict(self._motion)
            moving = abs(snap["yaw"]) >= 0.5 or abs(snap["pitch"]) >= 0.5
            key = (
                snap["id"],
                round(snap["yaw"] / 4.0) * 4,
                round(snap["pitch"] / 4.0) * 4,
                snap["practice"],
                moving,
            )
            now = time.monotonic()
            should_send = key != last_key or (moving and now - last_send > 0.4)
            if should_send and not snap["practice"] and snap["host"] and snap["port"] > 0:
                try:
                    if moving:
                        http_get(
                            snap["host"],
                            snap["port"],
                            "/speed",
                            {
                                "yaw": f"{snap['yaw']:.2f}",
                                "roll": "0",
                                "pitch": f"{snap['pitch']:.2f}",
                            },
                            timeout=0.8,
                        )
                    elif last_key is not None and last_key[4]:
                        http_get(snap["host"], snap["port"], "/stop", timeout=0.8)
                    last_send = now
                    last_key = key
                except CallError as error:
                    if now - last_error > 2:
                        self.results.put(Result(note=f"{snap['name']} {error}"))
                        last_error = now
                    last_key = key
            elif should_send:
                last_key = key
            time.sleep(0.08)
