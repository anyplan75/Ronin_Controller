#include "hub_ota.h"

#include <Update.h>
#include <WebServer.h>
#include <WiFi.h>
#include <ETH.h>

#ifndef HUB_FW_VERSION
#define HUB_FW_VERSION "1.0.62"
#endif

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

void hubOtaBegin() {
  if (started) return;
  // 와이파이 또는 PoE 이더넷이 붙으면 80번을 엽니다(같은 LAN에서 curl OTA).
  if (WiFi.status() != WL_CONNECTED && !ETH.linkUp()) return;

  http.on("/version", HTTP_GET, []() {
    String body = String("{\"fw\":\"") + HUB_FW_VERSION + "\"}";
    http.send(200, "application/json", body);
  });
  http.on("/update", HTTP_GET, []() {
    http.send(200, "text/html",
              "<html><body><h1>Ronin Olimex OTA</h1>"
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
  Serial.println("OTA http://ip/update · /version (80)");
}

void hubOtaLoop() {
  if (!started) {
    hubOtaBegin();
    return;
  }
  http.handleClient();
}
