#include "ronin_ble.h"
#include "dji_r_frame.h"

#include <Preferences.h>
#include <ctype.h>
#include <string.h>

static constexpr size_t kMaxFound = 8;
static RoninFound found[kMaxFound];
static size_t foundCount = 0;

static NimBLEClient* client = nullptr;
static NimBLERemoteCharacteristic* writeChar = nullptr;
static bool linked = false;
static bool busy = false;
static char linkedName[40] = {};
static char linkedId[24] = {};
static uint16_t seq = 1;
static Preferences store;

static void lowerCopy(char* out, size_t cap, const char* in) {
  if (out == nullptr || cap == 0) return;
  size_t i = 0;
  for (; in != nullptr && in[i] != 0 && i + 1 < cap; i++) {
    out[i] = (char)tolower((unsigned char)in[i]);
  }
  out[i] = 0;
}

static bool textHas(const char* hay, const char* needle) {
  if (hay == nullptr || needle == nullptr || needle[0] == 0) return false;
  return strstr(hay, needle) != nullptr;
}

static bool looksLikeRonin(NimBLEAdvertisedDevice& device) {
  std::string name = device.getName();
  char lower[64];
  lowerCopy(lower, sizeof(lower), name.c_str());
  if (textHas(lower, "ronin") || textHas(lower, "dji rs") || textHas(lower, "rs 2") || textHas(lower, "rs2") ||
      textHas(lower, "rsc") || textHas(lower, "rs 3") || textHas(lower, "rs3")) {
    return true;
  }
  if (device.isAdvertisingService(NimBLEUUID((uint16_t)0xFFF0)) && name.size() > 0) {
    if (textHas(lower, "osmo") || textHas(lower, "action") || textHas(lower, "pocket")) return false;
    if (textHas(lower, "dji")) return true;
  }
  return false;
}

static void pauseProvision() {
  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  if (advertising != nullptr) advertising->stop();
}

static void resumeProvision() {
  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  if (advertising != nullptr) advertising->start();
}

static void clearLink(bool keepPrefs) {
  writeChar = nullptr;
  linked = false;
  linkedName[0] = 0;
  linkedId[0] = 0;
  if (client != nullptr) {
    if (client->isConnected()) client->disconnect();
    NimBLEDevice::deleteClient(client);
    client = nullptr;
  }
  if (!keepPrefs) {
    store.begin("ronin-c3", false);
    store.remove("gimbalName");
    store.remove("gimbalId");
    store.end();
  }
  resumeProvision();
}

void roninBleBegin() {
  store.begin("ronin-c3", false);
  String savedName = store.getString("gimbalName", "");
  String savedId = store.getString("gimbalId", "");
  store.end();
  if (!savedName.isEmpty()) {
    strncpy(linkedName, savedName.c_str(), sizeof(linkedName) - 1);
  }
  if (!savedId.isEmpty()) {
    strncpy(linkedId, savedId.c_str(), sizeof(linkedId) - 1);
  }
}

void roninBleLoop() {
  if (client != nullptr && linked && !client->isConnected()) {
    Serial.println("로닌 블루투스가 끊겼습니다.");
    clearLink(true);
  }
}

void roninBleDrop() { clearLink(false); }

bool roninBleBusy() { return busy; }

bool roninBleLinked() { return linked && client != nullptr && client->isConnected() && writeChar != nullptr; }

const char* roninBleName() { return linkedName[0] ? linkedName : ""; }

