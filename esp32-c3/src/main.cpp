#include <Arduino.h>
#include <ArduinoJson.h>
#include <Preferences.h>
#include <WebSocketsServer.h>
#include <WiFi.h>

#if __has_include("wifi_local.h")
#include "wifi_local.h"
#define C3_HAS_WIFI 1
#else
#define C3_HAS_WIFI 0
#endif

// C3 는 로닌 제어 또는 울란지 조명 중 하나만 합니다. 액션 카메라 중계가 아닙니다.
// CAN 은 시작하지 않고, 울란지 프로토콜도 없습니다. 둘 다 ack false 로 답합니다.

static WebSocketsServer socket(82);
static Preferences prefs;
static String job = "ronin";
static bool clientUp = false;

static void reply(uint8_t num, bool ack, const char* reason) {
  JsonDocument doc;
  doc["ack"] = ack;
  doc["reason"] = reason;
  doc["job"] = job;
  String out;
  serializeJson(doc, out);
  socket.sendTXT(num, out);
}

static void banner() {
  Serial.println();
  Serial.println("C3 단일 작업 기판");
  Serial.print("맡은 일: ");
  Serial.println(job == "light" ? "울란지 조명" : "로닌 제어");
  Serial.println("핫스팟 Ronin-C3 192.168.4.1 웹소켓 82");
#if C3_HAS_WIFI
  Serial.println("같은 와이파이 192.168.0.152 웹소켓 82");
#else
  Serial.println("비밀 파일이 없어 같은 와이파이는 건너뜁니다.");
#endif
  Serial.println("로닌 CAN 은 시작하지 않습니다. 울란지 명령도 성공으로 답하지 않습니다.");
}

static void applyMode(const char* mode) {
  WiFi.softAPdisconnect(true);
  WiFi.disconnect(true);
  delay(50);
  if (mode != nullptr && strcmp(mode, "ap") == 0) {
    prefs.putString("mode", "ap");
    WiFi.mode(WIFI_AP);
    WiFi.softAPConfig(IPAddress(192, 168, 4, 1), IPAddress(192, 168, 4, 1), IPAddress(255, 255, 255, 0));
    WiFi.softAP("Ronin-C3");
    Serial.println("핫스팟 Ronin-C3 로 바꿨습니다.");
    return;
  }
  prefs.putString("mode", "lan");
  WiFi.mode(WIFI_STA);
#if C3_HAS_WIFI
  WiFi.config(IPAddress(192, 168, 0, 152), IPAddress(192, 168, 0, 1), IPAddress(255, 255, 255, 0));
  WiFi.begin(WIFI_SSID_1, WIFI_PASS);
  Serial.println("같은 와이파이로 붙는 중입니다.");
#else
  Serial.println("비밀 파일이 없어 같은 와이파이는 시작하지 않습니다.");
#endif
}

static void onEvent(uint8_t num, WStype_t type, uint8_t* payload, size_t length) {
  if (type == WStype_CONNECTED) {
    clientUp = true;
    reply(num, false, "연결만 되었습니다. 아직 명령을 수행하지 않았습니다.");
    return;
  }
  if (type == WStype_DISCONNECTED) {
    clientUp = false;
    return;
  }
  if (type != WStype_TEXT || payload == nullptr) return;
  JsonDocument doc;
  if (deserializeJson(doc, payload, length)) {
    reply(num, false, "명령을 읽지 못했습니다.");
    return;
  }
  const char* op = doc["op"] | "";
  if (strcmp(op, "job") == 0) {
    const char* next = doc["job"] | "ronin";
    job = strcmp(next, "light") == 0 ? "light" : "ronin";
    prefs.putString("job", job);
    reply(num, true, job == "light" ? "조명만 맡도록 저장했습니다." : "로닌 제어만 맡도록 저장했습니다.");
    banner();
    return;
  }
  if (strcmp(op, "mode") == 0) {
    applyMode(doc["mode"] | "lan");
    reply(num, true, "연결 방식을 저장했습니다. 웹소켓은 잠깐 끊길 수 있습니다.");
    return;
  }
  if (strcmp(op, "ronin") == 0) {
    if (job != "ronin") {
      reply(num, false, "이 C3 는 로닌 제어가 아닙니다. 명령을 수행하지 않았습니다.");
      return;
    }
    reply(num, false, "CAN 을 시작하지 않았습니다. 팬과 틸트를 짐벌에 보내지 않았습니다.");
    return;
  }
  if (strcmp(op, "light") == 0) {
    if (job != "light") {
      reply(num, false, "이 C3 는 조명이 아닙니다. 명령을 수행하지 않았습니다.");
      return;
    }
    reply(num, false, "울란지 통신 절차가 없습니다. 밝기와 색온도를 보내지 않았습니다.");
    return;
  }
  reply(num, false, "이 기판이 받지 않는 명령입니다.");
}

void setup() {
  Serial.begin(115200);
  delay(400);
  prefs.begin("ronin-c3", false);
  job = prefs.getString("job", "ronin");
  if (job != "light") job = "ronin";
  banner();
  String mode = prefs.getString("mode", "lan");
  applyMode(mode.c_str());
  socket.begin();
  socket.onEvent(onEvent);
  Serial.println("웹소켓 82번을 열었습니다.");
}

void loop() {
  socket.loop();
  (void)clientUp;
}
