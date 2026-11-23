#include "ulanzi_ble.h"
#include "board_net.h"

#include <Preferences.h>
#include <ctype.h>
#include <string.h>

// 관측 근거 (2026-11-20, 맥 bleak):
// - 광고 이름 "Ulanzi light(...)", 광고 서비스 0xAE00
// - 연결 후 서비스 0xFFF0, 쓰기 0xFFF2(WR), 알림 0xFFF1
// 지연 대응 (2026-11-21):
// - 저장된 2대를 동시에 붙인 채로 유지(칸 전환 재페어 ~3초 제거)
// - 적용 중이면 칸별 최신값만 덮어쓰고 루프가 40ms 간격으로 비움

static constexpr size_t kMaxFound = 8;
static UlanziFound found[kMaxFound];
static size_t foundCount = 0;

struct LightLink {
  NimBLEClient* client = nullptr;
  NimBLERemoteCharacteristic* writeChar = nullptr;
  char name[40] = {};
  char id[24] = {};
  bool linked = false;
};

static LightLink links[2];
static bool busy = false;
static char savedNames[2][40] = {};
static char savedIds[2][24] = {};
static uint8_t savedCount = 0;
static Preferences store;

struct PendingLight {
  bool valid = false;
  int brightness = 40;
  int kelvin = 4500;
  bool on = true;
};
static PendingLight pending[2];
static uint32_t lastApplyMs = 0;
static constexpr uint32_t kMinApplyGapMs = 40;

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

static bool anyLinked() {
  for (uint8_t i = 0; i < 2; i++) {
    if (links[i].linked && links[i].client != nullptr && links[i].client->isConnected() && links[i].writeChar != nullptr) {
      return true;
    }
  }
  return false;
}

static void clearOne(uint8_t slot, bool keepPrefs) {
  if (slot >= 2) return;
  LightLink& L = links[slot];
  L.writeChar = nullptr;
  L.linked = false;
  L.name[0] = 0;
  L.id[0] = 0;
  if (L.client != nullptr) {
    if (L.client->isConnected()) L.client->disconnect();
    delay(80);
    NimBLEDevice::deleteClient(L.client);
    L.client = nullptr;
    delay(40);
  }
  if (!keepPrefs && slot == 0) {
    store.begin("ronin-c3", false);
    store.remove("lightName");
    store.remove("lightId");
    store.end();
  }
}

static void clearLink(bool keepPrefs) {
  clearOne(0, keepPrefs);
  clearOne(1, keepPrefs);
  resumeProvision();
}

static bool linkAlive(uint8_t slot) {
  if (slot >= 2) return false;
  LightLink& L = links[slot];
  return L.linked && L.client != nullptr && L.client->isConnected() && L.writeChar != nullptr;
}

static int slotForId(const char* id) {
  if (id == nullptr || id[0] == 0) return -1;
  for (uint8_t i = 0; i < savedCount; i++) {
    if (strcasecmp(savedIds[i], id) == 0) return (int)i;
  }
  return -1;
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
}

uint8_t ulanziBleSavedCount() { return savedCount; }

static bool writePkt(LightLink& L, const uint8_t* pkt, size_t len) {
  if (L.writeChar == nullptr || pkt == nullptr || len == 0) return false;
  if (L.writeChar->canWriteNoResponse()) {
    return L.writeChar->writeValue(pkt, len, false);
  }
  return L.writeChar->writeValue(pkt, len, true);
}

