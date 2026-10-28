#include "sony_remote.h"

#include <HTTPClient.h>
#include <Preferences.h>
#include <WiFi.h>

namespace {
constexpr uint32_t kWifiRetryMs = 15000;
constexpr uint16_t kHttpTimeoutMs = 5000;

Preferences prefs;
}  // namespace

void SonyRemote::begin() {
  prefs.begin("sony", false);
  ssid_ = prefs.getString("ssid", "");
  pass_ = prefs.getString("pass", "");
  host_ = prefs.getString("host", "192.168.122.1");
  if (ssid_.length()) {
    connectWifi();
  } else {
    Serial.println("A7M2: /sony/connect?ssid=DIRECT-xxxx&pass=비밀번호 로 카메라 Wi-Fi를 저장하세요.");
  }
}

void SonyRemote::loop() {
  if (!ssid_.length() || wifiConnected()) {
    return;
  }
  if (millis() - lastWifiAttemptMs_ < kWifiRetryMs) {
    return;
  }
  connectWifi();
}

bool SonyRemote::wifiConnected() const {
  return WiFi.status() == WL_CONNECTED;
}

bool SonyRemote::saveAndConnect(const String& ssid, const String& pass, const String& host) {
  ssid_ = ssid;
  pass_ = pass;
  if (host.length()) {
    host_ = host;
  }
  prefs.putString("ssid", ssid_);
  prefs.putString("pass", pass_);
  prefs.putString("host", host_);
  ready_ = false;
  apiList_ = "";
  return connectWifi();
}

bool SonyRemote::connectWifi() {
  lastWifiAttemptMs_ = millis();
  if (!ssid_.length()) {
    lastError_ = "ssid empty";
    return false;
  }
  Serial.printf("A7M2 Wi-Fi 연결 중: %s\n", ssid_.c_str());
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid_.c_str(), pass_.c_str());

  const uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 8000) {
    delay(200);
  }
  if (WiFi.status() != WL_CONNECTED) {
    lastError_ = "wifi connect failed";
    Serial.println("A7M2 Wi-Fi 실패. 카메라에서 Smart Remote를 켜고 SSID/암호를 확인하세요.");
    return false;
  }
  Serial.printf("A7M2 Wi-Fi OK  sta=%s  cam=%s\n", WiFi.localIP().toString().c_str(), host_.c_str());
  return true;
}

bool SonyRemote::rpc(const char* method, const char* params, String* response) {
  if (!wifiConnected()) {
    lastError_ = "wifi not connected";
    return false;
  }

  String url = "http://" + host_ + ":8080/sony/camera";
  String body = "{\"method\":\"";
  body += method;
  body += "\",\"params\":";
  body += params;
  body += ",\"id\":1,\"version\":\"1.0\"}";

  WiFiClient client;
  HTTPClient http;
  http.setTimeout(kHttpTimeoutMs);
  if (!http.begin(client, url)) {
    lastError_ = "http begin failed";
    return false;
  }
  http.addHeader("Content-Type", "application/json");
  const int code = http.POST(body);
  const String payload = http.getString();
  http.end();

  if (code != 200) {
    lastError_ = String(method) + " http " + String(code) + " " + payload;
    Serial.println(lastError_);
    return false;
  }
  if (payload.indexOf("\"error\"") >= 0) {
    lastError_ = String(method) + " " + payload;
    Serial.println(lastError_);
    return false;
  }
  lastError_ = "";
  if (response) {
    *response = payload;
  }
  return true;
}

bool SonyRemote::hasApi(const char* name) const {
  return apiList_.indexOf(name) >= 0;
}

bool SonyRemote::ensureReady() {
  if (!wifiConnected() && !connectWifi()) {
    return false;
  }

  String unused;
  rpc("startRecMode", "[]", &unused);
  delay(400);
  if (!rpc("getAvailableApiList", "[]", &apiList_)) {
    ready_ = false;
    return false;
  }
  ready_ = true;
  Serial.println(apiList_);
  return true;
}

bool SonyRemote::startRecord() {
  if (!ensureReady()) {
    return false;
  }
  if (hasApi("setShootMode")) {
    rpc("setShootMode", "[\"movie\"]", nullptr);
    delay(200);
    rpc("getAvailableApiList", "[]", &apiList_);
  }
  if (!hasApi("startMovieRec")) {
    lastError_ =
        "startMovieRec unavailable. Install/start Smart Remote Control on the A7M2, "
        "or use movie mode + photo shutter.";
    return false;
  }
  if (!rpc("startMovieRec", "[]", nullptr)) {
    return false;
  }
  recording_ = true;
  return true;
}

bool SonyRemote::stopRecord() {
  if (!wifiConnected() && !connectWifi()) {
    return false;
  }
  if (!rpc("stopMovieRec", "[]", nullptr)) {
    return false;
  }
  recording_ = false;
  return true;
}

bool SonyRemote::toggleRecord() {
  return recording_ ? stopRecord() : startRecord();
}

bool SonyRemote::takePhoto() {
  if (!ensureReady()) {
    return false;
  }
  if (hasApi("setShootMode")) {
    rpc("setShootMode", "[\"still\"]", nullptr);
    delay(200);
  }
  if (!hasApi("actTakePicture") && !ensureReady()) {
    lastError_ = "actTakePicture unavailable";
    return false;
  }
  rpc("getAvailableApiList", "[]", &apiList_);
  if (!hasApi("actTakePicture")) {
    lastError_ = "actTakePicture unavailable";
    return false;
  }
  return rpc("actTakePicture", "[]", nullptr);
}
