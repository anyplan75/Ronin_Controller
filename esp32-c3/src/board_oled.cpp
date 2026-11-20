#include "board_oled.h"

#include <Arduino.h>

// OLED 배선(SDA/SCL)이 확정되기 전에는 I2C 를 건드리지 않습니다.
// 잘못된 버스로 Wire.begin 하면 C3 전체가 멈추는 경우가 있어,
// 화면은 oledReady=0 으로 두고 망·로닌 검증을 먼저 합니다.

static bool enabled = false;
static bool ready = false;

void boardOledBegin(bool want) {
  enabled = want;
  ready = false;
  if (!enabled) return;
  Serial.println("OLED 화면은 핀 확인 전이라 아직 켜지 않습니다(oledReady=0).");
}

bool boardOledReady() { return ready; }

void boardOledShow(const char* line1, const char* line2, const char* line3) {
  (void)line1;
  (void)line2;
  (void)line3;
  (void)enabled;
}
