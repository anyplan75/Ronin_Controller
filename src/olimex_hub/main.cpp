#include <Arduino.h>
#include <ArduinoJson.h>
#include <AsyncTCP.h>
#include <ETH.h>
#include <ESPAsyncWebServer.h>
#include <NimBLEDevice.h>
#include <WiFi.h>

#include "dji_ble.h"
#include "gopro_ble_frame.h"

#if __has_include("wifi_local.h")
#include "wifi_local.h"
#define HUB_HAS_WIFI 1
#else
#define HUB_HAS_WIFI 0
#endif

// 올리멕스 ESP32-PoE 액션캠 허브입니다. 로닌 CAN 은 다루지 않습니다.
// 웹소켓 81번은 이더넷, 같은 와이파이, 기판 핫스팟에서 같이 엽니다.

static AsyncWebServer server(81);
static AsyncWebSocket socket("/");

struct HubCam {
  char id[40];
  char name[48];
  char kind[24];
  char ble[8];
  bool used;
};

struct HubJob {
  int index;
  bool start;
  bool tally;
  bool used;
};

static HubCam cams[8];
static HubJob jobs[8];
static int jobCount = 0;
static bool busy = false;
static uint16_t djiSeq = 1;
static bool ethReady = false;

static void sendText(const String& text) { socket.textAll(text); }

static void tallyNote(const char* note) {
  JsonDocument doc;
  doc["tally"]["note"] = note;
  String out;
  serializeJson(doc, out);
  sendText(out);
}

static void publish() {
  JsonDocument doc;
  JsonArray list = doc["cameras"].to<JsonArray>();
  for (const HubCam& cam : cams) {
    if (!cam.used) continue;
    JsonObject row = list.add<JsonObject>();
    row["id"] = cam.id;
    row["name"] = cam.name;
    row["kind"] = cam.kind;
    row["ble"] = cam.ble;
  }
  if (ethReady) {
    doc["host"] = ETH.localIP().toString();
  }
  doc["port"] = 81;
  String out;
  serializeJson(doc, out);
  sendText(out);
}

static void copyField(char* dest, size_t cap, const char* src) {
  if (src == nullptr) src = "";
  strncpy(dest, src, cap - 1);
  dest[cap - 1] = 0;
}

static int findCam(const char* id) {
  for (int i = 0; i < 8; i++) {
    if (cams[i].used && strcmp(cams[i].id, id) == 0) return i;
  }
  return -1;
}

static void remember(JsonObject row) {
  const char* id = row["id"] | "";
  const char* name = row["name"] | "";
  if (id[0] == 0 || name[0] == 0) return;
  int slot = findCam(id);
  if (slot < 0) {
    for (int i = 0; i < 8; i++) {
      if (!cams[i].used) {
        slot = i;
        break;
      }
    }
  }
  if (slot < 0) return;
  cams[slot].used = true;
  copyField(cams[slot].id, sizeof(cams[slot].id), id);
  copyField(cams[slot].name, sizeof(cams[slot].name), name);
  copyField(cams[slot].kind, sizeof(cams[slot].kind), row["kind"] | "");
  copyField(cams[slot].ble, sizeof(cams[slot].ble), row["ble"] | "FEA6");
}

static void enqueue(int index, bool start, bool tally) {
  if (index < 0 || jobCount >= 8) return;
  jobs[jobCount++] = HubJob{index, start, tally, true};
}

static bool nameMatches(NimBLEAdvertisedDevice& device, const char* name) {
  if (name == nullptr || name[0] == 0) return false;
  std::string seen = device.getName();
  if (seen.empty()) return false;
  return seen == name || seen.find(name) != std::string::npos || strstr(name, seen.c_str()) != nullptr;
}

static NimBLEAddress findAddress(const char* name, const char* service) {
  NimBLEScan* scan = NimBLEDevice::getScan();
  scan->setActiveScan(true);
  scan->start(3, false);
  NimBLEScanResults results = scan->getResults();
  NimBLEAddress found;
  for (int i = 0; i < results.getCount(); i++) {
    NimBLEAdvertisedDevice device = results.getDevice(i);
    if (nameMatches(device, name)) {
      found = device.getAddress();
      break;
    }
  }
  scan->clearResults();
  (void)service;
  return found;
}

