#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>

// 울란지 VL120BI·VL200BI 조명을 C3 블루투스로 붙입니다.
// 카메라 탈리와는 별개입니다. 로닌 역할 C3 와 같은 기판에서 쓰지 않습니다.
// 프로토콜 근거: 실기 GATT FFF0/FFF1/FFF2 + kevinlouie/lctl 관측 명령 + 맥 bleak 쓰기 확인.

struct UlanziFound {
  char id[24];
  char name[40];
  uint8_t addrType;
};

void ulanziBleBegin();
void ulanziBleLoop();
void ulanziBleDrop();
bool ulanziBleBusy();
bool ulanziBleLinked();
const char* ulanziBleName();
size_t ulanziBleScan(UlanziFound* out, size_t cap, bool manageBusy = true);
bool ulanziBlePair(const char* name, const char* id, char* reason, size_t reasonCap);
bool ulanziBleAutoPair(char* reason, size_t reasonCap);  // 최대 2대 저장·첫 대 연결
bool ulanziBleApply(int brightness, int kelvin, bool on, char* reason, size_t reasonCap);
/// 저장 칸(0·1) 한 대만. 묶음이 아닙니다.
bool ulanziBleApplyIndex(uint8_t index, int brightness, int kelvin, bool on, char* reason, size_t reasonCap);
bool ulanziBleApplyAll(int brightness, int kelvin, bool on, char* reason, size_t reasonCap);
void ulanziBleFillList(JsonDocument& doc);
/// 저장된 울란지 2칸을 hello·응답에 넣습니다. 앱 개별 UI용입니다.
void ulanziBleFillSaved(JsonDocument& doc);
uint8_t ulanziBleSavedCount();
const char* ulanziBleSavedName(uint8_t index);
const char* ulanziBleSavedId(uint8_t index);
