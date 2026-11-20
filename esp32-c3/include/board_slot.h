#pragma once
#include <Arduino.h>

// 보드 담당은 빌드 기본값 + prefs(slot) 로 고정합니다. 역할을 섞지 않습니다.
// oled  = 로닌 RS2 전용 (+ OLED 상태)
// rmsid = 로닌 SC 전용
// s3    = 울란지 VL200BI 두 대(조명)

#ifndef FW_VERSION
#define FW_VERSION "1.0.46"
#endif

enum class BoardSlot : uint8_t { OledRs2 = 0, RmsidSc = 1, S3Light = 2 };

#if defined(BOARD_SLOT_OLED)
static constexpr BoardSlot kDefaultSlot = BoardSlot::OledRs2;
#elif defined(BOARD_SLOT_RMSID)
static constexpr BoardSlot kDefaultSlot = BoardSlot::RmsidSc;
#elif defined(BOARD_SLOT_S3)
static constexpr BoardSlot kDefaultSlot = BoardSlot::S3Light;
#else
static constexpr BoardSlot kDefaultSlot = BoardSlot::OledRs2;
#endif

inline const char* slotId(BoardSlot s) {
  switch (s) {
    case BoardSlot::OledRs2: return "oled";
    case BoardSlot::RmsidSc: return "rmsid";
    case BoardSlot::S3Light: return "s3";
  }
  return "oled";
}

inline const char* slotTitle(BoardSlot s) {
  switch (s) {
    case BoardSlot::OledRs2: return "OLED·RS2";
    case BoardSlot::RmsidSc: return "RMSID·SC";
    case BoardSlot::S3Light: return "S3·울란지";
  }
  return "OLED·RS2";
}

inline BoardSlot slotFromText(const char* text, BoardSlot fallback = kDefaultSlot) {
  if (text == nullptr) return fallback;
  if (strcmp(text, "oled") == 0 || strcmp(text, "rs2") == 0) return BoardSlot::OledRs2;
  if (strcmp(text, "rmsid") == 0 || strcmp(text, "sc") == 0) return BoardSlot::RmsidSc;
  if (strcmp(text, "s3") == 0 || strcmp(text, "light") == 0) return BoardSlot::S3Light;
  return fallback;
}

inline bool slotIsLight(BoardSlot s) { return s == BoardSlot::S3Light; }

// OLED=.152, S3=.153, RMSID=.154 — 서로 겹치지 않게.
inline const char* slotDefaultIp(BoardSlot s) {
  switch (s) {
    case BoardSlot::S3Light: return "192.168.10.153";
    case BoardSlot::RmsidSc: return "192.168.10.154";
    case BoardSlot::OledRs2: return "192.168.10.152";
  }
  return "192.168.10.152";
}

inline bool nameMatchesRs2(const char* lower) {
  if (lower == nullptr) return false;
  if (strstr(lower, "rs 2") || strstr(lower, "rs2")) return true;
  if (strstr(lower, "dji rs") && strstr(lower, "2")) return true;
  return false;
}

inline bool nameMatchesSc(const char* lower) {
  if (lower == nullptr) return false;
  if (strstr(lower, "ronin-sc") || strstr(lower, "ronin sc")) return true;
  if (strstr(lower, "rsc")) return true;
  // 이름에 ronin 이 있고 RS 계열이 아니면 SC 후보로 봅니다.
  if (strstr(lower, "ronin") && !nameMatchesRs2(lower) && !strstr(lower, "rs 3") &&
      !strstr(lower, "rs3") && !strstr(lower, "rs 4") && !strstr(lower, "rs4") &&
      !strstr(lower, "ronin-olimex") && !strstr(lower, "ronin-c3")) {
    return true;
  }
  return false;
}

inline bool nameMatchesSlot(BoardSlot s, const char* lower) {
  if (s == BoardSlot::OledRs2) return nameMatchesRs2(lower);
  if (s == BoardSlot::RmsidSc) return nameMatchesSc(lower);
  return false;
}
