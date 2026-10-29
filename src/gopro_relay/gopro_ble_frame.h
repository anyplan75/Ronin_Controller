#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

// Open GoPro BLE (2025-02 SDK) 의 13비트 길이 헤더입니다.
// 서비스는 FEA6, 명령 특성은 b5f90072 입니다. FFE0/FFE1 이 아닙니다.
// 길이만 한 바이트로 둔 옛 4바이트 쓰기는 여기서 만들지 않습니다.

enum { kGoproFrameMax = 40 };

struct GoproBytes {
  uint8_t data[kGoproFrameMax];
  uint8_t length;
};

inline bool goproFrameExt13(const uint8_t* payload, uint8_t payloadLen, GoproBytes* out) {
  if (out == nullptr || payload == nullptr || payloadLen == 0 || payloadLen > 30) {
    return false;
  }
  out->data[0] = (uint8_t)(0x20u | ((payloadLen >> 8) & 0x1Fu));
  out->data[1] = payloadLen;
  memcpy(out->data + 2, payload, payloadLen);
  out->length = (uint8_t)(payloadLen + 2);
  return true;
}

// 명령 0x01, 인자 길이 1, 값 1=시작 0=정지. 앞에 13비트 헤더가 붙습니다.
inline bool goproShutterFrame(bool start, GoproBytes* out) {
  const uint8_t body[3] = {0x01, 0x01, (uint8_t)(start ? 0x01 : 0x00)};
  return goproFrameExt13(body, 3, out);
}

// 명령 0x5B. 세션을 끊지 않고 카메라를 깨워 둡니다.
inline bool goproKeepAliveFrame(GoproBytes* out) {
  const uint8_t body[1] = {0x5B};
  return goproFrameExt13(body, 1, out);
}

// 설정 특성(b5f90074)에 쓰는 TLV 입니다. 설정 번호, 길이 1, 선택값.
inline bool goproSettingFrame(uint8_t setting, uint8_t option, GoproBytes* out) {
  const uint8_t body[3] = {setting, 0x01, option};
  return goproFrameExt13(body, 3, out);
}

struct GoproAssembler {
  uint8_t payload[kGoproFrameMax];
  uint8_t payloadLen;
  uint16_t need;
  uint8_t state;
};

inline void goproAssemblerReset(GoproAssembler* rx) {
  rx->payloadLen = 0;
  rx->need = 0;
  rx->state = 0;
}

inline bool goproAssemblerPush(GoproAssembler* rx, const uint8_t* data, uint8_t len, bool* done) {
  *done = false;
  if (rx == nullptr || data == nullptr || len == 0) {
    return false;
  }
  if (rx->state == 0) {
    if (data[0] & 0x80) {
      return false;
    }
    const uint8_t kind = (uint8_t)((data[0] >> 5) & 0x03);
    uint16_t total = 0;
    uint8_t header = 0;
    if (kind == 0) {
      total = (uint16_t)(data[0] & 0x1F);
      header = 1;
    } else if (kind == 1) {
      if (len < 2) {
        return false;
      }
      total = (uint16_t)(((data[0] & 0x1F) << 8) | data[1]);
      header = 2;
    } else if (kind == 2) {
      if (len < 3) {
        return false;
      }
      total = (uint16_t)((data[1] << 8) | data[2]);
      header = 3;
    } else {
      return false;
    }
    if (header > len || total > kGoproFrameMax) {
      return false;
    }
    const uint8_t chunk = (uint8_t)(len - header);
    if (chunk > total) {
      return false;
    }
    memcpy(rx->payload, data + header, chunk);
    rx->payloadLen = chunk;
    if (chunk == total) {
      rx->state = 2;
      *done = true;
    } else {
      rx->need = (uint16_t)(total - chunk);
      rx->state = 1;
    }
    return true;
  }
  if (rx->state != 1 || (data[0] & 0x80) == 0 || len < 1) {
    return false;
  }
  const uint8_t chunk = (uint8_t)(len - 1);
  if (chunk > rx->need || (uint16_t)rx->payloadLen + chunk > kGoproFrameMax) {
    return false;
  }
  memcpy(rx->payload + rx->payloadLen, data + 1, chunk);
  rx->payloadLen = (uint8_t)(rx->payloadLen + chunk);
  rx->need = (uint16_t)(rx->need - chunk);
  if (rx->need == 0) {
    rx->state = 2;
    *done = true;
  }
  return true;
}
