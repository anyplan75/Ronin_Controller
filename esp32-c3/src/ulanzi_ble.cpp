#include "ulanzi_ble.h"
#include "board_net.h"

#include <Preferences.h>
#include <ctype.h>
#include <string.h>

// 관측 근거 (2026-11-20, 맥 bleak):
// - 광고 이름 "Ulanzi light(...)", 광고 서비스 0xAE00
// - 연결 후 서비스 0xFFF0, 쓰기 0xFFF2(WR), 알림 0xFFF1
// - 제조사 문자열 BEKEN SAS / 모델 BK-BLE-1.0
// 명령 바이트는 kevinlouie/lctl README·ble_controller.py 와 같고,
// 같은 맥에서 on/밝기/색온도/off 쓰기를 보내고 notify 응답을 받았다.

static constexpr size_t kMaxFound = 8;
static UlanziFound found[kMaxFound];
static size_t foundCount = 0;

static NimBLEClient* client = nullptr;
static NimBLERemoteCharacteristic* writeChar = nullptr;
static bool linked = false;
static bool busy = false;
static char linkedName[40] = {};
static char linkedId[24] = {};
static char savedNames[2][40] = {};
static char savedIds[2][24] = {};
static uint8_t savedCount = 0;
static Preferences store;

static void rememberSlot(uint8_t i, const char* name, const char* id) {
  if (i >= 2 || name == nullptr) return;
  strncpy(savedNames[i], name, sizeof(savedNames[i]) - 1);
  if (id) strncpy(savedIds[i], id, sizeof(savedIds[i]) - 1);
  char keyN[16];
  char keyI[16];
  snprintf(keyN, sizeof(keyN), "lightName%u", (unsigned)i);
  snprintf(keyI, sizeof(keyI), "lightId%u", (unsigned)i);
  store.begin("ronin-c3", false);
  store.putString(keyN, savedNames[i]);
  store.putString(keyI, savedIds[i]);
  store.putUChar("lightCount", savedCount);
  store.end();
}

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

static bool looksLikeUlanzi(NimBLEAdvertisedDevice& device) {
  std::string name = device.getName();
  char lower[64];
  lowerCopy(lower, sizeof(lower), name.c_str());
  if (textHas(lower, "ulanzi")) return true;
  if (device.isAdvertisingService(NimBLEUUID((uint16_t)0xAE00))) return true;
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
    delay(250);
    NimBLEDevice::deleteClient(client);
    client = nullptr;
    delay(150);
  }
  if (!keepPrefs) {
    store.begin("ronin-c3", false);
    store.remove("lightName");
    store.remove("lightId");
    store.end();
  }
  resumeProvision();
}

void ulanziBleBegin() {
  store.begin("ronin-c3", false);
  savedCount = store.getUChar("lightCount", 0);
  if (savedCount > 2) savedCount = 2;
  for (uint8_t i = 0; i < 2; i++) {
    char keyN[16];
    char keyI[16];
    snprintf(keyN, sizeof(keyN), "lightName%u", (unsigned)i);
    snprintf(keyI, sizeof(keyI), "lightId%u", (unsigned)i);
    String n = store.getString(keyN, i == 0 ? store.getString("lightName", "") : "");
    String id = store.getString(keyI, i == 0 ? store.getString("lightId", "") : "");
    savedNames[i][0] = 0;
    savedIds[i][0] = 0;
    if (!n.isEmpty()) {
      strncpy(savedNames[i], n.c_str(), sizeof(savedNames[i]) - 1);
      strncpy(savedIds[i], id.c_str(), sizeof(savedIds[i]) - 1);
      if (i >= savedCount) savedCount = i + 1;
    }
  }
  store.end();
  if (savedNames[0][0]) {
    strncpy(linkedName, savedNames[0], sizeof(linkedName) - 1);
    strncpy(linkedId, savedIds[0], sizeof(linkedId) - 1);
  }
}

uint8_t ulanziBleSavedCount() { return savedCount; }

void ulanziBleLoop() {
  if (client != nullptr && linked && !client->isConnected()) {
    Serial.println("울란지 블루투스가 끊겼습니다.");
    clearLink(true);
  }
}

void ulanziBleDrop() { clearLink(false); }

