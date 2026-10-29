"""베이지색 무대입니다. 장치는 점이 아니라 종류마다 다른 모양입니다."""

from __future__ import annotations

import math

import pygame

from 화면코드.model import (
    KIND_GOPRO,
    KIND_RONIN,
    ROOM_H,
    ROOM_L,
    ROOM_W,
    record_mark,
)
from 화면코드.stage_math import coverage_rays, project

PAPER = (244, 239, 230)
INK = (28, 25, 21)
OXBLOOD = (122, 46, 52)
BRASS = (138, 106, 50)
STAGE_FILL = (56, 189, 248, 40)
STAGE_LINE = (56, 189, 248)


def draw_stage(target, rect, studio, camera, drives, nudge, fonts) -> list[tuple[str, float, float]]:
    view = pygame.Surface((rect[2], rect[3]))
    view.fill(PAPER)
    size = (rect[2], rect[3])
    half_w = ROOM_W * 0.5
    for x in _range(-math.floor(half_w), math.floor(half_w), 2):
        a = project((x, 0, 0), size, camera)
        b = project((x, ROOM_L, 0), size, camera)
        pygame.draw.line(view, (220, 214, 204), a, b, 1)
    y = 0.0
    while y <= ROOM_L:
        a = project((-half_w, y, 0), size, camera)
        b = project((half_w, y, 0), size, camera)
        pygame.draw.line(view, (220, 214, 204), a, b, 1)
        y += 2
    corners = [
        (-half_w, 0, 0), (half_w, 0, 0), (half_w, ROOM_L, 0), (-half_w, ROOM_L, 0),
        (-half_w, 0, ROOM_H), (half_w, 0, ROOM_H), (half_w, ROOM_L, ROOM_H), (-half_w, ROOM_L, ROOM_H),
    ]
    edges = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
    for a, b in edges:
        pygame.draw.line(view, INK, project(corners[a], size, camera), project(corners[b], size, camera), 2)
    deck = [
        project((-half_w * 0.7, 0.2, 0.4), size, camera),
        project((half_w * 0.7, 0.2, 0.4), size, camera),
        project((half_w * 0.7, 2.2, 0.4), size, camera),
        project((-half_w * 0.7, 2.2, 0.4), size, camera),
    ]
    pygame.draw.polygon(view, (210, 226, 232), deck)
    pygame.draw.polygon(view, STAGE_LINE, deck, 1)

    hits = []
    devices = list(studio.profile.devices)
    if not devices:
        _text(view, fonts, 18, "장치가 없습니다. 메뉴 버튼으로 장치 추가를 여세요.", INK, (16, size[1] - 64))
    for index, device in enumerate(devices):
        spot = studio.spot(device.id)
        floor = project((spot.x, spot.y, 0), size, camera)
        top = project((spot.x, spot.y, spot.z), size, camera)
        pygame.draw.line(view, (120, 112, 100), floor, top, 1)
        yaw = spot.aim_yaw
        pitch_draw = 0.0
        if device.kind == KIND_RONIN:
            if device.id in drives:
                yaw, pitch_draw = drives[device.id]
            else:
                yaw = spot.aim_yaw + spot.home_yaw
                pitch_draw = -spot.home_pitch
            _coverage(view, size, camera, spot, yaw, pitch_draw)
        elif nudge and nudge[0] == device.id:
            yaw = spot.aim_yaw + nudge[1]
            pitch_draw = nudge[2]
        aim = project((
            spot.x + math.sin(math.radians(yaw)) * 1.8,
            spot.y + math.cos(math.radians(yaw)) * 1.8,
            spot.z + math.sin(math.radians(pitch_draw)) * 1.8,
        ), size, camera)
        pygame.draw.line(view, BRASS, top, aim, 2)
        chosen = device.id == studio.selected_id
        live_ronin = studio.ronin_live.get(device.id)
        live_gopro = studio.gopro_live.get(device.id)
        osmo = studio.radio.snapshot(device.id).get("status")
        mark = record_mark(device.kind, live_ronin, live_gopro, osmo)
        _glyph(view, device, top, aim, chosen, mark is not None)
        lift = index * 16
        if mark:
            _text(view, fonts, 14, mark, OXBLOOD, (top[0] + 16, top[1] - 46 - lift))
        _text(view, fonts, 15, device.name, INK, (top[0] + 16, top[1] - 28 - lift))
        hits.append((device.id, top[0] + rect[0], top[1] + rect[1]))
    _text(view, fonts, 15, "화면 휠 없음. 왼쪽 스틱이 고른 장치를 움직입니다.", INK, (12, size[1] - 28))
    target.blit(view, (rect[0], rect[1]))
    return hits