static bool writeGoPro(NimBLEClient* client, bool start, bool tallyOn, bool doTally, char* note, size_t noteCap) {
  NimBLERemoteService* service = client->getService(NimBLEUUID((uint16_t)0xFEA6));
  if (service == nullptr) {
    snprintf(note, noteCap, "고프로 서비스 FEA6 를 찾지 못했습니다.");
    return false;
  }
  GoproBytes frame;
  bool wrote = false;
  if (!doTally || start) {
    if (!goproShutterFrame(start, &frame)) return false;
    NimBLERemoteCharacteristic* command = service->getCharacteristic(
        NimBLEUUID("b5f90072-aa8d-11e3-9046-0002a5d5c51b"));
    if (command == nullptr || !command->writeValue(frame.data, frame.length, false)) {
      snprintf(note, noteCap, "고프로 셔터를 쓰지 못했습니다. 성공으로 두지 않습니다.");
      return false;
    }
    wrote = true;
  }
  if (doTally) {
    if (!goproSettingFrame(91, tallyOn ? 4 : 0, &frame)) return false;
    NimBLERemoteCharacteristic* setting = service->getCharacteristic(
        NimBLEUUID("b5f90074-aa8d-11e3-9046-0002a5d5c51b"));
    if (setting == nullptr || !setting->writeValue(frame.data, frame.length, false)) {
      snprintf(note, noteCap, "고프로 LED 설정을 쓰지 못했습니다. 앞 화면 글자는 보내지 않았습니다.");
      return false;
    }
    wrote = true;
  }
  if (wrote) {
    snprintf(note, noteCap, "고프로에 셔터 또는 LED 설정을 썼습니다. 카메라가 상태 0으로 답했는지는 확인하지 못했습니다. 앞 화면 글자는 보내지 않았습니다.");
  }
  return wrote;
}

static uint32_t osmoDeviceId(const char* name) {
  String text = name == nullptr ? "" : name;
  text.toLowerCase();
  if (text.indexOf("360") >= 0) return 0xFF660000;
  if (text.indexOf("action 6") >= 0 || text.indexOf("action6") >= 0) return 0xFF550000;
  if (text.indexOf("action 4") >= 0 || text.indexOf("action4") >= 0) return 0xFF330000;
  return 0xFF440000;
}

static bool writeOsmo(NimBLEClient* client, const char* name, bool start, char* note, size_t noteCap) {
  NimBLERemoteService* service = client->getService(NimBLEUUID((uint16_t)0xFFF0));
  if (service == nullptr) {
    snprintf(note, noteCap, "오즈모 서비스 FFF0 를 찾지 못했습니다.");
    return false;
  }
  NimBLERemoteCharacteristic* write = service->getCharacteristic(NimBLEUUID((uint16_t)0xFFF5));
  if (write == nullptr) {
    snprintf(note, noteCap, "오즈모 쓰기 특성 FFF5 를 찾지 못했습니다.");
    return false;
  }
  uint32_t device = osmoDeviceId(name);
  uint8_t payload[9] = {
      (uint8_t)device, (uint8_t)(device >> 8), (uint8_t)(device >> 16), (uint8_t)(device >> 24),
      (uint8_t)(start ? 0x00 : 0x01), 0, 0, 0, 0};
  uint8_t frame[40];
  size_t len = djiBuild(frame, sizeof(frame), 0x1D, 0x03, 0x01, djiSeq++, payload, sizeof(payload));
  if (len == 0 || !write->writeValue(frame, len, false)) {
    snprintf(note, noteCap, "오즈모 녹화 프레임을 쓰지 못했습니다. 성공으로 두지 않습니다.");
    return false;
  }
  snprintf(note, noteCap, "오즈모 녹화 프레임을 썼습니다. 카메라 응답은 확인하지 못했습니다.");
  return true;
}

static void runJob(const HubJob& job) {
  const HubCam& cam = cams[job.index];
  char note[180] = "명령을 끝내지 못했습니다.";
  const char* service = "FEA6";
  if (strcmp(cam.ble, "FFF0") == 0) service = "FFF0";
  if (strcmp(cam.ble, "CE80") == 0) service = "CE80";
  if (strcmp(cam.ble, "CE80") == 0) {
    tallyNote("인스타360 은 목록만 둡니다. 확인된 셔터 명령이 없어 보내지 않았습니다.");
    return;
  }
  NimBLEAddress address = findAddress(cam.name, service);
  if (address.toString().empty() || address.toString() == "00:00:00:00:00:00") {
    snprintf(note, sizeof(note), "%s 블루투스를 찾지 못했습니다. 명령을 보내지 않았습니다.", cam.name);
    tallyNote(note);
    return;
  }
  NimBLEClient* client = NimBLEDevice::createClient();
  if (client == nullptr || !client->connect(address)) {
    snprintf(note, sizeof(note), "%s 에 붙지 못했습니다.", cam.name);
    tallyNote(note);
    if (client != nullptr) NimBLEDevice::deleteClient(client);
    return;
  }
  bool ok = false;
  if (strcmp(cam.ble, "FFF0") == 0) {
    ok = writeOsmo(client, cam.name, job.start, note, sizeof(note));
  } else {
    ok = writeGoPro(client, job.start, job.start || job.tally, job.tally || job.start, note, sizeof(note));
  }
  client->disconnect();
  NimBLEDevice::deleteClient(client);
  if (!ok && note[0] == 0) {
    snprintf(note, sizeof(note), "%s 명령을 끝내지 못했습니다.", cam.name);
  }
  tallyNote(note);
  (void)ok;
}

