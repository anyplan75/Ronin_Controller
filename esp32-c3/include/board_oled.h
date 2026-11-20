#pragma once
#include <Arduino.h>

// OLED C3(0.42" SSD1306, SDA=5 SCL=6) 상태 표시. 화면이 없으면 조용히 끕니다.

void boardOledBegin(bool enabled);
void boardOledShow(const char* line1, const char* line2, const char* line3);
bool boardOledReady();
