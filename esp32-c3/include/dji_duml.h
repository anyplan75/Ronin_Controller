#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <math.h>

// DJI DUML(SOF 0x55). 로닌 앱 BLE 가 R SDK(0xAA) 가 아닐 때 씁니다.
// CRC8: poly 0x31 init 0xEE reflected. CRC16: poly 0x1021 init 0x496C reflected.

inline uint8_t dumlCrc8(const uint8_t* data, size_t len) {
  uint8_t crc = 0x77;  // reflected init of 0xEE
  for (size_t i = 0; i < len; i++) {
    crc ^= data[i];
    for (int b = 0; b < 8; b++) {
      if (crc & 1) crc = (uint8_t)((crc >> 1) ^ 0x8C);  // reflected 0x31
      else crc >>= 1;
    }
  }
  return crc;
}

inline uint16_t dumlCrc16(const uint8_t* data, size_t len) {
  uint16_t crc = 0x3692;  // reflected init of 0x496C
  for (size_t i = 0; i < len; i++) {
    crc ^= data[i];
    for (int b = 0; b < 8; b++) {
      if (crc & 1) crc = (uint16_t)((crc >> 1) ^ 0x8408);  // reflected 0x1021
      else crc >>= 1;
    }
  }
  return crc;
}

inline size_t dumlBuild(uint8_t* out, size_t cap, uint16_t target, uint16_t seq, uint8_t flags,
                        uint8_t cmdSet, uint8_t cmdId, const uint8_t* payload, size_t payloadLen) {
  size_t total = 13 + payloadLen;
  if (out == nullptr || total > cap || total > 1024) return 0;
  out[0] = 0x55;
  out[1] = (uint8_t)(total & 0xFF);
  out[2] = (uint8_t)(((total >> 8) & 0x03) | (1 << 2));  // version 1
  out[3] = dumlCrc8(out, 3);
  out[4] = (uint8_t)(target & 0xFF);
  out[5] = (uint8_t)(target >> 8);
  out[6] = (uint8_t)(seq >> 8);  // BE
  out[7] = (uint8_t)(seq & 0xFF);
  out[8] = flags;
  out[9] = cmdSet;
  out[10] = cmdId;
  for (size_t i = 0; i < payloadLen; i++) out[11 + i] = payload[i];
  uint16_t c16 = dumlCrc16(out, total - 2);
  out[total - 2] = (uint8_t)(c16 & 0xFF);
  out[total - 1] = (uint8_t)(c16 >> 8);
  return total;
}

// App(0x02) → Gimbal(0x04) = 0x0402
// 로닌 RS2/SC: 페이로드는 R SDK와 같이 yaw·roll·pitch 순서.
// (Osmo Pocket 문서의 pitch-first 는 로닌에서 yaw가 틸트로 가는 오매핑이 났음.)
// flags bit0=pitch, bit1=roll, bit2=yaw — 쓰는 축만 켭니다.
inline size_t dumlAbsAngle(uint8_t* out, size_t cap, uint16_t seq, float yawDeg, float pitchDeg, float durationSec) {
  uint8_t payload[8];
  int16_t yaw = (int16_t)lroundf(yawDeg * 10.0f);
  int16_t roll = 0;
  int16_t pitch = (int16_t)lroundf(pitchDeg * 10.0f);
  payload[0] = (uint8_t)(yaw & 0xFF);
  payload[1] = (uint8_t)(yaw >> 8);
  payload[2] = (uint8_t)(roll & 0xFF);
  payload[3] = (uint8_t)(roll >> 8);
  payload[4] = (uint8_t)(pitch & 0xFF);
  payload[5] = (uint8_t)(pitch >> 8);
  uint8_t axis = 0;
  if (yaw != 0) axis |= 0x04;    // yaw/팬
  if (pitch != 0) axis |= 0x01;  // pitch/틸트
  if (axis == 0) axis = 0x05;    // 제자리: 팬+틸트
  payload[6] = axis;
  if (durationSec < 0.1f) durationSec = 0.1f;
  if (durationSec > 25.0f) durationSec = 25.0f;
  payload[7] = (uint8_t)lroundf(durationSec * 10.0f);
  return dumlBuild(out, cap, 0x0402, seq, 0x40, 0x04, 0x14, payload, sizeof(payload));
}

inline size_t dumlSpeed(uint8_t* out, size_t cap, uint16_t seq, float yawDps, float pitchDps) {
  uint8_t payload[7];
  int16_t yaw = (int16_t)lroundf(yawDps * 10.0f);
  int16_t roll = 0;
  int16_t pitch = (int16_t)lroundf(pitchDps * 10.0f);
  payload[0] = (uint8_t)(yaw & 0xFF);
  payload[1] = (uint8_t)(yaw >> 8);
  payload[2] = (uint8_t)(roll & 0xFF);
  payload[3] = (uint8_t)(roll >> 8);
  payload[4] = (uint8_t)(pitch & 0xFF);
  payload[5] = (uint8_t)(pitch >> 8);
  payload[6] = 0x01;
  return dumlBuild(out, cap, 0x0402, seq, 0x40, 0x04, 0x0C, payload, sizeof(payload));
}

inline size_t dumlSetMode(uint8_t* out, size_t cap, uint16_t seq, uint8_t mode) {
  uint8_t payload[2] = {mode, 0};  // 0=lock 1=follow 2=fpv
  return dumlBuild(out, cap, 0x0402, seq, 0x40, 0x04, 0x4C, payload, sizeof(payload));
}