static void pump() {
  if (busy || jobCount == 0) return;
  busy = true;
  HubJob job = jobs[0];
  for (int i = 1; i < jobCount; i++) jobs[i - 1] = jobs[i];
  jobCount--;
  runJob(job);
  busy = false;
  publish();
}

static void handleText(const char* text) {
  JsonDocument doc;
  if (deserializeJson(doc, text)) return;
  const char* op = doc["op"] | "";
  if (strcmp(op, "record") == 0 || strcmp(op, "record-one") == 0) {
    bool start = doc["start"] | false;
    bool tally = doc["tally"] | start;
    JsonArray ids = doc["ids"].as<JsonArray>();
    if (strcmp(op, "record-one") == 0) {
      remember(doc.as<JsonObject>());
      int index = findCam(doc["id"] | "");
      enqueue(index, start, tally);
    } else if (!ids.isNull()) {
      for (JsonVariant id : ids) {
        int index = findCam(id.as<const char*>());
        enqueue(index, start, tally);
      }
    } else {
      for (int i = 0; i < 8; i++) {
        if (cams[i].used) enqueue(i, start, tally);
      }
    }
    return;
  }
  if (strcmp(op, "tally") == 0) {
    remember(doc.as<JsonObject>());
    enqueue(findCam(doc["id"] | ""), doc["on"] | false, true);
    return;
  }
  if (strcmp(op, "camera") == 0) {
    remember(doc.as<JsonObject>());
    tallyNote("이 허브는 화각과 해상도 설정을 카메라에 쓰지 않습니다. 화면의 화각은 프리셋입니다.");
    publish();
  }
}

static void onEvent(AsyncWebSocket*, AsyncWebSocketClient* client, AwsEventType type, void*, uint8_t* data, size_t len) {
  if (type == WS_EVT_CONNECT) {
    publish();
    return;
  }
  if (type != WS_EVT_DATA || data == nullptr || len == 0 || len > 1200) return;
  char text[1201];
  memcpy(text, data, len);
  text[len] = 0;
  (void)client;
  handleText(text);
}

static void banner() {
  Serial.println();
  Serial.println("올리멕스 액션캠 허브");
  Serial.println("PoE 192.168.0.150 웹소켓 81");
  Serial.println("핫스팟 Ronin-Olimex 192.168.4.1 웹소켓 81");
#if HUB_HAS_WIFI
  Serial.println("같은 와이파이 192.168.0.151 웹소켓 81");
#else
  Serial.println("비밀 파일이 없어 같은 와이파이는 건너뜁니다.");
#endif
  Serial.println("고프로 FEA6, 오즈모 FFF0, 인스타360 은 목록만. 앞 화면 글자는 보내지 않습니다.");
}

void setup() {
  Serial.begin(115200);
  delay(400);
  banner();
  NimBLEDevice::init("Ronin-Olimex");
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAPConfig(IPAddress(192, 168, 4, 1), IPAddress(192, 168, 4, 1), IPAddress(255, 255, 255, 0));
  WiFi.softAP("Ronin-Olimex");
#if HUB_HAS_WIFI
  WiFi.config(IPAddress(192, 168, 0, 151), IPAddress(192, 168, 0, 1), IPAddress(255, 255, 255, 0));
  WiFi.begin(WIFI_SSID_1, WIFI_PASS);
#else
  WiFi.disconnect(true);
#endif
  WiFi.onEvent([](arduino_event_id_t event) {
    if (event == ARDUINO_EVENT_ETH_GOT_IP) ethReady = true;
    if (event == ARDUINO_EVENT_ETH_DISCONNECTED) ethReady = false;
  });
  if (ETH.begin()) {
    ETH.config(IPAddress(192, 168, 0, 150), IPAddress(192, 168, 0, 1), IPAddress(255, 255, 255, 0));
    Serial.println("이더넷 초기화를 시작했습니다.");
  } else {
    Serial.println("이더넷 초기화에 실패했습니다.");
  }
  socket.onEvent(onEvent);
  server.addHandler(&socket);
  server.begin();
  Serial.println("웹소켓 81번을 열었습니다.");
}

void loop() {
  pump();
  socket.cleanupClients();
  delay(20);
}
