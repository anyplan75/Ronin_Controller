#include "board_oled.h"

#include <Wire.h>

#if __has_include(<U8g2lib.h>)
#include <U8g2lib.h>
#define BOARD_HAS_U8G2 1
#else
#define BOARD_HAS_U8G2 0
#endif

static bool enabled = false;
static bool ready = false;

#if BOARD_HAS_U8G2
// 흔한 ESP32-C3 0.42" OLED: SDA GPIO5, SCL GPIO6, 72x40
static U8G2_SSD1306_72X40_ER_F_HW_I2C u8g2(U8G2_R0, U8X8_PIN_NONE, 6, 5);
#endif

void boardOledBegin(bool want) {
  enabled = want;
  ready = false;
  if (!enabled) return;
#if BOARD_HAS_U8G2
  Wire.setTimeOut(50);
  Wire.begin(5, 6);
  Wire.beginTransmission(0x3C);
  if (Wire.endTransmission() != 0) {
    Serial.println("OLED(0x3C) 없음. 상태 화면은 끕니다.");
    return;
  }
  if (!u8g2.begin()) {
    Serial.println("OLED 시작 실패. 상태 화면은 끕니다.");
    return;
  }
  u8g2.setContrast(255);
  u8g2.setBusClock(400000);
  ready = true;
  boardOledShow("OLED RS2", "starting", "");
  Serial.println("OLED 상태 화면을 켰습니다.");
#else
  Serial.println("U8g2 가 없어 OLED 를 켜지 않습니다.");
#endif
}

bool boardOledReady() { return ready; }

void boardOledShow(const char* line1, const char* line2, const char* line3) {
  if (!ready) return;
#if BOARD_HAS_U8G2
  u8g2.clearBuffer();
  u8g2.setFont(u8g2_font_5x8_tr);
  if (line1 && line1[0]) u8g2.drawStr(0, 10, line1);
  if (line2 && line2[0]) u8g2.drawStr(0, 22, line2);
  if (line3 && line3[0]) u8g2.drawStr(0, 34, line3);
  u8g2.sendBuffer();
#else
  (void)line1;
  (void)line2;
  (void)line3;
#endif
}
