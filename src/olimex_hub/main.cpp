#include <Arduino.h>
#include <ArduinoJson.h>
#include <AsyncTCP.h>
#include <ETH.h>
#include <ESPAsyncWebServer.h>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <WiFi.h>
#include <esp_netif.h>
#include <esp_wifi.h>

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
  char id[20];
  char name[40];
  char ble[8];
  uint8_t addrType;
  uint8_t kind;
  bool start;
  bool led;
  uint8_t setting;
  uint8_t option;
  bool used;
};

struct LiveCam {
  char id[20];
  char name[40];
  char kind[16];
  char ble[8];
  uint8_t addrType;
  bool used;
};

static HubCam cams[8];
static LiveCam liveCams[8];
static HubJob jobs[8];
static int jobCount = 0;
static bool busy = false;
static uint16_t djiSeq = 1;
static bool ethReady = false;
static String ethMacText;

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
  for (const LiveCam& cam : liveCams) {
    if (!cam.used || cam.name[0] == 0) continue;
    JsonObject row = list.add<JsonObject>();
    row["id"] = cam.id;
    row["name"] = cam.name;
    row["kind"] = cam.kind;
    row["ble"] = cam.ble;
  }
  if (WiFi.status() == WL_CONNECTED) {
    doc["wifiHost"] = WiFi.localIP().toString();
    doc["host"] = WiFi.localIP().toString();
  }
  if (ethReady) {
    doc["ethHost"] = ETH.localIP().toString();
    if (WiFi.status() != WL_CONNECTED) doc["host"] = ETH.localIP().toString();
  }
  doc["port"] = 81;
  doc["fw"] = "1.0.62-hub";
  doc["wifiMac"] = WiFi.macAddress();
  doc["ethMac"] = ethMacText;
  doc["apMac"] = WiFi.softAPmacAddress();
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

static const uint8_t kJobRecord = 0;
static const uint8_t kJobTally = 1;
static const uint8_t kJobSetting = 2;
static bool linkHeld = false;

static uint8_t macType(const char* id) {
  unsigned value = 0;
  if (id == nullptr || sscanf(id, "%2x", &value) != 1) return BLE_ADDR_PUBLIC;
  return (value & 0xC0) == 0xC0 ? BLE_ADDR_RANDOM : BLE_ADDR_PUBLIC;
}

// 같은 카메라·같은 종류 명령은 최신값만 남깁니다(큐 적체 지연 방지).
static void enqueueCam(const char* id, const char* name, const char* ble, uint8_t addrType, uint8_t kind, bool start, bool led, uint8_t setting, uint8_t option) {
  if (id == nullptr || id[0] == 0) return;
  for (int i = 0; i < jobCount; i++) {
    if (!jobs[i].used || jobs[i].kind != kind || strcmp(jobs[i].id, id) != 0) continue;
    copyField(jobs[i].name, sizeof(jobs[i].name), name == nullptr ? "" : name);
    copyField(jobs[i].ble, sizeof(jobs[i].ble), ble == nullptr || ble[0] == 0 ? "FEA6" : ble);
    jobs[i].addrType = addrType;
    jobs[i].start = start;
    jobs[i].led = led;
    jobs[i].setting = setting;
    jobs[i].option = option;
    return;
  }
  if (jobCount >= 8) {
    // 가득 차면 맨 앞(가장 오래된)을 버리고 뒤에 넣습니다.
    for (int i = 1; i < jobCount; i++) jobs[i - 1] = jobs[i];
    jobCount--;
  }
  HubJob job = {};
  copyField(job.id, sizeof(job.id), id);
  copyField(job.name, sizeof(job.name), name == nullptr ? "" : name);
  copyField(job.ble, sizeof(job.ble), ble == nullptr || ble[0] == 0 ? "FEA6" : ble);
  job.addrType = addrType;
  job.kind = kind;
  job.start = start;
  job.led = led;
  job.setting = setting;
  job.option = option;
  job.used = true;
  jobs[jobCount++] = job;
}

static bool nameMatches(NimBLEAdvertisedDevice& device, const char* name) {
  if (name == nullptr || name[0] == 0) return false;
  std::string seen = device.getName();
  if (seen.empty()) return false;
  return seen == name || seen.find(name) != std::string::npos || strstr(name, seen.c_str()) != nullptr;
}

static bool textHas(const char* hay, const char* needle) {
  return hay != nullptr && needle != nullptr && strstr(hay, needle) != nullptr;
}

static void toLower(char* dest, size_t cap, const std::string& src) {
  size_t n = src.size();
  if (n >= cap) n = cap - 1;
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)src[i];
    dest[i] = (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : (char)c;
  }
  dest[n] = 0;
}

