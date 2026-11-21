#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>

// 로닌 짐벌을 C3 블루투스로 붙입니다. CAN 배선이 아닙니다.

struct RoninFound {
  char id[24];
  char name[40];
  uint8_t addrType;
};

enum class RoninTarget : uint8_t { Any = 0, Rs2Only = 1, ScOnly = 2 };

void roninBleBegin();
void roninBleSetTarget(RoninTarget target);
RoninTarget roninBleTarget();
void roninBleLoop();
void roninBleDrop();
bool roninBleBusy();
bool roninBleLinked();
const char* roninBleName();
size_t roninBleScan(RoninFound* out, size_t cap, bool manageBusy = true);
bool roninBlePair(const char* name, const char* id, char* reason, size_t reasonCap);
bool roninBleAutoPair(char* reason, size_t reasonCap);
/// pan=좌우, pitch=틸트, roll=요(롤 모터). 팬≠요.
bool roninBleMove(float panDeg, float pitchDeg, bool home, char* reason, size_t reasonCap, float rollDeg = 0);
/// RS2 줌(다이얼). speed +줌인 / -줌아웃 / 0멈춤. SC는 자리만(지금은 거부).
bool roninBleZoom(int16_t speed, char* reason, size_t reasonCap);
/// 최신 목표만 덮어씀. 루프가 30~50ms 간격으로 한 번에 하나씩 보냄.
void roninBleOfferMove(float panDeg, float pitchDeg, float rollDeg, bool home);
void roninBleOfferZoom(int16_t speed);
/// 팬·틸트 DUML 페이로드 바이트/축 분리 시험. axisSlot 0=팬 1=롤(요) 2=틸트. rawByte>=0 이면 그 칸(0~7)만 씀.
bool roninBleProbePayload(int axisSlot, float deg, int rawByte, int rawValue, char* reason, size_t reasonCap);
void roninBleFillList(JsonDocument& doc);