static bool applyOnLink(LightLink& L, int brightness, int kelvin, bool on, char* reason, size_t reasonCap) {
  if (reason == nullptr || reasonCap == 0) return false;
  reason[0] = 0;
  if (!(L.linked && L.client != nullptr && L.client->isConnected() && L.writeChar != nullptr)) {
    snprintf(reason, reasonCap, "붙은 울란지가 없습니다. 앱에서 이름을 골라 붙이세요.");
    return false;
  }
  if (!on) {
    const uint8_t off1[] = {0xFF, 0xA1, 0x01, 0x30, 0x30, 0xAA};
    const uint8_t off2[] = {0xFF, 0xA1, 0x01, 0x01, 0x01, 0xAA};
    if (!writePkt(L, off1, sizeof(off1))) {
      snprintf(reason, reasonCap, "울란지 끄기(1단계)를 쓰지 못했습니다.");
      return false;
    }
    delay(15);
    if (!writePkt(L, off2, sizeof(off2))) {
      snprintf(reason, reasonCap, "울란지 끄기(2단계)를 쓰지 못했습니다.");
      return false;
    }
    snprintf(reason, reasonCap, "울란지 %s 끄기를 보냈습니다.", L.name);
    return true;
  }

  int level = brightness;
  if (level < 0) level = 0;
  if (level > 100) level = 100;
  int cct = kelvin;
  if (cct < 2700) cct = 2700;
  if (cct > 6500) cct = 6500;

  const uint8_t onPkt[] = {0xFF, 0xA1, 0x01, 0x00, 0x00, 0xAA};
  if (!writePkt(L, onPkt, sizeof(onPkt))) {
    snprintf(reason, reasonCap, "울란지 켜기를 쓰지 못했습니다.");
    return false;
  }
  delay(10);
  uint8_t bri[] = {0xFF, 0xA2, 0x01, (uint8_t)level, (uint8_t)level, 0xAA};
  if (!writePkt(L, bri, sizeof(bri))) {
    snprintf(reason, reasonCap, "울란지 밝기를 쓰지 못했습니다.");
    return false;
  }
  delay(10);
  uint8_t hi = (uint8_t)((cct >> 8) & 0xFF);
  uint8_t lo = (uint8_t)(cct & 0xFF);
  uint8_t chk = (uint8_t)((hi + lo) & 0xFF);
  uint8_t temp[] = {0xFF, 0xA3, 0x02, hi, lo, chk, 0xAA};
  if (!writePkt(L, temp, sizeof(temp))) {
    snprintf(reason, reasonCap, "울란지 색온도를 쓰지 못했습니다.");
    return false;
  }
  snprintf(reason, reasonCap, "울란지 %s 켜기·밝기 %d·색온도 %dK 를 보냈습니다.", L.name, level, cct);
  return true;
}

static bool openServices(NimBLEClient* next, LightLink& L, char* reason, size_t reasonCap) {
  NimBLERemoteService* service = next->getService(NimBLEUUID((uint16_t)0xFFF0));
  if (service == nullptr) {
    snprintf(reason, reasonCap, "울란지 서비스 FFF0 을 찾지 못했습니다.");
    return false;
  }
  NimBLERemoteCharacteristic* notify = service->getCharacteristic(NimBLEUUID((uint16_t)0xFFF1));
  if (notify != nullptr && notify->canNotify()) {
    notify->subscribe(true, nullptr, true);
    delay(30);
  }
  NimBLERemoteCharacteristic* write = service->getCharacteristic(NimBLEUUID((uint16_t)0xFFF2));
  if (write == nullptr || !(write->canWrite() || write->canWriteNoResponse())) {
    snprintf(reason, reasonCap, "울란지 쓰기 특성 FFF2 를 찾지 못했습니다.");
    return false;
  }
  L.writeChar = write;
  return true;
}

static bool connectSlot(uint8_t slot, const char* name, const char* id, char* reason, size_t reasonCap) {
  if (slot >= 2) {
    snprintf(reason, reasonCap, "울란지 칸이 잘못되었습니다.");
    return false;
  }
  if (linkAlive(slot) && id != nullptr && id[0] && strcasecmp(links[slot].id, id) == 0) {
    snprintf(reason, reasonCap, "울란지 %s 에 이미 붙어 있습니다.", links[slot].name);
    return true;
  }
  clearOne(slot, true);
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
    resumeProvision();
    snprintf(reason, reasonCap, "주변에서 그 울란지 이름을 찾지 못했습니다. 먼저 스캔하세요.");
    return false;
  }

  NimBLEAddress address(std::string(hit->id), hit->addrType);
  NimBLEClient* next = NimBLEDevice::createClient();
  if (next == nullptr) {
    resumeProvision();
    snprintf(reason, reasonCap, "블루투스 클라이언트를 만들지 못했습니다.");
    return false;
  }
  next->setConnectTimeout(6);
  if (!next->connect(address)) {
    NimBLEDevice::deleteClient(next);
    resumeProvision();
    snprintf(reason, reasonCap, "울란지 블루투스에 붙지 못했습니다. 다른 기기가 붙어 있으면 끊고 다시 누르세요.");
    return false;
  }
  next->updateConnParams(6, 12, 0, 200);
  LightLink& L = links[slot];
  if (!openServices(next, L, reason, reasonCap)) {
    next->disconnect();
    NimBLEDevice::deleteClient(next);
    resumeProvision();
    return false;
  }
  L.client = next;
  L.linked = true;
  strncpy(L.name, hit->name, sizeof(L.name) - 1);
  strncpy(L.id, hit->id, sizeof(L.id) - 1);
  rememberSlot(slot, L.name, L.id);
  if (savedCount < slot + 1) savedCount = slot + 1;
  store.begin("ronin-c3", false);
  store.putUChar("lightCount", savedCount);
  store.end();
  snprintf(reason, reasonCap, "울란지 %s 에 블루투스로 붙었습니다.", L.name);
  Serial.println(reason);
  return true;
}

