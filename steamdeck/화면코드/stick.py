"""스팀 덱 왼쪽 스틱을 로닌 기판의 요·피치 속도로 바꿉니다.

기판은 요 오른쪽을 양수, 피치 위를 음수로 받습니다.
스틱 좌표는 오른쪽이 양수, 위가 음수입니다.
"""

from __future__ import annotations

DEADZONE = 0.18
MAX_DPS = 120.0


def _shape(value: float, deadzone: float = DEADZONE) -> float:
    magnitude = abs(value)
    if magnitude < deadzone:
        return 0.0
    shaped = (magnitude - deadzone) / (1.0 - deadzone)
    if shaped > 1:
        shaped = 1.0
    return shaped if value > 0 else -shaped


def stick_unit(x: float, y: float, deadzone: float = DEADZONE) -> tuple[float, float]:
    return _shape(x, deadzone), _shape(y, deadzone)


def stick_speed(x: float, y: float, max_dps: float = MAX_DPS) -> tuple[float, float, float]:
    """반환은 (요 속도, 롤 속도, 피치 속도) 입니다. 롤은 항상 0입니다."""
    unit_x, unit_y = stick_unit(x, y)
    yaw = unit_x * max_dps
    pitch = unit_y * max_dps
    return yaw, 0.0, pitch


def visual_offsets(x: float, y: float) -> tuple[float, float]:
    """자세 값이 없을 때 무대 빛에 더할 각도입니다. 가득 밀면 12도입니다."""
    unit_x, unit_y = stick_unit(x, y)
    return unit_x * 12.0, (-unit_y) * 12.0