// 로닌 RS·SC 짐벌도 FFF0 을 씁니다. 올리멕스는 액션캠만 잡고, 짐벌은 C3 로닌 역할만 붙입니다.
static bool looksLikeRoninGimbal(const char* lower) {
  return textHas(lower, "ronin") || textHas(lower, "ronin-sc") || textHas(lower, "ronin sc") ||
         textHas(lower, "dji rs") || textHas(lower, "rs 2") || textHas(lower, "rs2") ||
         textHas(lower, "rsc") || textHas(lower, "rsc2") || textHas(lower, "rsc 2") ||
         textHas(lower, "rs 3") || textHas(lower, "rs3") || textHas(lower, "rs 4") || textHas(lower, "rs4");
}

static bool takeCamera(NimBLEAdvertisedDevice& device, LiveCam* out) {
  memset(out, 0, sizeof(*out));
  std::string raw = device.haveName() ? device.getName() : std::string();
  char lower[48];
  toLower(lower, sizeof(lower), raw);
  if (looksLikeRoninGimbal(lower)) return false;
  const bool fff0 = device.isAdvertisingService(NimBLEUUID((uint16_t)0xFFF0));
  const bool fea6 = device.isAdvertisingService(NimBLEUUID((uint16_t)0xFEA6));
  const bool ce80 = device.isAdvertisingService(NimBLEUUID((uint16_t)0xCE80));
  const bool nameOsmo = textHas(lower, "osmo") || textHas(lower, "action");
  const bool nameGo = textHas(lower, "gopro");
  const bool nameInsta = textHas(lower, "insta");
  // FFF0 만으로는 안 됩니다. 로닌 RS 도 FFF0 이라 이름에 osmo/action 이 있을 때만 액션캠으로 봅니다.
  if (fea6 || nameGo || ce80 || nameInsta) {
    // ok
  } else if (fff0 && nameOsmo) {
    // ok
  } else if (nameOsmo) {
    // ok
  } else {
    return false;
  }
  const char* ble = "FFF0";
  const char* kind = "osmo";
  if (fea6 || nameGo) {
    ble = "FEA6";
    kind = "gopro";
  } else if (ce80 || nameInsta) {
    ble = "CE80";
    kind = "insta360";
  }
  copyField(out->ble, sizeof(out->ble), ble);
  copyField(out->kind, sizeof(out->kind), kind);
  std::string addr = device.getAddress().toString();
  copyField(out->id, sizeof(out->id), addr.c_str());
  out->addrType = device.getAddress().getType();
  if (raw.empty()) snprintf(out->name, sizeof(out->name), "%s %s", kind, addr.c_str());
  else copyField(out->name, sizeof(out->name), raw.c_str());
  out->used = out->name[0] != 0 && out->id[0] != 0;
  return out->used;
}

static uint32_t nextScanAt = 0;