size_t roninBleScan(RoninFound* out, size_t cap, bool manageBusy) {
  if (out == nullptr || cap == 0) return 0;
  if (manageBusy) busy = true;
  pauseProvision();
  if (NimBLEDevice::getScan()->isScanning()) {
    NimBLEDevice::getScan()->stop();
  }
  NimBLEScan* scan = NimBLEDevice::getScan();
  scan->setActiveScan(true);
  scan->setInterval(100);
  scan->setWindow(90);
  scan->setDuplicateFilter(true);
  NimBLEScanResults results = scan->start(4, false);
  foundCount = 0;
  for (int i = 0; i < results.getCount() && foundCount < kMaxFound; i++) {
    NimBLEAdvertisedDevice device = results.getDevice(i);
    if (!looksLikeRonin(device)) continue;
    std::string name = device.getName();
    if (name.empty()) continue;
    RoninFound row = {};
    strncpy(row.name, name.c_str(), sizeof(row.name) - 1);
    strncpy(row.id, device.getAddress().toString().c_str(), sizeof(row.id) - 1);
    row.addrType = device.getAddressType();
    bool dup = false;
    for (size_t j = 0; j < foundCount; j++) {
      if (strcmp(found[j].id, row.id) == 0) {
        dup = true;
        break;
      }
    }
    if (dup) continue;
    found[foundCount++] = row;
    Serial.print("로닌 후보 ");
    Serial.print(row.name);
    Serial.print(" ");
    Serial.println(row.id);
  }
  scan->clearResults();
  if (!roninBleLinked()) resumeProvision();
  if (manageBusy) busy = false;
  size_t n = foundCount < cap ? foundCount : cap;
  for (size_t i = 0; i < n; i++) out[i] = found[i];
  return n;
}

void roninBleFillList(JsonDocument& doc) {
  JsonArray list = doc["gimbals"].to<JsonArray>();
  for (size_t i = 0; i < foundCount; i++) {
    JsonObject row = list.add<JsonObject>();
    row["id"] = found[i].id;
    row["name"] = found[i].name;
    row["addrType"] = found[i].addrType;
  }
  if (roninBleLinked()) {
    doc["paired"] = linkedName;
    doc["pairedId"] = linkedId;
  } else if (linkedName[0]) {
    doc["saved"] = linkedName;
  }
}

static bool openServices(NimBLEClient* next, char* reason, size_t reasonCap) {
  NimBLERemoteService* service = next->getService(NimBLEUUID((uint16_t)0xFFF0));
  if (service == nullptr) {
    snprintf(reason, reasonCap, "로닌 서비스 FFF0 을 찾지 못했습니다.");
    return false;
  }
  NimBLERemoteCharacteristic* notify = service->getCharacteristic(NimBLEUUID((uint16_t)0xFFF4));
  if (notify != nullptr && notify->canNotify()) {
    notify->subscribe(true, nullptr, true);
  }
  NimBLERemoteCharacteristic* write = service->getCharacteristic(NimBLEUUID((uint16_t)0xFFF5));
  if (write == nullptr || !(write->canWrite() || write->canWriteNoResponse())) {
    snprintf(reason, reasonCap, "로닌 쓰기 특성 FFF5 를 찾지 못했습니다.");
    return false;
  }
  writeChar = write;
  return true;
}

