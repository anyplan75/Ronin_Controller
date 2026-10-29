#pragma once

#include <stdint.h>

// 여러 기판이 같은 시각에 녹화 명령을 내보내도록,
// 앱이 보낸 시각을 이 기판의 millis 기준으로 바꿉니다.
//
// at_ms 가 있으면 그 시각을 쓰고, 없으면 delay_ms 뒤에 보냅니다.
// at_ms 가 지금보다 10초보다 더 뒤면 거절합니다.
// 200ms 보다 더 지난 시각이면 바로 보냅니다.
// true 이면 fireAtMs 가 유효합니다.
inline bool planSyncFire(bool hasAt, uint32_t atMs, bool hasDelay, int32_t delayMs,
                         uint32_t nowMs, uint32_t* fireAtMs, bool* fireNow) {
  uint32_t fireAt = nowMs;
  if (hasAt) {
    const int32_t wait = static_cast<int32_t>(atMs - nowMs);
    if (wait > 10000) {
      return false;
    }
    if (wait < -200) {
      fireAt = nowMs;
    } else {
      fireAt = atMs;
    }
  } else {
    int32_t delay = hasDelay ? delayMs : 0;
    if (delay < 0) {
      delay = 0;
    }
    if (delay > 10000) {
      delay = 10000;
    }
    fireAt = nowMs + static_cast<uint32_t>(delay);
  }
  *fireAtMs = fireAt;
  *fireNow = static_cast<int32_t>(fireAt - nowMs) <= 0;
  return true;
}