void ulanziBleLoop() {
  // 끊김: prefs 는 유지한 채 표시만 내리고, 아래에서 저장 이름으로 조용히 다시 붙입니다(스캔·자동페어 없음).
  for (uint8_t i = 0; i < 2; i++) {
    if (links[i].client != nullptr && links[i].linked && !links[i].client->isConnected()) {
      Serial.print("울란지 칸 ");
      Serial.print(i);
      Serial.println(" 블루투스가 끊겼습니다. 저장 이름으로 다시 붙입니다.");
      clearOne(i, true);
    }
  }
  if (busy) return;
  // 저장된 칸이 비었으면 스캔 없이 재연결만(루프 자동페어 제거로 불안정 완화).
  for (uint8_t i = 0; i < 2; i++) {
    if (linkAlive(i) || !savedNames[i][0]) continue;
    if ((uint32_t)(millis() - lastApplyMs) < 800) break;
    busy = true;
    char reason[160];
    connectSlot(i, savedNames[i], savedIds[i], reason, sizeof(reason));
    lastApplyMs = millis();
    busy = false;
    return;
  }
  if ((uint32_t)(millis() - lastApplyMs) < kMinApplyGapMs) return;
  for (uint8_t i = 0; i < 2; i++) {
    if (!pending[i].valid) continue;
    PendingLight job = pending[i];
    pending[i].valid = false;
    busy = true;
    char reason[160];
    if (!linkAlive(i) && savedNames[i][0]) {
      connectSlot(i, savedNames[i], savedIds[i], reason, sizeof(reason));
    }
    if (linkAlive(i)) {
      applyOnLink(links[i], job.brightness, job.kelvin, job.on, reason, sizeof(reason));
    }
    lastApplyMs = millis();
    busy = false;
    return;  // 한 루프에 한 칸만(최신값 덮어쓰기와 맞춤)
  }
}

void ulanziBleDrop() { clearLink(false); }

bool ulanziBleBusy() { return busy; }

bool ulanziBleLinked() { return anyLinked(); }