bool ulanziBleBusy() { return busy; }

bool ulanziBleLinked() {
  return linked && client != nullptr && client->isConnected() && writeChar != nullptr;
}

const char* ulanziBleName() { return linkedName[0] ? linkedName : ""; }

size_t ulanziBleScan(UlanziFound* out, size_t cap, bool manageBusy) {
  if (out == nullptr || cap == 0) return 0;
  if (manageBusy) busy = true;
  pauseProvision();
  if (NimBLEDevice::getScan()->isScanning()) {
    NimBLEDevice::getScan()->stop();
  }
  NimBLEScan* scan = NimBLEDevice::getScan();
  scan->setActiveScan(true);
  scan->setInterval(160);
  scan->setWindow(48);
  scan->setDuplicateFilter(false);
  foundCount = 0;
  for (int round = 0; round < 3; round++) {
    NimBLEScanResults results = scan->start(2, false);
    for (int i = 0; i < results.getCount() && foundCount < kMaxFound; i++) {
      NimBLEAdvertisedDevice device = results.getDevice(i);
      if (!looksLikeUlanzi(device)) continue;
      std::string name = device.getName();
      if (name.empty()) name = "Ulanzi light";
      UlanziFound row = {};
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
      Serial.print("울란지 후보 ");
      Serial.print(row.name);
      Serial.print(" ");
      Serial.println(row.id);
    }
    scan->clearResults();
    boardNetPump();
  }
  scan->clearResults();
  if (!ulanziBleLinked()) resumeProvision();
  if (manageBusy) busy = false;
  size_t n = foundCount < cap ? foundCount : cap;
  for (size_t i = 0; i < n; i++) out[i] = found[i];
  return n;
}

void ulanziBleFillList(JsonDocument& doc) {
  JsonArray list = doc["lights"].to<JsonArray>();
  JsonArray also = doc["gimbals"].to<JsonArray>();
  for (size_t i = 0; i < foundCount; i++) {
    JsonObject row = list.add<JsonObject>();
    row["id"] = found[i].id;
    row["name"] = found[i].name;
    row["addrType"] = found[i].addrType;
    JsonObject copy = also.add<JsonObject>();
    copy["id"] = found[i].id;
    copy["name"] = found[i].name;
  }
  if (ulanziBleLinked()) {
    doc["paired"] = linkedName;
    doc["pairedId"] = linkedId;
  } else if (linkedName[0]) {
    doc["saved"] = linkedName;
  }
}

void ulanziBleFillSaved(JsonDocument& doc) {
  JsonArray list = doc["savedLightsList"].to<JsonArray>();
  for (uint8_t i = 0; i < savedCount; i++) {
    if (!savedNames[i][0]) continue;
    JsonObject row = list.add<JsonObject>();
    row["index"] = i;
    row["id"] = savedIds[i];
    row["name"] = savedNames[i];
  }
  doc["savedLights"] = savedCount;
}

const char* ulanziBleSavedName(uint8_t index) {
  if (index >= savedCount) return "";
  return savedNames[index];
}

const char* ulanziBleSavedId(uint8_t index) {
  if (index >= savedCount) return "";
  return savedIds[index];
}

bool ulanziBleApplyIndex(uint8_t index, int brightness, int kelvin, bool on, char* reason, size_t reasonCap) {
  if (reason == nullptr || reasonCap == 0) return false;
  reason[0] = 0;
  if (index >= savedCount || !savedNames[index][0]) {
    snprintf(reason, reasonCap, "울란지 칸 %u 가 비어 있습니다. 먼저 스캔·붙이기를 하세요.", (unsigned)index);
    return false;
  }
  char pairReason[160];
  if (!ulanziBlePair(savedNames[index], savedIds[index], pairReason, sizeof(pairReason))) {
    snprintf(reason, reasonCap, "%s", pairReason);
    return false;
  }
  return ulanziBleApply(brightness, kelvin, on, reason, reasonCap);
}