static void scanCameras() {
  // 대기 명령이 있으면 3초 스캔으로 누르기 반응을 막지 않습니다.
  if (busy || linkHeld || jobCount > 0 || NimBLEDevice::getScan()->isScanning()) return;
  NimBLEScan* scan = NimBLEDevice::getScan();
  scan->setActiveScan(true);
  scan->setInterval(100);
  scan->setWindow(90);
  scan->setDuplicateFilter(true);
  NimBLEDevice::getAdvertising()->stop();
  Serial.println("블루투스 스캔 시작");
  const uint32_t began = millis();
  // 소켓 클라이언트가 있으면 짧게(1초), 없으면 3초.
  const uint32_t scanSec = socket.count() > 0 ? 1 : 3;
  NimBLEScanResults results = scan->start(scanSec, false);
  if (millis() - began < 200) {
    Serial.println("블루투스 스캔을 시작하지 못했습니다.");
    NimBLEDevice::getAdvertising()->start();
    nextScanAt = millis() + 8000;
    return;
  }
  LiveCam next[8];
  memset(next, 0, sizeof(next));
  int count = 0;
  int named = 0;
  for (int i = 0; i < results.getCount(); i++) {
    NimBLEAdvertisedDevice device = results.getDevice(i);
    LiveCam row;
    if (takeCamera(device, &row)) {
      if (count < 8) next[count++] = row;
      Serial.print("  카메라 ");
      Serial.print(row.ble);
      Serial.print(" ");
      Serial.print(row.name);
      Serial.print(" ");
      Serial.println(row.id);
      continue;
    }
    if (!device.haveName() || named >= 8) continue;
    std::string seen = device.getName();
    if (seen.empty()) continue;
    named++;
    Serial.print("  다른 이름 ");
    Serial.println(seen.c_str());
  }
  const int seen = results.getCount();
  scan->clearResults();
  memcpy(liveCams, next, sizeof(liveCams));
  Serial.print("블루투스 스캔 끝. 주변 ");
  Serial.print(seen);
  Serial.print(", 카메라 ");
  Serial.println(count);
  NimBLEDevice::getAdvertising()->start();
  nextScanAt = millis() + 8000;
  publish();
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

static volatile bool noteReady = false;
static uint8_t noteBuf[48];
static volatile uint8_t noteLen = 0;

static void onBleNotify(NimBLERemoteCharacteristic*, uint8_t* data, size_t len, bool) {
  if (data == nullptr || len == 0 || len > sizeof(noteBuf)) return;
  memcpy(noteBuf, data, len);
  noteLen = (uint8_t)len;
  noteReady = true;
}

struct BleSession {
  NimBLEClient* client;
  char id[20];
  char ble[8];
  bool open;
  uint32_t touched;
  uint32_t kept;
};

static BleSession session = {};

static void dropSession() {
  if (session.client != nullptr) {
    if (session.client->isConnected()) session.client->disconnect();
    NimBLEDevice::deleteClient(session.client);
  }
  session.client = nullptr;
  session.open = false;
  session.id[0] = 0;
  linkHeld = false;
  NimBLEDevice::getAdvertising()->start();
}

static bool sessionHeld() {
  return linkHeld && session.client != nullptr && session.client->isConnected();
}

static bool waitNote(uint32_t ms) {
  const uint32_t start = millis();
  while ((uint32_t)(millis() - start) < ms) {
    if (noteReady) return true;
    delay(5);
    yield();
  }
  return noteReady;
}

static bool goproAccepted() {
  GoproAssembler rx;
  goproAssemblerReset(&rx);
  bool done = false;
  if (!goproAssemblerPush(&rx, noteBuf, noteLen, &done) || !done) return false;
  if (rx.payloadLen >= 3 && rx.payload[0] == 0x02) return rx.payload[2] == 0;
  if (rx.payloadLen >= 2) return rx.payload[1] == 0;
  return false;
}

static bool osmoAccepted(uint8_t cmd) {
  if (noteLen < 15 || noteBuf[0] != 0xAA) return false;
  if ((noteBuf[3] & 0x20) == 0) return false;
  if (noteBuf[12] != 0x1D || noteBuf[13] != cmd) return false;
  return noteBuf[14] == 0;
}

static bool subscribeOne(NimBLERemoteService* service, const NimBLEUUID& uuid) {
  NimBLERemoteCharacteristic* notify = service->getCharacteristic(uuid);
  if (notify == nullptr || !notify->canNotify()) return false;
  return notify->subscribe(true, onBleNotify, true);
}

static bool looksLikeMac(const char* id) {
  int colons = 0;
  if (id == nullptr) return false;
  for (const char* p = id; *p; ++p) {
    if (*p == ':') colons++;
  }
  return colons == 5;
}

static bool openSession(const HubJob& job) {
  if (sessionHeld() && strcmp(session.id, job.id) == 0) {
    session.touched = millis();
    return true;
  }
  dropSession();
  NimBLEDevice::getAdvertising()->stop();
  const bool osmo = strcmp(job.ble, "FFF0") == 0;
  for (int attempt = 0; attempt < 3; attempt++) {
    // 붙이는 동안 새 녹화 명령이 오면 스캔이 다시 끼어들지 않게 합니다.
    if (jobCount > 0 && attempt > 0) { /* keep trying current */ }
    NimBLEAddress address(std::string(job.id), job.addrType);
    if (!looksLikeMac(job.id)) {
      address = findAddress(job.name, osmo ? "FFF0" : "FEA6");
    }
    NimBLEClient* client = NimBLEDevice::createClient();
    if (client == nullptr) continue;
    // 알려진 MAC 은 빠르게 실패·재시도합니다(8초 대기는 체감 지연).
    client->setConnectTimeout(looksLikeMac(job.id) ? 3 : 5);
    if (!client->connect(address)) {
      NimBLEDevice::deleteClient(client);
      delay(80);
      continue;
    }
    client->updateConnParams(6, 12, 0, 200);
    NimBLERemoteService* service = client->getService(osmo ? NimBLEUUID((uint16_t)0xFFF0) : NimBLEUUID((uint16_t)0xFEA6));
    if (service == nullptr) {
      client->disconnect();
      NimBLEDevice::deleteClient(client);
      delay(250);
      continue;
    }
    bool listening = false;
    if (osmo) {
      listening = subscribeOne(service, NimBLEUUID((uint16_t)0xFFF4));
    } else {
      const bool command = subscribeOne(service, NimBLEUUID("b5f90073-aa8d-11e3-9046-0002a5d5c51b"));
      const bool setting = subscribeOne(service, NimBLEUUID("b5f90075-aa8d-11e3-9046-0002a5d5c51b"));
      listening = command && setting;
    }
    if (!listening) {
      client->disconnect();
      NimBLEDevice::deleteClient(client);
      delay(80);
      continue;
    }
    session.client = client;
    copyField(session.id, sizeof(session.id), job.id);
    copyField(session.ble, sizeof(session.ble), job.ble);
    session.open = true;
    session.touched = millis();
    session.kept = millis();
    linkHeld = true;
    return true;
  }
  NimBLEDevice::getAdvertising()->start();
  return false;
}

static bool writeGoPro(const uint8_t* body, uint8_t bodyLen, bool setting) {
  if (!sessionHeld()) return false;
  GoproBytes frame;
  if (!goproFrameExt13(body, bodyLen, &frame)) return false;
  NimBLERemoteService* service = session.client->getService(NimBLEUUID((uint16_t)0xFEA6));
  if (service == nullptr) return false;
  const char* uuid = setting ? "b5f90074-aa8d-11e3-9046-0002a5d5c51b" : "b5f90072-aa8d-11e3-9046-0002a5d5c51b";
  NimBLERemoteCharacteristic* write = service->getCharacteristic(NimBLEUUID(uuid));
  if (write == nullptr) return false;
  noteReady = false;
  noteLen = 0;
  // 셔터는 무응답 쓰기로 먼저 보내고, 짧게 notify 를 확인합니다.
  const bool wantResponse = setting;
  if (!write->writeValue(frame.data, frame.length, wantResponse)) return false;
  if (!waitNote(setting ? 700 : 450)) return false;
  return goproAccepted();
}

static bool writeOsmo(uint8_t cmd, const uint8_t* payload, size_t payloadLen) {
  if (!sessionHeld()) return false;
  NimBLERemoteService* service = session.client->getService(NimBLEUUID((uint16_t)0xFFF0));
  if (service == nullptr) return false;
  NimBLERemoteCharacteristic* write = service->getCharacteristic(NimBLEUUID((uint16_t)0xFFF5));
  if (write == nullptr) return false;
  uint8_t frame[48];
  size_t len = djiBuild(frame, sizeof(frame), 0x1D, cmd, 0x01, djiSeq++, payload, payloadLen);
  if (len == 0) return false;
  noteReady = false;
  noteLen = 0;
  // 녹화(0x03)는 무응답 쓰기 + 짧은 대기. 설정만 응답 대기.
  const bool wantResponse = cmd != 0x03;
  if (!write->writeValue(frame, len, wantResponse)) return false;
  if (!waitNote(wantResponse ? 700 : 450)) return false;
  return osmoAccepted(cmd);
}

static void keepSession() {
  if (!sessionHeld() || busy || jobCount > 0) return;
  if ((uint32_t)(millis() - session.touched) > 60000) {
    dropSession();
    nextScanAt = millis();
    return;
  }
  if (strcmp(session.ble, "FEA6") != 0) return;
  if ((uint32_t)(millis() - session.kept) < 2500) return;
  const uint8_t body[1] = {0x5B};
  if (!writeGoPro(body, 1, false)) {
    dropSession();
    nextScanAt = millis();
    return;
  }
  session.kept = millis();
}

static uint32_t osmoDeviceId(const char* name) {
  String text = name == nullptr ? "" : name;
  text.toLowerCase();
  if (text.indexOf("360") >= 0) return 0xFF660000;
  if (text.indexOf("action 6") >= 0 || text.indexOf("action6") >= 0) return 0xFF550000;
  if (text.indexOf("action 4") >= 0 || text.indexOf("action4") >= 0) return 0xFF330000;
  return 0xFF440000;
}

static bool osmoPayload(const HubJob& job, uint8_t cmd, uint8_t* payload, size_t* len) {
  const uint32_t device = osmoDeviceId(job.name);
  payload[0] = (uint8_t)device;
  payload[1] = (uint8_t)(device >> 8);
  payload[2] = (uint8_t)(device >> 16);
  payload[3] = (uint8_t)(device >> 24);
  if (cmd == 0x03) {
    payload[4] = job.start ? 0x00 : 0x01;
    payload[5] = 0;
    payload[6] = 0;
    payload[7] = 0;
    payload[8] = 0;
    *len = 9;
    return true;
  }
  payload[4] = job.option;
  payload[5] = 0x01;
  payload[6] = 0x47;
  payload[7] = 0x39;
  payload[8] = 0x36;
  *len = 9;
  return true;
}

static bool runOnce(const HubJob& job, char* note, size_t noteCap) {
  if (strcmp(job.ble, "CE80") == 0) {
    snprintf(note, noteCap, "인스타360 은 목록만 둡니다. 확인된 셔터 명령이 없어 보내지 않았습니다.");
    return false;
  }
  const bool osmo = strcmp(job.ble, "FFF0") == 0;
  if (osmo && job.kind == kJobTally) {
    snprintf(note, noteCap, "액션 5 앞 화면 탈리는 블루투스 명령에 없습니다. 녹화 테두리는 녹화가 시작될 때만 카메라가 켭니다.");
    return false;
  }
  if (!openSession(job)) {
    snprintf(note, noteCap, "%s 에 세 번 붙지 못했습니다. 명령을 보내지 않았습니다.", job.name);
    return false;
  }
  if (!osmo && job.kind == kJobRecord) {
    const uint8_t body[3] = {0x01, 0x01, (uint8_t)(job.start ? 0x01 : 0x00)};
    if (!writeGoPro(body, 3, false)) {
      snprintf(note, noteCap, "%s 고프로가 셔터에 상태 0으로 답하지 않았습니다.", job.name);
      return false;
    }
    if (job.led) {
      const uint8_t led[3] = {91, 0x01, (uint8_t)(job.start ? 4 : 0)};
      if (!writeGoPro(led, 3, true)) {
        snprintf(note, noteCap, "%s 셔터는 상태 0입니다. LED 91은 상태 0이 아닙니다. 앞 화면 글자는 그리지 않습니다.", job.name);
        return true;
      }
    }
    snprintf(note, noteCap, "%s 고프로가 상태 0으로 받았습니다. 앞 화면 글자는 그리지 않습니다.", job.name);
    return true;
  }
  if (!osmo && job.kind == kJobTally) {
    const uint8_t led[3] = {91, 0x01, (uint8_t)(job.start ? 4 : 0)};
    if (!writeGoPro(led, 3, true)) {
      snprintf(note, noteCap, "%s 고프로 LED 91이 상태 0으로 답하지 않았습니다. 앞 화면 글자는 그리지 않습니다.", job.name);
      return false;
    }
    snprintf(note, noteCap, "%s 고프로 LED를 %s. 상태 0입니다. 앞 화면 글자는 그리지 않습니다.", job.name, job.start ? "켰습니다" : "껐습니다");
    return true;
  }
  if (!osmo && job.kind == kJobSetting) {
    const uint8_t body[3] = {job.setting, 0x01, job.option};
    if (!writeGoPro(body, 3, true)) {
      snprintf(note, noteCap, "%s 고프로 설정 %u 가 상태 0으로 답하지 않았습니다.", job.name, job.setting);
      return false;
    }
    snprintf(note, noteCap, "%s 고프로 설정 %u 값 %u 을 상태 0으로 받았습니다.", job.name, job.setting, job.option);
    return true;
  }
  uint8_t payload[9];
  size_t len = 0;
  const uint8_t cmd = job.kind == kJobSetting ? 0x04 : 0x03;
  osmoPayload(job, cmd, payload, &len);
  if (!writeOsmo(cmd, payload, len)) {
    snprintf(note, noteCap, "%s 액션 5가 상태 0으로 답하지 않았습니다.", job.name);
    return false;
  }
  snprintf(note, noteCap, "%s 액션 5가 상태 0으로 받았습니다. 앞 화면 글자는 그리지 않습니다.", job.name);
  return true;
}

static void runJob(const HubJob& job) {
  char note[180] = "명령을 끝내지 못했습니다.";
  bool ok = false;
  for (int attempt = 0; attempt < 3 && !ok; attempt++) {
    // 이미 같은 카메라에 붙어 있으면 끊지 않고 한 번 더 보냅니다.
    if (attempt > 0 && !(sessionHeld() && strcmp(session.id, job.id) == 0)) dropSession();
    ok = runOnce(job, note, sizeof(note));
    if (strcmp(job.ble, "CE80") == 0 || (strcmp(job.ble, "FFF0") == 0 && job.kind == kJobTally)) break;
  }
  if (ok) session.touched = millis();
  tallyNote(note);
}

static int pickJobIndex() {
  if (jobCount <= 0) return -1;
  if (sessionHeld()) {
    for (int i = 0; i < jobCount; i++) {
      if (strcmp(jobs[i].id, session.id) == 0) return i;
    }
  }
  return 0;
}

static void pump() {
  if (busy || jobCount == 0) return;
  busy = true;
  const int pick = pickJobIndex();
  HubJob job = jobs[pick];
  for (int i = pick + 1; i < jobCount; i++) jobs[i - 1] = jobs[i];
  jobCount--;
  runJob(job);
  busy = false;
  publish();
}

static void enqueueKnown(const char* id, const char* name, const char* ble, uint8_t kind, bool start, bool led, uint8_t setting, uint8_t option) {
  if (id == nullptr || id[0] == 0) return;
  uint8_t addrType = macType(id);
  const char* useName = name;
  const char* useBle = ble;
  for (const LiveCam& cam : liveCams) {
    if (!cam.used || strcmp(cam.id, id) != 0) continue;
    addrType = cam.addrType;
    if (useName == nullptr || useName[0] == 0) useName = cam.name;
    if (useBle == nullptr || useBle[0] == 0) useBle = cam.ble;
    break;
  }
  enqueueCam(id, useName, useBle, addrType, kind, start, led, setting, option);
}

static void handleText(const char* text) {
  JsonDocument doc;
  if (deserializeJson(doc, text)) return;
  const char* op = doc["op"] | "";
  if (strcmp(op, "ping") == 0) {
    // keepalive. 상태 방송은 하지 않습니다.
    return;
  }
  if (strcmp(op, "record") == 0 || strcmp(op, "record-one") == 0) {
    bool start = doc["start"] | false;
    bool led = doc["tally"] | start;
    if (strcmp(op, "record-one") == 0) {
      enqueueKnown(doc["id"] | "", doc["name"] | "", doc["ble"] | "", kJobRecord, start, led, 0, 0);
      return;
    }
    JsonArray ids = doc["ids"].as<JsonArray>();
    if (ids.isNull() || ids.size() == 0) {
      for (const LiveCam& cam : liveCams) {
        if (!cam.used) continue;
        enqueueCam(cam.id, cam.name, cam.ble, cam.addrType, kJobRecord, start, led, 0, 0);
      }
      return;
    }
    for (JsonVariant id : ids) enqueueKnown(id.as<const char*>(), "", "", kJobRecord, start, led, 0, 0);
    return;
  }
  if (strcmp(op, "tally") == 0) {
    enqueueKnown(doc["id"] | "", doc["name"] | "", doc["ble"] | "", kJobTally, doc["on"] | false, true, 0, 0);
    return;
  }
  if (strcmp(op, "camera") == 0) {
    const char* ble = doc["ble"] | "";
    const char* rawSetting = doc["setting"] | "";
    const int option = atoi(doc["value"] | "0");
    if (strcmp(ble, "FFF0") == 0) {
      enqueueKnown(doc["id"] | "", doc["name"] | "", ble, kJobSetting, false, false, 0, (uint8_t)option);
      return;
    }
    const int setting = atoi(rawSetting);
    if (setting <= 0 || option < 0) {
      tallyNote("고프로 설정 번호가 없습니다. 보내지 않았습니다.");
      return;
    }
    enqueueKnown(doc["id"] | "", doc["name"] | "", ble, kJobSetting, false, false, (uint8_t)setting, (uint8_t)option);
  }
}

static void onEvent(AsyncWebSocket*, AsyncWebSocketClient* client, AwsEventType type, void*, uint8_t* data, size_t len) {
  if (type == WS_EVT_CONNECT) {
    nextScanAt = millis();
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

static const char* kProvService = "7b1e9c10-5a20-4c31-8d10-726f6e696e31";
static const char* kProvChar = "7b1e9c11-5a20-4c31-8d10-726f6e696e31";
static Preferences wifiStore;
static NimBLECharacteristic* provChar = nullptr;
static bool joinAsked = false;
static bool staWanted = false;
static String joinSsid;
static String joinPass;
static String joinIp;
static int staChannel = 0;
static uint8_t staBssid[6] = {};
static bool staLocked = false;
static uint32_t nextStaTry = 0;

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

static void showIdentity() {
  if (provChar == nullptr) return;
  JsonDocument doc;
  doc["wifiMac"] = WiFi.macAddress();
  doc["ethMac"] = ethMacText;
  doc["apMac"] = WiFi.softAPmacAddress();
  String out;
  serializeJson(doc, out);
  provChar->setValue(out.c_str());
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
  NimBLEServer* server = NimBLEDevice::createServer();
  NimBLEService* service = server->createService(kProvService);
  provChar = service->createCharacteristic(
      kProvChar, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY, 240);
  provChar->setCallbacks(new ProvCallbacks());
  service->start();
  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(kProvService);
  advertising->start();
  Serial.println("블루투스 이름 Ronin-Olimex. 처음 설정은 이 이름으로 받습니다.");
}

static void allowKoreaChannels() {
  wifi_country_t country = {};
  memcpy(country.cc, "KR", 3);
  country.schan = 1;
  country.nchan = 13;
  country.policy = WIFI_COUNTRY_POLICY_MANUAL;
  esp_wifi_set_country(&country);
}

static void pinAddress(const IPAddress& ip) {
  esp_netif_t* netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
  if (netif == nullptr) return;
  esp_netif_dhcpc_stop(netif);
  esp_netif_ip_info_t info = {};
  info.ip.addr = static_cast<uint32_t>(ip);
  info.gw.addr = static_cast<uint32_t>(IPAddress(192, 168, 10, 1));
  info.netmask.addr = static_cast<uint32_t>(IPAddress(255, 255, 255, 0));
  esp_netif_set_ip_info(netif, &info);
}

static void startHotspot(int channel) {
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAPConfig(IPAddress(192, 168, 4, 1), IPAddress(192, 168, 4, 1), IPAddress(255, 255, 255, 0));
  if (channel >= 1 && channel <= 13) WiFi.softAP("Ronin-Olimex", nullptr, channel);
  else WiFi.softAP("Ronin-Olimex");
}

/// 핫스팟을 먼저 켜면 라디오가 1번 채널에 고정됩니다. 집 2.4GHz는 다른 채널이라 붙지 못합니다.
static bool beginStation(const String& ssid, const String& pass, const String& ipText) {
  staWanted = true;
  joinSsid = ssid;
  joinPass = pass;
  IPAddress parsed;
  String useIp = ipText;
  if (!fixedLan(useIp, &parsed)) {
    useIp = "192.168.10.151";
    Serial.println("고정 주소가 없어 192.168.10.151 을 씁니다.");
  }
  joinIp = useIp;
  if (ssid.isEmpty()) {
    startHotspot(0);
    nextStaTry = millis() + 15000;
    return false;
  }
  WiFi.persistent(false);
  WiFi.setAutoReconnect(false);
  WiFi.mode(WIFI_STA);
  allowKoreaChannels();
  IPAddress ip;
  if (fixedLan(useIp, &ip)) {
    WiFi.config(ip, IPAddress(192, 168, 10, 1), IPAddress(255, 255, 255, 0), IPAddress(192, 168, 10, 1));
  } else {
    WiFi.config((uint32_t)0, (uint32_t)0, (uint32_t)0, (uint32_t)0);
  }
  staLocked = false;
  const int found = WiFi.scanNetworks();
  int bestRssi = -127;
  int bestChannel = 0;
  uint8_t best[6] = {};
  if (found > 0) {
    for (int i = 0; i < found; i++) {
      if (WiFi.SSID(i) != ssid) continue;
      const int channel = WiFi.channel(i);
      if (channel < 1 || channel > 13) continue;
      if (WiFi.RSSI(i) > bestRssi) {
        bestRssi = WiFi.RSSI(i);
        bestChannel = channel;
        const uint8_t* bssid = WiFi.BSSID(i);
        if (bssid != nullptr) memcpy(best, bssid, 6);
      }
    }
  }
  WiFi.scanDelete();
  Serial.println("와이파이에 붙는 중입니다. 비밀번호는 찍지 않습니다.");
  if (bestChannel == 0) {
    Serial.println("2.4GHz에서 그 이름을 찾지 못했습니다. 이 기판은 5GHz에 붙지 못합니다.");
    WiFi.begin(ssid.c_str(), pass.c_str());
  } else {
    staChannel = bestChannel;
    memcpy(staBssid, best, 6);
    staLocked = true;
    Serial.print("2.4GHz 채널 ");
    Serial.println(bestChannel);
    WiFi.begin(ssid.c_str(), pass.c_str(), bestChannel, staBssid);
  }
  const uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < 15000) delay(200);
  bool ok = WiFi.status() == WL_CONNECTED;
  startHotspot(bestChannel);
  IPAddress wanted;
  if (fixedLan(useIp, &wanted)) {
    Serial.print("USEIP ");
    Serial.println(useIp);
    pinAddress(wanted);
  }
  if (fixedLan(useIp, &wanted) && WiFi.localIP() != wanted) {
    WiFi.config(wanted, IPAddress(192, 168, 10, 1), IPAddress(255, 255, 255, 0), IPAddress(192, 168, 10, 1));
    if (staLocked) WiFi.begin(ssid.c_str(), pass.c_str(), staChannel, staBssid);
    else WiFi.begin(ssid.c_str(), pass.c_str());
    const uint32_t again = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - again < 10000) delay(200);
    ok = WiFi.status() == WL_CONNECTED;
    Serial.print("요청 주소 ");
    Serial.println(useIp);
  } else if (ok && WiFi.status() != WL_CONNECTED && staLocked) {
    WiFi.begin(ssid.c_str(), pass.c_str(), staChannel, staBssid);
    const uint32_t again = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - again < 8000) delay(200);
    ok = WiFi.status() == WL_CONNECTED;
  }
  wifiStore.putString("ip", useIp);
  if (ok) {
    Serial.print("같은 와이파이 주소 ");
    Serial.println(WiFi.localIP());
  } else if (WiFi.status() == WL_CONNECT_FAILED) {
    Serial.println("2.4GHz에 비밀번호가 맞지 않습니다. 처음 연결에서 다시 넣으세요.");
  } else {
    Serial.println("2.4GHz에 붙지 못했습니다. 핫스팟은 켜 둡니다.");
  }
  nextStaTry = millis() + 15000;
  return ok;
}

