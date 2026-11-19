#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
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

static const char* kProvService = "7b1e9c10-5a20-4c31-8d10-726f6e696e31";
static const char* kProvChar = "7b1e9c11-5a20-4c31-8d10-726f6e696e31";
static NimBLECharacteristic* provChar = nullptr;
static bool joinAsked = false;
static String joinSsid;
static String joinPass;
static String joinIp;

static bool fixedLan(const String& text, IPAddress* out) {
  IPAddress ip;
  if (text.isEmpty() || !ip.fromString(text)) return false;
  if (ip[0] != 192 || ip[1] != 168 || ip[2] != 10) return false;
  if (ip[3] == 0 || ip[3] == 255) return false;
  *out = ip;
  return true;
}

static void tellProvision(const char* json) {
  if (provChar == nullptr) return;
  provChar->setValue(json);
  provChar->notify();
}

class ProvCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic) override {
    JsonDocument doc;
    std::string raw = characteristic->getValue();
    if (deserializeJson(doc, raw)) {
      tellProvision("{\"ok\":false,\"reason\":\"설정을 읽지 못했습니다.\"}");
      return;
    }
    joinSsid = doc["ssid"] | "";
    joinPass = doc["pass"] | "";
    joinIp = doc["ip"] | "";
    if (joinSsid.isEmpty()) {
      tellProvision("{\"ok\":false,\"reason\":\"와이파이 이름이 없습니다.\"}");
      return;
    }
    IPAddress ignore;
    if (!joinIp.isEmpty() && !fixedLan(joinIp, &ignore)) {
      tellProvision("{\"ok\":false,\"reason\":\"고정 주소는 192.168.10.1 부터 254 사이만 됩니다.\"}");
      return;
    }
    joinAsked = true;
  }
};

static void startProvision() {
  NimBLEDevice::init("Ronin-C3");
  NimBLEServer* server = NimBLEDevice::createServer();
  NimBLEService* service = server->createService(kProvService);
  provChar = service->createCharacteristic(
      kProvChar, NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY, 240);
  provChar->setCallbacks(new ProvCallbacks());
  service->start();
  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(kProvService);
  advertising->start();
  Serial.println("블루투스 이름 Ronin-C3. 처음 설정은 이 이름으로 받습니다.");
}

static bool beginStation(const String& ssid, const String& pass, const String& ipText) {
  IPAddress ip;
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAPConfig(IPAddress(192, 168, 4, 1), IPAddress(192, 168, 4, 1), IPAddress(255, 255, 255, 0));
  WiFi.softAP("Ronin-C3");
  if (fixedLan(ipText, &ip)) {
    WiFi.config(ip, IPAddress(192, 168, 10, 1), IPAddress(255, 255, 255, 0));
  } else {
    WiFi.config(IPAddress(0, 0, 0, 0), IPAddress(0, 0, 0, 0), IPAddress(0, 0, 0, 0));
  }
  WiFi.begin(ssid.c_str(), pass.c_str());
  Serial.println("와이파이에 붙는 중입니다. 비밀번호는 찍지 않습니다.");
  const uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 12000) {
    delay(200);
  }
  return WiFi.status() == WL_CONNECTED;
}

static void finishJoin() {
  joinAsked = false;
  prefs.putString("wifiSsid", joinSsid);
  prefs.putString("wifiPass", joinPass);
  prefs.putString("wifiIp", joinIp);
  prefs.putString("mode", "lan");
  if (!beginStation(joinSsid, joinPass, joinIp)) {
    tellProvision("{\"ok\":false,\"reason\":\"그 와이파이에 붙지 못했습니다. 핫스팟 Ronin-C3 는 그대로입니다.\"}");
    return;
  }
  const String ip = WiFi.localIP().toString();
  String note = "{\"ok\":true,\"ip\":\"" + ip + "\",\"port\":82}";
  tellProvision(note.c_str());
  Serial.print("같은 와이파이 주소 ");
  Serial.println(ip);
}

static void banner() {
  Serial.println();
  Serial.println("C3 단일 작업 기판");
  Serial.print("맡은 일: ");
  Serial.println(job == "light" ? "울란지 조명" : "로닌 제어");
  Serial.println("핫스팟 Ronin-C3 192.168.4.1 웹소켓 82");
  Serial.println("같은 와이파이 기본 192.168.10.152 웹소켓 82. 블루투스 설정이 있으면 그 주소를 씁니다.");
  Serial.println("로닌 CAN 은 시작하지 않습니다. 울란지 명령도 성공으로 답하지 않습니다.");
}

static void applyMode(const char* mode) {
  if (mode != nullptr && strcmp(mode, "ap") == 0) {
    prefs.putString("mode", "ap");
    WiFi.mode(WIFI_AP);
    WiFi.softAPConfig(IPAddress(192, 168, 4, 1), IPAddress(192, 168, 4, 1), IPAddress(255, 255, 255, 0));
    WiFi.softAP("Ronin-C3");
    Serial.println("핫스팟 Ronin-C3 로 바꿨습니다.");
    return;
  }
  prefs.putString("mode", "lan");
  if (prefs.isKey("wifiSsid")) {
    beginStation(prefs.getString("wifiSsid", ""), prefs.getString("wifiPass", ""), prefs.getString("wifiIp", ""));
    return;
  }
#if C3_HAS_WIFI
  Serial.println("저장된 설정이 없어 비밀 파일의 와이파이로 붙습니다. 비밀번호는 찍지 않습니다.");
  beginStation(WIFI_SSID_1, WIFI_PASS, "192.168.10.152");
#else
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAPConfig(IPAddress(192, 168, 4, 1), IPAddress(192, 168, 4, 1), IPAddress(255, 255, 255, 0));
  WiFi.softAP("Ronin-C3");
  Serial.println("저장된 와이파이가 없습니다. 블루투스 Ronin-C3 로 처음 설정을 받으세요.");
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
  startProvision();
  String mode = prefs.isKey("mode") ? prefs.getString("mode", "lan") : "lan";
  applyMode(mode.c_str());
  socket.begin();
  socket.onEvent(onEvent);
  Serial.println("웹소켓 82번을 열었습니다.");
}

void loop() {
  if (joinAsked) finishJoin();
  socket.loop();
  (void)clientUp;
}