static bool openServices(NimBLEClient* next, char* reason, size_t reasonCap) {
  NimBLERemoteService* service = next->getService(NimBLEUUID((uint16_t)0xFFF0));
  if (service == nullptr) {
    snprintf(reason, reasonCap, "울란지 서비스 FFF0 을 찾지 못했습니다.");
    return false;
  }
  NimBLERemoteCharacteristic* notify = service->getCharacteristic(NimBLEUUID((uint16_t)0xFFF1));
  if (notify != nullptr && notify->canNotify()) {
    notify->subscribe(true, nullptr, true);
    delay(200);
  }
  NimBLERemoteCharacteristic* write = service->getCharacteristic(NimBLEUUID((uint16_t)0xFFF2));
  if (write == nullptr || !(write->canWrite() || write->canWriteNoResponse())) {
    snprintf(reason, reasonCap, "울란지 쓰기 특성 FFF2 를 찾지 못했습니다.");
    return false;
  }
  writeChar = write;
  return true;
}

bool ulanziBlePair(const char* name, const char* id, char* reason, size_t reasonCap) {
  if (reason == nullptr || reasonCap == 0) return false;
  reason[0] = 0;
  if ((name == nullptr || name[0] == 0) && (id == nullptr || id[0] == 0)) {
    snprintf(reason, reasonCap, "붙일 울란지 이름이 없습니다.");
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
    UlanziFound scratch[kMaxFound];
    ulanziBleScan(scratch, kMaxFound, false);
  }

  const UlanziFound* hit = nullptr;
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
    snprintf(reason, reasonCap, "주변에서 그 울란지 이름을 찾지 못했습니다. 먼저 스캔하세요.");
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
  next->setConnectTimeout(10);
  if (!next->connect(address)) {
    NimBLEDevice::deleteClient(next);
    busy = false;
    resumeProvision();
    snprintf(reason, reasonCap, "울란지 블루투스에 붙지 못했습니다. 다른 기기가 붙어 있으면 끊고 다시 누르세요.");
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
  // 첫 빈 칸 또는 같은 id 자리에 저장
  uint8_t slot = 0;
  for (uint8_t i = 0; i < savedCount; i++) {
    if (strcmp(savedIds[i], linkedId) == 0 || strcmp(savedNames[i], linkedName) == 0) {
      slot = i;
      break;
    }
    slot = i + 1;
  }
  if (slot > 1) slot = 1;
  if (savedCount < slot + 1) savedCount = slot + 1;
  rememberSlot(slot, linkedName, linkedId);
  busy = false;
  snprintf(reason, reasonCap, "울란지 %s 에 블루투스로 붙었습니다.", linkedName);
  Serial.println(reason);
  return true;
}

bool ulanziBleAutoPair(char* reason, size_t reasonCap) {
  if (reason == nullptr || reasonCap == 0) return false;
  reason[0] = 0;
  UlanziFound rows[8];
  size_t n = ulanziBleScan(rows, 8);
  if (n == 0) {
    snprintf(reason, reasonCap, "울란지를 찾지 못했습니다.");
    return false;
  }
  savedCount = 0;
  size_t take = n < 2 ? n : 2;
  for (size_t i = 0; i < take; i++) {
    rememberSlot((uint8_t)i, rows[i].name, rows[i].id);
    savedCount = (uint8_t)(i + 1);
  }
  store.begin("ronin-c3", false);
  store.putUChar("lightCount", savedCount);
  store.end();
  bool ok = ulanziBlePair(rows[0].name, rows[0].id, reason, reasonCap);
  if (ok && savedCount > 1) {
    char extra[96];
    snprintf(extra, sizeof(extra), " · 2대 저장(%s)", savedNames[1]);
    strncat(reason, extra, reasonCap - strlen(reason) - 1);
  }
  return ok;
}

bool ulanziBleApplyAll(int brightness, int kelvin, bool on, char* reason, size_t reasonCap) {
  if (reason == nullptr || reasonCap == 0) return false;
  reason[0] = 0;
  if (savedCount == 0 && linkedName[0]) {
    savedCount = 1;
    rememberSlot(0, linkedName, linkedId);
  }
  if (savedCount == 0) {
    snprintf(reason, reasonCap, "저장된 울란지가 없습니다. 먼저 스캔·자동페어하세요.");
    return false;
  }
  char notes[180] = {};
  uint8_t okCount = 0;
  for (uint8_t i = 0; i < savedCount; i++) {
    char one[120];
    if (!ulanziBlePair(savedNames[i], savedIds[i], one, sizeof(one))) {
      strncat(notes, one, sizeof(notes) - strlen(notes) - 1);
      strncat(notes, " | ", sizeof(notes) - strlen(notes) - 1);
      continue;
    }
    if (!ulanziBleApply(brightness, kelvin, on, one, sizeof(one))) {
      strncat(notes, one, sizeof(notes) - strlen(notes) - 1);
      strncat(notes, " | ", sizeof(notes) - strlen(notes) - 1);
      continue;
    }
    okCount++;
    strncat(notes, one, sizeof(notes) - strlen(notes) - 1);
    strncat(notes, " | ", sizeof(notes) - strlen(notes) - 1);
  }
  snprintf(reason, reasonCap, "울란지 %u/%u 성공. %s", (unsigned)okCount, (unsigned)savedCount, notes);
  return okCount > 0;
}

static bool writePkt(const uint8_t* pkt, size_t len) {
  if (writeChar == nullptr || pkt == nullptr || len == 0) return false;
  if (writeChar->canWriteNoResponse()) {
    return writeChar->writeValue(pkt, len, false);
  }
  return writeChar->writeValue(pkt, len, true);
}

bool ulanziBleApply(int brightness, int kelvin, bool on, char* reason, size_t reasonCap) {
  if (reason == nullptr || reasonCap == 0) return false;
  reason[0] = 0;
  if (!ulanziBleLinked()) {
    if (linkedName[0]) {
      char pairReason[160];
      if (!ulanziBlePair(linkedName, linkedId, pairReason, sizeof(pairReason))) {
        snprintf(reason, reasonCap, "%s", pairReason);
        return false;
      }
    } else {
      snprintf(reason, reasonCap, "붙은 울란지가 없습니다. 앱에서 이름을 골라 붙이세요.");
      return false;
    }
  }

  if (!on) {
    const uint8_t off1[] = {0xFF, 0xA1, 0x01, 0x30, 0x30, 0xAA};
    const uint8_t off2[] = {0xFF, 0xA1, 0x01, 0x01, 0x01, 0xAA};
    if (!writePkt(off1, sizeof(off1))) {
      snprintf(reason, reasonCap, "울란지 끄기(1단계)를 쓰지 못했습니다.");
      clearLink(true);
      return false;
    }
    delay(80);
    if (!writePkt(off2, sizeof(off2))) {
      snprintf(reason, reasonCap, "울란지 끄기(2단계)를 쓰지 못했습니다.");
      clearLink(true);
      return false;
    }
    snprintf(reason, reasonCap, "울란지 %s 끄기를 보냈습니다.", linkedName);
    return true;
  }

  int level = brightness;
  if (level < 0) level = 0;
  if (level > 100) level = 100;
  int cct = kelvin;
  if (cct < 2700) cct = 2700;
  if (cct > 6500) cct = 6500;

  const uint8_t onPkt[] = {0xFF, 0xA1, 0x01, 0x00, 0x00, 0xAA};
  if (!writePkt(onPkt, sizeof(onPkt))) {
    snprintf(reason, reasonCap, "울란지 켜기를 쓰지 못했습니다.");
    clearLink(true);
    return false;
  }
  delay(50);
  uint8_t bri[] = {0xFF, 0xA2, 0x01, (uint8_t)level, (uint8_t)level, 0xAA};
  if (!writePkt(bri, sizeof(bri))) {
    snprintf(reason, reasonCap, "울란지 밝기를 쓰지 못했습니다.");
    clearLink(true);
    return false;
  }
  delay(50);
  uint8_t hi = (uint8_t)((cct >> 8) & 0xFF);
  uint8_t lo = (uint8_t)(cct & 0xFF);
  uint8_t chk = (uint8_t)((hi + lo) & 0xFF);
  uint8_t temp[] = {0xFF, 0xA3, 0x02, hi, lo, chk, 0xAA};
  if (!writePkt(temp, sizeof(temp))) {
    snprintf(reason, reasonCap, "울란지 색온도를 쓰지 못했습니다.");
    clearLink(true);
    return false;
  }
  snprintf(reason, reasonCap, "울란지 %s 켜기·밝기 %d·색온도 %dK 를 보냈습니다.", linkedName, level, cct);
  return true;
}