def _coverage(view, size, camera, spot, yaw, pitch):
    rays = coverage_rays(spot.x, spot.y, spot.z, yaw, pitch)
    half = math.radians(90) / 2
    for index in range(len(rays) - 1):
        left, right = rays[index], rays[index + 1]
        if left[2] <= 0.02 and right[2] <= 0.02:
            continue
        on_axis = 1 - min(1, abs((left[0] + right[0]) / 2) / half)
        for ring in range(6):
            f0 = ring / 6
            f1 = (ring + 1) / 6
            near = 1 - (f0 + f1) / 2
            loud = max(0, min(1, on_axis * near))
            color = (
                int(32 + 208 * loud),
                int(36 * (1 - abs(loud - 0.5) * 2)),
                int(32 + 208 * (1 - loud)),
            )
            points = [
                _along(left, f0, spot, size, camera),
                _along(right, f0, spot, size, camera),
                _along(right, f1, spot, size, camera),
                _along(left, f1, spot, size, camera),
            ]
            pygame.draw.polygon(view, color, points)
    for ray in rays:
        if ray[2] <= 0.02:
            continue
        hit = _along(ray, 1, spot, size, camera)
        pygame.draw.circle(view, (28, 63, 115), (int(hit[0]), int(hit[1])), 3)
        pygame.draw.circle(view, PAPER, (int(hit[0]), int(hit[1])), 3, 1)


def _along(ray, factor, spot, size, camera):
    distance = ray[2] * factor
    return project((
        spot.x + ray[1][0] * distance,
        spot.y + ray[1][1] * distance,
        spot.z + ray[1][2] * distance,
    ), size, camera)


def _glyph(view, device, top, aim, chosen, recording):
    surf = pygame.Surface((72, 72), pygame.SRCALPHA)
    cx = cy = 36
    ink = OXBLOOD if recording else INK
    if device.kind == KIND_GOPRO:
        pygame.draw.rect(surf, OXBLOOD, (cx - 20, cy - 8, 30, 16), border_radius=3)
        pygame.draw.rect(surf, ink, (cx - 20, cy - 8, 30, 16), 2, border_radius=3)
        pygame.draw.circle(surf, INK, (cx + 12, cy), 6)
        pygame.draw.circle(surf, PAPER, (cx + 14, cy - 1), 2)
    elif device.kind == KIND_RONIN:
        pygame.draw.arc(surf, ink, (cx - 16, cy - 18, 32, 32), math.radians(20), math.radians(160), 3)
        pygame.draw.rect(surf, ink, (cx - 2, cy + 4, 4, 12))
        pygame.draw.rect(surf, OXBLOOD, (cx - 8, cy - 6, 18, 12), border_radius=2)
        pygame.draw.circle(surf, INK, (cx + 12, cy), 4)
    elif device.osmo_model == "osmo360":
        pygame.draw.circle(surf, OXBLOOD, (cx, cy), 12)
        pygame.draw.circle(surf, ink, (cx, cy), 12, 2)
        pygame.draw.circle(surf, INK, (cx + 8, cy), 4)
        pygame.draw.circle(surf, INK, (cx - 10, cy), 4)
    else:
        pygame.draw.rect(surf, OXBLOOD, (cx - 9, cy - 16, 18, 30), border_radius=4)
        pygame.draw.rect(surf, ink, (cx - 9, cy - 16, 18, 30), 2, border_radius=4)
        pygame.draw.circle(surf, INK, (cx + 8, cy), 5)
        pygame.draw.rect(surf, PAPER, (cx - 7, cy - 10, 8, 12), 1)
    if chosen:
        surf = pygame.transform.smoothscale(surf, (90, 90))
    angle = -math.degrees(math.atan2(aim[1] - top[1], aim[0] - top[0]))
    rotated = pygame.transform.rotate(surf, angle)
    view.blit(rotated, (top[0] - rotated.get_width() / 2, top[1] - rotated.get_height() / 2))
    if chosen:
        pygame.draw.circle(view, BRASS, (int(top[0]), int(top[1])), 8, 2)


def _text(view, fonts, size, text, color, pos):
    image = fonts.render(size, text, color)
    view.blit(image, pos)


def _range(start, stop, step):
    value = start
    while value <= stop:
        yield value
        value += step
