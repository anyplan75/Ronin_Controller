"""무대 방의 빛과 화면 위치입니다. 가로는 14m, 깊이는 18m, 높이는 6.5m 입니다."""

from __future__ import annotations

import math

from 화면코드.model import FIELD_DEGREES, ROOM_H, ROOM_L, ROOM_W


def room_exit(origin, direction) -> float:
    """방 안에 있는 점에서 벽·바닥·천장까지 거리입니다."""
    half_w = ROOM_W * 0.5
    slabs = [
        (origin[0], direction[0], -half_w, half_w),
        (origin[1], direction[1], 0.0, ROOM_L),
        (origin[2], direction[2], 0.0, ROOM_H),
    ]
    exit_distance = math.inf
    for origin_axis, direction_axis, low, high in slabs:
        if abs(direction_axis) < 1e-8:
            if origin_axis < low - 1e-4 or origin_axis > high + 1e-4:
                return 0.0
            continue
        near = (low - origin_axis) / direction_axis
        far = (high - origin_axis) / direction_axis
        if near > far:
            near, far = far, near
        if far < exit_distance:
            exit_distance = far
    if not math.isfinite(exit_distance) or exit_distance < 0:
        return 0.0
    limit = math.hypot(ROOM_W, math.hypot(ROOM_L, ROOM_H))
    return min(exit_distance, limit)


def project(point, size, camera) -> tuple[float, float]:
    yaw = camera["yaw"]
    pitch = camera["pitch"]
    zoom = camera["zoom"]
    width, height = size
    cx, cy, cz = 0.0, ROOM_L * 0.5, ROOM_H * 0.45
    rx, ry, rz = point[0] - cx, point[1] - cy, point[2] - cz
    cos_y, sin_y = math.cos(yaw), math.sin(yaw)
    x1 = rx * cos_y - ry * sin_y
    y1 = rx * sin_y + ry * cos_y
    cos_p, sin_p = math.cos(pitch), math.sin(pitch)
    y2 = y1 * cos_p - rz * sin_p
    z2 = y1 * sin_p + rz * cos_p
    max_span = max(ROOM_W, ROOM_L, ROOM_H)
    fov = min(width, height) * 0.95 * zoom
    depth = max(2.0, max_span * 1.65 + y2)
    sx = width * 0.5 + (x1 * fov) / depth
    sy = height * 0.54 - (z2 * fov) / depth
    return sx, sy


def coverage_rays(spot_x, spot_y, spot_z, yaw_deg, pitch_deg):
    half = math.radians(FIELD_DEGREES) / 2
    yaw = math.radians(yaw_deg)
    pitch = math.radians(pitch_deg)
    steps = 14
    rays = []
    for step in range(steps + 1):
        ang = -half + (half * 2) * step / steps
        heading = yaw + ang
        direction = (
            math.sin(heading) * math.cos(pitch),
            math.cos(heading) * math.cos(pitch),
            math.sin(pitch),
        )
        dist = room_exit((spot_x, spot_y, spot_z), direction)
        rays.append((ang, direction, dist))
    return rays
