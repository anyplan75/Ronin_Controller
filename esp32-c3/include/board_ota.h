#pragma once
#include <Arduino.h>

// 와이파이 OTA. USB는 최초·비상만. ArduinoOTA + HTTP /update.

void boardOtaBegin(const char* hostname);
void boardOtaLoop();
