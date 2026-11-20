#include "board_oled.h"

#include <Arduino.h>
#include <new>

#if __has_include(<U8g2lib.h>)
#include <U8g2lib.h>
#define BOARD_HAS_U8G2 1
#else
#define BOARD_HAS_U8G2 0
#endif

// 하드웨어 Wire 는 이 보드에서 버스 잠김이 있어 쓰지 않습니다.
// 소프트웨어 I2C 만, 비트마다 짧은 시간제한으로 조사합니다.

static bool enabled = false;
static bool ready = false;
static int usedSda = -1;
static int usedScl = -1;

#if BOARD_HAS_U8G2
static U8G2_SSD1306_72X40_ER_F_SW_I2C* u8g2 = nullptr;
static uint8_t u8g2Mem[sizeof(U8G2_SSD1306_72X40_ER_F_SW_I2C)];

static const int kPairs[][2] = {
    {5, 6}, {8, 9}, {6, 7}, {4, 5}, {1, 0}, {10, 8}, {3, 2},
};

static void sdaOut(int sda, bool hi) {
  pinMode(sda, OUTPUT);
  digitalWrite(sda, hi ? HIGH : LOW);
}
static void sclOut(int scl, bool hi) {
  pinMode(scl, OUTPUT);
  digitalWrite(scl, hi ? HIGH : LOW);
}
static void sdaIn(int sda) { pinMode(sda, INPUT_PULLUP); }
static void sclIn(int scl) { pinMode(scl, INPUT_PULLUP); }

static void delayHalf() { delayMicroseconds(5); }

static bool waitHigh(int pin, uint32_t usCap) {
  uint32_t start = micros();
  while (digitalRead(pin) == LOW) {
    if ((micros() - start) > usCap) return false;
  }
  return true;
}

static bool softStart(int sda, int scl) {
  sdaIn(sda);
  sclIn(scl);
  if (!waitHigh(sda, 200) || !waitHigh(scl, 200)) return false;
  delayHalf();
  sdaOut(sda, false);
  delayHalf();
  sclOut(scl, false);
  delayHalf();
  return true;
}

static void softStop(int sda, int scl) {
  sdaOut(sda, false);
  delayHalf();
  sclOut(scl, true);
  if (!waitHigh(scl, 200)) return;
  delayHalf();
  sdaOut(sda, true);
  delayHalf();
  sdaIn(sda);
  sclIn(scl);
}

static bool softWriteByte(int sda, int scl, uint8_t value) {
  for (int i = 7; i >= 0; i--) {
    sdaOut(sda, (value >> i) & 1);
    delayHalf();
    sclOut(scl, true);
    if (!waitHigh(scl, 200)) return false;
    delayHalf();
    sclOut(scl, false);
    delayHalf();
  }
  sdaIn(sda);
  delayHalf();
  sclOut(scl, true);
  if (!waitHigh(scl, 200)) return false;
  delayHalf();
  bool ack = (digitalRead(sda) == LOW);
  sclOut(scl, false);
  delayHalf();
  return ack;
}

/// 0x3C 쓰기 주소로 ACK 이 오면 칩이 있다고 봅니다.
static bool softProbe(int sda, int scl) {
  if (!softStart(sda, scl)) {
    softStop(sda, scl);
    return false;
  }
  bool ok = softWriteByte(sda, scl, 0x3C << 1);
  softStop(sda, scl);
  return ok;
}
#endif

void boardOledBegin(bool want) {
  enabled = want;
  ready = false;
  usedSda = -1;
  usedScl = -1;
  if (!enabled) return;
#if BOARD_HAS_U8G2
  for (size_t i = 0; i < sizeof(kPairs) / sizeof(kPairs[0]); i++) {
    int sda = kPairs[i][0];
    int scl = kPairs[i][1];
    Serial.printf("OLED 조사 SDA=%d SCL=%d\n", sda, scl);
    if (!softProbe(sda, scl)) continue;
    u8g2 = new (u8g2Mem) U8G2_SSD1306_72X40_ER_F_SW_I2C(U8G2_R0, /*clock=*/scl, /*data=*/sda, U8X8_PIN_NONE);
    if (!u8g2->begin()) {
      Serial.printf("OLED begin 실패 SDA=%d SCL=%d\n", sda, scl);
      u8g2 = nullptr;
      continue;
    }
    u8g2->setContrast(255);
    usedSda = sda;
    usedScl = scl;
    ready = true;
    Serial.printf("OLED 상태 화면을 켰습니다. SDA=%d SCL=%d\n", usedSda, usedScl);
    boardOledShow("OLED RS2", "starting", "");
    return;
  }
  Serial.println("OLED(0x3C) 소프트웨어 I2C 후보에서 없음. oledReady=0");
#else
  Serial.println("U8g2 가 없어 OLED 를 켜지 않습니다.");
#endif
}

bool boardOledReady() { return ready; }

void boardOledShow(const char* line1, const char* line2, const char* line3) {
  if (!ready) return;
#if BOARD_HAS_U8G2
  if (u8g2 == nullptr) return;
  u8g2->clearBuffer();
  u8g2->setFont(u8g2_font_5x8_tr);
  if (line1 && line1[0]) u8g2->drawStr(0, 10, line1);
  if (line2 && line2[0]) u8g2->drawStr(0, 22, line2);
  if (line3 && line3[0]) u8g2->drawStr(0, 34, line3);
  u8g2->sendBuffer();
#else
  (void)line1;
  (void)line2;
  (void)line3;
#endif
}
