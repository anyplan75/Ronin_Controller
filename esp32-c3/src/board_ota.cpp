#include "board_ota.h"

#include <ArduinoOTA.h>
#include <Update.h>
#include <WebServer.h>
#include <WiFi.h>

#include "board_slot.h"

static WebServer http(80);
static bool started = false;

static void handleUpdate() {
  HTTPUpload& upload = http.upload();
  if (upload.status == UPLOAD_FILE_START) {
    Serial.printf("OTA 시작 %s\n", upload.filename.c_str());
    if (!Update.begin(UPDATE_SIZE_UNKNOWN)) Update.printError(Serial);
  } else if (upload.status == UPLOAD_FILE_WRITE) {
    if (Update.write(upload.buf, upload.currentSize) != upload.currentSize) Update.printError(Serial);
  } else if (upload.status == UPLOAD_FILE_END) {
    if (Update.end(true)) {
      Serial.printf("OTA 완료 %u 바이트\n", upload.totalSize);
    } else {
      Update.printError(Serial);
    }
  }
}

void boardOtaBegin(const char* hostname) {
  if (WiFi.status() != WL_CONNECTED) return;
  if (started) return;
  ArduinoOTA.setHostname(hostname && hostname[0] ? hostname : "Ronin-Board");
  ArduinoOTA.onStart([]() { Serial.println("ArduinoOTA 시작"); });
  ArduinoOTA.onEnd([]() { Serial.println("ArduinoOTA 끝"); });
  ArduinoOTA.onError([](ota_error_t e) { Serial.printf("ArduinoOTA 오류 %u\n", (unsigned)e); });
  ArduinoOTA.begin();

  http.on("/version", HTTP_GET, []() {
    String body = String("{\"fw\":\"") + FW_VERSION + "\"}";
    http.send(200, "application/json", body);
  });
  http.on("/update", HTTP_GET, []() {
    http.send(200, "text/html",
              "<html><body><h1>Ronin OTA</h1>"
              "<form method='POST' enctype='multipart/form-data'>"
              "<input type='file' name='update'><input type='submit' value='Upload'>"
              "</form></body></html>");
  });
  http.on(
      "/update", HTTP_POST,
      []() {
        http.sendHeader("Connection", "close");
        http.send(200, "text/plain", Update.hasError() ? "fail" : "ok");
        delay(200);
        if (!Update.hasError()) ESP.restart();
      },
      handleUpdate);
  http.begin();
  started = true;
  Serial.println("와이파이 OTA 준비: ArduinoOTA + http://ip/update");
}

void boardOtaLoop() {
  if (!started) {
    if (WiFi.status() == WL_CONNECTED) boardOtaBegin("Ronin-Board");
    return;
  }
  ArduinoOTA.handle();
  http.handleClient();
}