static void keepStation() {
  if (!staWanted || joinSsid.isEmpty() || WiFi.status() == WL_CONNECTED) return;
  if (millis() < nextStaTry) return;
  beginStation(joinSsid, joinPass, joinIp);
}

static void finishJoin() {
  joinAsked = false;
  wifiStore.putString("ssid", joinSsid);
  wifiStore.putString("pass", joinPass);
  wifiStore.putString("ip", joinIp);
  const bool ok = beginStation(joinSsid, joinPass, joinIp);
  if (!ok) {
    tellProvision("{\"ok\":false,\"reason\":\"그 와이파이에 붙지 못했습니다. 핫스팟 Ronin-Olimex 는 그대로입니다.\"}");
    return;
  }
  const String ip = WiFi.localIP().toString();
  String note = "{\"ok\":true,\"ip\":\"" + ip + "\",\"port\":81,\"wifiMac\":\"" + WiFi.macAddress() + "\",\"ethMac\":\"" + ethMacText + "\",\"apMac\":\"" + WiFi.softAPmacAddress() + "\"}";
  tellProvision(note.c_str());
  Serial.print("같은 와이파이 주소 ");
  Serial.println(ip);
}

static void banner() {
  Serial.println();
  Serial.println("올리멕스 액션캠 허브");
  Serial.println("PoE 192.168.10.150 웹소켓 81");
  Serial.println("핫스팟 Ronin-Olimex 192.168.4.1 웹소켓 81");
  Serial.println("같은 와이파이 기본 192.168.10.151 웹소켓 81. 블루투스 설정이 있으면 그 주소를 씁니다.");
  Serial.println("주변 고프로 FEA6, 오즈모 FFF0, 인스타360 이름을 스캔해 웹소켓으로 보냅니다.");
}

