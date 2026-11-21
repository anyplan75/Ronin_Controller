#include "board_ota.h"

#include <Update.h>
#include <WebServer.h>
#include <WiFi.h>

#include "board_slot.h"

// ArduinoOTA(mDNS) 빼고 HTTP /update 만 — 플래시 절약. USB 비상 플래시는 그대로.

static WebServer http(80);
static bool started = false;

static void handleUpdate() {
  HTTPUpload& upload = http.upload();
  if (upload.status == UPLOAD_FILE_START) {
    if (!Update.begin(UPDATE_SIZE_UNKNOWN)) Update.printError(Serial);
  } else if (upload.status == UPLOAD_FILE_WRITE) {
    if (Update.write(upload.buf, upload.currentSize) != upload.currentSize) Update.printError(Serial);
  } else if (upload.status == UPLOAD_FILE_END) {
    if (!Update.end(true)) Update.printError(Serial);
  }
}

void boardOtaBegin(const char* /*hostname*/) {
  if (WiFi.status() != WL_CONNECTED) return;
  if (started) return;

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
}

void boardOtaLoop() {
  if (!started) {
    if (WiFi.status() == WL_CONNECTED) boardOtaBegin("Ronin-Board");
    return;
  }
  http.handleClient();
}