bool roninBlePair(const char* name, const char* id, char* reason, size_t reasonCap) {
  if (reason == nullptr || reasonCap == 0) return false;
  reason[0] = 0;
  if ((name == nullptr || name[0] == 0) && (id == nullptr || id[0] == 0)) {
    snprintf(reason, reasonCap, "붙일 로닌 이름이 없습니다.");
    return false;
  }
  busy = true;
  clearLink(true);
  pauseProvision();

  char wantName[40] = {};
  char wantId[24] = {};
  if (name != nullptr) strncpy(wantName, name, sizeof(wantName) - 1);
  if (id != nullptr) strncpy(wantId, id, sizeof(wantId) - 1);

  if (foundCount == 0) {
    RoninFound scratch[kMaxFound];
    roninBleScan(scratch, kMaxFound, false);
  }

  const RoninFound* hit = nullptr;
  for (size_t i = 0; i < foundCount; i++) {
    if (wantId[0] && strcasecmp(found[i].id, wantId) == 0) {
      hit = &found[i];
      break;
    }
  }
  if (hit == nullptr && wantName[0]) {
    for (size_t i = 0; i < foundCount; i++) {
      if (strcasecmp(found[i].name, wantName) == 0) {
        hit = &found[i];
        break;
      }
    }
  }
  if (hit == nullptr && wantName[0]) {
    char needle[40];
    lowerCopy(needle, sizeof(needle), wantName);
    for (size_t i = 0; i < foundCount; i++) {
      char lower[40];
      lowerCopy(lower, sizeof(lower), found[i].name);
      if (textHas(lower, needle)) {
        hit = &found[i];
        break;
      }
    }
  }
  if (hit == nullptr) {
    busy = false;
    resumeProvision();
    snprintf(reason, reasonCap, "주변에서 그 로닌 이름을 찾지 못했습니다. 먼저 스캔하세요.");
    return false;
  }

  NimBLEAddress address(std::string(hit->id), hit->addrType);
  NimBLEClient* next = NimBLEDevice::createClient();
  if (next == nullptr) {
    busy = false;
    resumeProvision();
    snprintf(reason, reasonCap, "블루투스 클라이언트를 만들지 못했습니다.");
    return false;
  }
  next->setConnectTimeout(8);
  if (!next->connect(address)) {
    NimBLEDevice::deleteClient(next);
    busy = false;
    resumeProvision();
    snprintf(reason, reasonCap, "로닌 블루투스에 붙지 못했습니다. 짐벌 화면에서 블루투스를 켠 뒤 다시 누르세요.");
    return false;
  }
  if (!openServices(next, reason, reasonCap)) {
    next->disconnect();
    NimBLEDevice::deleteClient(next);
    busy = false;
    resumeProvision();
    return false;
  }
  client = next;
  linked = true;
  strncpy(linkedName, hit->name, sizeof(linkedName) - 1);
  strncpy(linkedId, hit->id, sizeof(linkedId) - 1);
  store.begin("ronin-c3", false);
  store.putString("gimbalName", linkedName);
  store.putString("gimbalId", linkedId);
  store.end();
  busy = false;
  snprintf(reason, reasonCap, "로닌 %s 에 블루투스로 붙었습니다.", linkedName);
  Serial.println(reason);
  return true;
}

bool roninBleMove(float yawDeg, float pitchDeg, bool home, char* reason, size_t reasonCap) {
  if (reason == nullptr || reasonCap == 0) return false;
  reason[0] = 0;
  if (!roninBleLinked()) {
    if (linkedName[0]) {
      char pairReason[160];
      if (!roninBlePair(linkedName, linkedId, pairReason, sizeof(pairReason))) {
        snprintf(reason, reasonCap, "%s", pairReason);
        return false;
      }
    } else {
      snprintf(reason, reasonCap, "붙은 로닌이 없습니다. 앱에서 이름을 골라 붙이세요.");
      return false;
    }
  }
  if (home) {
    yawDeg = 0;
    pitchDeg = 0;
  }
  uint8_t frame[40];
  size_t len = djiMoveTo(frame, sizeof(frame), seq++, yawDeg, pitchDeg, 1.0f, true);
  if (len == 0 || writeChar == nullptr) {
    snprintf(reason, reasonCap, "이동 명령을 만들지 못했습니다.");
    return false;
  }
  bool ok = false;
  if (writeChar->canWriteNoResponse()) {
    ok = writeChar->writeValue(frame, len, false);
  } else {
    ok = writeChar->writeValue(frame, len, true);
  }
  if (!ok) {
    snprintf(reason, reasonCap, "로닌에 팬·틸트를 쓰지 못했습니다. 블루투스를 다시 붙이세요.");
    clearLink(true);
    return false;
  }
  if (home) {
    snprintf(reason, reasonCap, "로닌 %s 제자리(팬 0°, 틸트 0°)로 보냈습니다.", linkedName);
  } else {
    snprintf(reason, reasonCap, "로닌 %s 팬 %.0f°, 틸트 %.0f° 를 블루투스로 보냈습니다.", linkedName, yawDeg, pitchDeg);
  }
  return true;
}