void setup() {
  Serial.begin(115200);
  delay(400);
  banner();
  NimBLEDevice::init("Ronin-Olimex");
  wifiStore.begin("olimex-wifi", false);
  startProvision();
  const String savedSsid = wifiStore.isKey("ssid") ? wifiStore.getString("ssid", "") : "";
  if (!savedSsid.isEmpty()) {
    String savedIp = wifiStore.getString("ip", "");
    if (savedIp.isEmpty() || savedIp == "192.168.10.204") savedIp = "192.168.10.151";
    beginStation(savedSsid, wifiStore.getString("pass", ""), savedIp);
  } else {
#if HUB_HAS_WIFI
    Serial.println("저장된 설정이 없어 비밀 파일의 와이파이로 붙습니다. 비밀번호는 찍지 않습니다.");
    beginStation(WIFI_SSID_1, WIFI_PASS, "192.168.10.151");
#else
    Serial.println("저장된 와이파이가 없습니다. 블루투스 Ronin-Olimex 로 처음 설정을 받으세요.");
    startHotspot(0);
#endif
  }
  WiFi.onEvent([](arduino_event_id_t event) {
    if (event == ARDUINO_EVENT_ETH_GOT_IP) ethReady = true;
    if (event == ARDUINO_EVENT_ETH_DISCONNECTED) ethReady = false;
  });
  if (ETH.begin()) {
    ETH.config(IPAddress(192, 168, 10, 150), IPAddress(192, 168, 10, 1), IPAddress(255, 255, 255, 0));
    ethMacText = ETH.macAddress();
    Serial.print("이더넷 MAC ");
    Serial.println(ethMacText);
  } else {
    Serial.println("이더넷 초기화에 실패했습니다.");
  }
  if (staWanted && WiFi.status() != WL_CONNECTED && !joinSsid.isEmpty()) {
    beginStation(joinSsid, joinPass, joinIp);
  }
  showIdentity();
  Serial.print("와이파이 MAC ");
  Serial.println(WiFi.macAddress());
  socket.onEvent(onEvent);
  server.addHandler(&socket);
  server.begin();
  Serial.println("웹소켓 81번을 열었습니다.");
}

void loop() {
  if (joinAsked) finishJoin();
  else keepStation();
  pump();
  if (!busy) keepSession();
  if (!busy && !linkHeld && jobCount == 0 && (int32_t)(millis() - nextScanAt) >= 0) scanCameras();
  socket.cleanupClients();
  // 대기 명령이 있으면 20ms 쉼을 줄여 바로 다음 카메라로 갑니다.
  delay(jobCount > 0 ? 2 : 12);
}