const char* ulanziBleName() {
  for (uint8_t i = 0; i < 2; i++) {
    if (linkAlive(i)) return links[i].name;
  }
  return savedNames[0][0] ? savedNames[0] : "";
}

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
  if (!anyLinked()) resumeProvision();
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
  if (anyLinked()) {
    doc["paired"] = ulanziBleName();
    for (uint8_t i = 0; i < 2; i++) {
      if (linkAlive(i)) {
        doc["pairedId"] = links[i].id;
        break;
      }
    }
  } else if (savedNames[0][0]) {
    doc["saved"] = savedNames[0];
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
    row["linked"] = linkAlive(i);
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

bool ulanziBlePair(const char* name, const char* id, char* reason, size_t reasonCap) {
  if (reason == nullptr || reasonCap == 0) return false;
  reason[0] = 0;
  if ((name == nullptr || name[0] == 0) && (id == nullptr || id[0] == 0)) {
    snprintf(reason, reasonCap, "붙일 울란지 이름이 없습니다.");
    return false;
  }
  busy = true;
  uint8_t slot = 0;
  int known = slotForId(id);
  if (known >= 0) {
    slot = (uint8_t)known;
  } else {
    for (uint8_t i = 0; i < savedCount; i++) {
      if (name && strcmp(savedNames[i], name) == 0) {
        slot = i;
        known = i;
        break;
      }
    }
    if (known < 0) {
      slot = savedCount < 2 ? savedCount : 1;
    }
  }
  bool ok = connectSlot(slot, name, id, reason, reasonCap);
  busy = false;
  return ok;
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
  busy = true;
  bool ok0 = connectSlot(0, rows[0].name, rows[0].id, reason, reasonCap);
  bool ok1 = true;
  if (savedCount > 1) {
    char extra[160];
    ok1 = connectSlot(1, rows[1].name, rows[1].id, extra, sizeof(extra));
    if (ok0) {
      strncat(reason, " · ", reasonCap - strlen(reason) - 1);
      strncat(reason, ok1 ? extra : "2대째 연결 실패", reasonCap - strlen(reason) - 1);
    }
  }
  busy = false;
  return ok0;
}

bool ulanziBleApply(int brightness, int kelvin, bool on, char* reason, size_t reasonCap) {
  if (reason == nullptr || reasonCap == 0) return false;
  // 단일 적용: 붙어 있는 첫 칸, 없으면 칸0
  uint8_t slot = 0;
  for (uint8_t i = 0; i < 2; i++) {
    if (linkAlive(i)) {
      slot = i;
      break;
    }
  }
  return ulanziBleApplyIndex(slot, brightness, kelvin, on, reason, reasonCap);
}

bool ulanziBleApplyIndex(uint8_t index, int brightness, int kelvin, bool on, char* reason, size_t reasonCap) {
  if (reason == nullptr || reasonCap == 0) return false;
  reason[0] = 0;
  if (index >= savedCount || !savedNames[index][0]) {
    snprintf(reason, reasonCap, "울란지 칸 %u 가 비어 있습니다. 먼저 스캔·붙이기를 하세요.", (unsigned)index);
    return false;
  }
  // 이미 붙어 있고 바쁨이면 최신값만 남기고 즉시 응답(슬라이더 체감).
  if (busy || ((uint32_t)(millis() - lastApplyMs) < kMinApplyGapMs && linkAlive(index))) {
    pending[index].valid = true;
    pending[index].brightness = brightness;
    pending[index].kelvin = kelvin;
    pending[index].on = on;
    snprintf(reason, reasonCap, "울란지 칸 %u 최신값을 예약했습니다.", (unsigned)index);
    return true;
  }
  busy = true;
  if (!linkAlive(index)) {
    char pairReason[160];
    if (!connectSlot(index, savedNames[index], savedIds[index], pairReason, sizeof(pairReason))) {
      snprintf(reason, reasonCap, "%s", pairReason);
      busy = false;
      return false;
    }
  }
  bool ok = applyOnLink(links[index], brightness, kelvin, on, reason, reasonCap);
  lastApplyMs = millis();
  // 예약이 더 있으면 남깁니다(루프가 비움).
  busy = false;
  return ok;
}

bool ulanziBleApplyAll(int brightness, int kelvin, bool on, char* reason, size_t reasonCap) {
  if (reason == nullptr || reasonCap == 0) return false;
  reason[0] = 0;
  if (savedCount == 0) {
    snprintf(reason, reasonCap, "저장된 울란지가 없습니다. 먼저 스캔·자동페어하세요.");
    return false;
  }
  char notes[180] = {};
  uint8_t okCount = 0;
  for (uint8_t i = 0; i < savedCount; i++) {
    char one[120];
    if (!linkAlive(i)) {
      if (!connectSlot(i, savedNames[i], savedIds[i], one, sizeof(one))) {
        strncat(notes, one, sizeof(notes) - strlen(notes) - 1);
        strncat(notes, " | ", sizeof(notes) - strlen(notes) - 1);
        continue;
      }
    }
    if (!applyOnLink(links[i], brightness, kelvin, on, one, sizeof(one))) {
      strncat(notes, one, sizeof(notes) - strlen(notes) - 1);
      strncat(notes, " | ", sizeof(notes) - strlen(notes) - 1);
      continue;
    }
    okCount++;
    strncat(notes, one, sizeof(notes) - strlen(notes) - 1);
    strncat(notes, " | ", sizeof(notes) - strlen(notes) - 1);
  }
  lastApplyMs = millis();
  snprintf(reason, reasonCap, "울란지 %u/%u 성공. %s", (unsigned)okCount, (unsigned)savedCount, notes);
  return okCount > 0;
}
