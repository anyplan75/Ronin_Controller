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
bool roninBleMove(float yawDeg, float pitchDeg, bool home, char* reason, size_t reasonCap);
void roninBleFillList(JsonDocument& doc);
