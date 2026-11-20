#include "ronin_ble.h"
#include "board_net.h"
#include "board_slot.h"
#include "dji_duml.h"
#include "dji_r_frame.h"

#include <Preferences.h>
#include <ctype.h>
#include <string.h>

static constexpr size_t kMaxFound = 8;
static RoninFound found[kMaxFound];
static size_t foundCount = 0;

static NimBLEClient* client = nullptr;
static NimBLERemoteCharacteristic* writeChar = nullptr;
static NimBLERemoteCharacteristic* notifyChar = nullptr;
static bool linked = false;
static bool busy = false;
static bool authed = false;
static char linkedName[40] = {};
static char linkedId[24] = {};
static char writeUuid[8] = {};
static uint16_t seq = 1;
static uint16_t dumlSeq = 0x0100;
static Preferences store;
static RoninTarget targetFilter = RoninTarget::Any;

// FFF4 알림을 모아 응답 코드를 봅니다. write 성공만으로 움직였다고 치지 않습니다.
static constexpr size_t kRxCap = 256;
static uint8_t rxBuf[kRxCap];
static volatile size_t rxLen = 0;
static volatile uint8_t lastAaCmdSet = 0;
static volatile uint8_t lastAaCmdId = 0;
static volatile uint8_t lastAaRet = 0xFF;
static volatile bool lastAaOk = false;
static volatile uint8_t lastDumlCmdSet = 0;
static volatile uint8_t lastDumlCmdId = 0;
static volatile bool lastDumlSeen = false;

static void clearRx() {
  rxLen = 0;
  lastAaOk = false;
  lastAaRet = 0xFF;
  lastAaCmdSet = 0;
  lastAaCmdId = 0;
  lastDumlSeen = false;
  lastDumlCmdSet = 0;
  lastDumlCmdId = 0;
}

static void ingestNotify(const uint8_t* data, size_t len) {
  if (data == nullptr || len == 0) return;
  size_t at = rxLen;
  if (at >= kRxCap) {
    at = 0;
    rxLen = 0;
  }
  size_t n = len;
  if (at + n > kRxCap) n = kRxCap - at;
  memcpy(rxBuf + at, data, n);
  rxLen = at + n;

  // AA 프레임 스캔
  for (size_t i = 0; i + 16 <= rxLen; i++) {
    if (rxBuf[i] != 0xAA) continue;
    size_t total = (size_t)rxBuf[i + 1] | (((size_t)(rxBuf[i + 2] & 0x03)) << 8);
    if (total < 16 || total > 128 || i + total > rxLen) continue;
    uint8_t cmdSet = 0, cmdId = 0, cmdType = 0;
    const uint8_t* payload = nullptr;
    size_t payloadLen = 0;
    if (!djiParseHeader(rxBuf + i, total, &cmdSet, &cmdId, &cmdType, &payload, &payloadLen)) continue;
    lastAaCmdSet = cmdSet;
    lastAaCmdId = cmdId;
    if ((cmdType & 0x20) != 0 && payloadLen >= 1) {
      lastAaRet = payload[0];
      lastAaOk = true;
    }
  }
  // DUML 프레임 스캔
  for (size_t i = 0; i + 13 <= rxLen; i++) {
    if (rxBuf[i] != 0x55) continue;
    size_t total = (size_t)rxBuf[i + 1] | (((size_t)(rxBuf[i + 2] & 0x03)) << 8);
    if (total < 13 || total > 200 || i + total > rxLen) continue;
    lastDumlCmdSet = rxBuf[i + 9];
    lastDumlCmdId = rxBuf[i + 10];
    lastDumlSeen = true;
  }
}

static void onNotify(NimBLERemoteCharacteristic* /*c*/, uint8_t* data, size_t len, bool /*isNotify*/) {
  ingestNotify(data, len);
}

void roninBleSetTarget(RoninTarget target) { targetFilter = target; }
RoninTarget roninBleTarget() { return targetFilter; }

static bool passesTarget(const char* lower) {
  if (targetFilter == RoninTarget::Rs2Only) return nameMatchesRs2(lower);
  if (targetFilter == RoninTarget::ScOnly) return nameMatchesSc(lower);
  return true;
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

// RS·SC 공통: 이름에 ronin/rs/rsc 가 있거나, FFF0+DJI(0x08AA)이면서 액션캠 이름이 아닐 때.
// 공식 앱은 SC를 "Ronin-SC" 로 찾고 FFF0 을 씁니다. RS 2 실기 광고도 FFF0·DJI 제조사입니다.
static bool isActionCamName(const char* lower) {
  return textHas(lower, "osmo") || textHas(lower, "action") || textHas(lower, "pocket");
}

static bool hasDjiManufacturer(NimBLEAdvertisedDevice& device) {
  std::string raw = device.getManufacturerData();
  if (raw.size() < 2) return false;
  uint16_t company = (uint8_t)raw[0] | ((uint16_t)(uint8_t)raw[1] << 8);
  return company == 0x08AA;
}

static bool looksLikeRonin(NimBLEAdvertisedDevice& device) {
  std::string name = device.getName();
  char lower[64];
  lowerCopy(lower, sizeof(lower), name.c_str());
  if (isActionCamName(lower)) return false;
  // 우리 기판 핫스팟·광고 이름은 짐벌이 아닙니다(Ronin-S3 를 SC 로 오인하지 않음).
  if (isOurBoardBleName(lower)) return false;
  if (textHas(lower, "ronin") || textHas(lower, "ronin-sc") || textHas(lower, "ronin_sc") ||
      textHas(lower, "ronin sc") || textHas(lower, "dji rs") || textHas(lower, "rs 2") ||
      textHas(lower, "rs2") || textHas(lower, "rsc") || textHas(lower, "rsc2") ||
      textHas(lower, "rsc 2") || textHas(lower, "rs 3") || textHas(lower, "rs3") ||
      textHas(lower, "rs 4") || textHas(lower, "rs4")) {
    return true;
  }
  const bool fff0 = device.isAdvertisingService(NimBLEUUID((uint16_t)0xFFF0));
  // 이름이 비어 있어도 FFF0+DJI 면 짐벌 후보(SC 약전계에서 이름 누락 대비).
  if (fff0 && (hasDjiManufacturer(device) || textHas(lower, "dji") || name.empty())) {
    if (name.empty() && !hasDjiManufacturer(device) && targetFilter != RoninTarget::ScOnly) return false;
    return true;
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
  notifyChar = nullptr;
  linked = false;
  authed = false;
  writeUuid[0] = 0;
  clearRx();
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

static uint32_t nextAutoPairMs = 0;

void roninBleLoop() {
  if (client != nullptr && linked && !client->isConnected()) {
    Serial.println("로닌 블루투스가 끊겼습니다.");
    clearLink(true);
    nextAutoPairMs = millis() + 2000;
  }
  // OTA·재부팅 뒤 저장 이름으로 다시 붙습니다. 실패 시 간격을 늘려 스캔 폭주를 막습니다.
  if (!busy && !roninBleLinked() && linkedName[0] && millis() >= nextAutoPairMs) {
    nextAutoPairMs = millis() + 45000;
    char reason[160];
    if (roninBlePair(linkedName, linkedId, reason, sizeof(reason))) {
      Serial.println(reason);
      nextAutoPairMs = millis() + 8000;
    } else {
      Serial.println(reason);
    }
    boardNetPump();
  }
}

void roninBleDrop() { clearLink(false); }

bool roninBleBusy() { return busy; }

bool roninBleLinked() { return linked && client != nullptr && client->isConnected() && writeChar != nullptr; }

const char* roninBleName() { return linkedName[0] ? linkedName : ""; }

static void absorbScanResults(NimBLEScanResults& results) {
  for (int i = 0; i < results.getCount() && foundCount < kMaxFound; i++) {
    NimBLEAdvertisedDevice device = results.getDevice(i);
    if (!looksLikeRonin(device)) continue;
    std::string name = device.getName();
    if (name.empty()) {
      name = std::string("DJI-FFF0-") + device.getAddress().toString();
    }
    char lower[64];
    lowerCopy(lower, sizeof(lower), name.c_str());
    if (textHas(lower, "dji-fff0-")) {
      if (targetFilter != RoninTarget::ScOnly && targetFilter != RoninTarget::Any) continue;
    } else if (!passesTarget(lower)) {
      continue;
    }
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
}

size_t roninBleScan(RoninFound* out, size_t cap, bool manageBusy) {
  if (out == nullptr || cap == 0) return 0;
  if (manageBusy) busy = true;
  pauseProvision();
  if (NimBLEDevice::getScan()->isScanning()) {
    NimBLEDevice::getScan()->stop();
  }
  NimBLEScan* scan = NimBLEDevice::getScan();
  scan->setActiveScan(true);
  // 윈도우를 절반만 열어 와이파이·웹소켓이 BLE 스캔에 질식하지 않게 합니다.
  scan->setInterval(160);
  scan->setWindow(48);
  scan->setDuplicateFilter(false);
  foundCount = 0;
  // SC 약전계(-100 근처)는 짧으면 놓칩니다. SC 전용은 2초×8=16초.
  const int rounds = (targetFilter == RoninTarget::ScOnly) ? 8 : 5;
  // SC 는 윈도우를 조금 넓혀 약한 광고를 더 받습니다(와이파이와 타협).
  if (targetFilter == RoninTarget::ScOnly) {
    scan->setInterval(120);
    scan->setWindow(80);
  }
  for (int round = 0; round < rounds; round++) {
    NimBLEScanResults results = scan->start(2, false);
    absorbScanResults(results);
    scan->clearResults();
    boardNetPump();
    if (foundCount > 0 && targetFilter == RoninTarget::ScOnly) break;  // 하나라도 잡히면 바로 끝
  }
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

static bool bleWrite(const uint8_t* frame, size_t len) {
  if (writeChar == nullptr || frame == nullptr || len == 0) return false;
  if (writeChar->canWriteNoResponse()) {
    return writeChar->writeValue(frame, len, false);
  }
  return writeChar->writeValue(frame, len, true);
}

static bool waitAaReply(uint8_t wantSet, uint8_t wantId, uint32_t ms) {
  uint32_t start = millis();
  while (millis() - start < ms) {
    boardNetPump();
    if (lastAaOk && lastAaCmdSet == wantSet && lastAaCmdId == wantId) return true;
    delay(5);
  }
  return lastAaOk && lastAaCmdSet == wantSet && lastAaCmdId == wantId;
}

static bool waitAnyNotify(uint32_t ms) {
  uint32_t start = millis();
  size_t before = rxLen;
  while (millis() - start < ms) {
    boardNetPump();
    if (rxLen > before || lastAaOk || lastDumlSeen) return true;
    delay(5);
  }
  return rxLen > before || lastAaOk || lastDumlSeen;
}

static bool openServices(NimBLEClient* next, char* reason, size_t reasonCap) {
  NimBLERemoteService* service = next->getService(NimBLEUUID((uint16_t)0xFFF0));
  if (service == nullptr) {
    snprintf(reason, reasonCap, "로닌 서비스 FFF0 을 찾지 못했습니다.");
    return false;
  }
  clearRx();
  notifyChar = service->getCharacteristic(NimBLEUUID((uint16_t)0xFFF4));
  if (notifyChar != nullptr && notifyChar->canNotify()) {
    notifyChar->subscribe(true, onNotify, true);
    delay(80);
  }
  // FFF5 만 씁니다. FFF3 은 쓰기가 받아도 짐벌이 무시하는 경우가 있습니다.
  NimBLERemoteCharacteristic* write = service->getCharacteristic(NimBLEUUID((uint16_t)0xFFF5));
  const char* uuidUsed = "FFF5";
  if (write == nullptr || !(write->canWrite() || write->canWriteNoResponse())) {
    write = service->getCharacteristic(NimBLEUUID((uint16_t)0xFFF3));
    uuidUsed = "FFF3";
  }
  if (write == nullptr || !(write->canWrite() || write->canWriteNoResponse())) {
    snprintf(reason, reasonCap, "로닌 쓰기 특성 FFF5·FFF3 을 찾지 못했습니다.");
    return false;
  }
  writeChar = write;
  strncpy(writeUuid, uuidUsed, sizeof(writeUuid) - 1);
  Serial.printf("로닌 쓰기 특성 %s (notify=%s)\n", writeUuid, notifyChar ? "FFF4" : "없음");

  // FFF4 에 [0x01,0x00] 페어 트리거(오즈모·로닌 공통 패턴).
  if (notifyChar != nullptr && (notifyChar->canWrite() || notifyChar->canWriteNoResponse())) {
    uint8_t kick[2] = {0x01, 0x00};
    if (notifyChar->canWriteNoResponse()) notifyChar->writeValue(kick, 2, false);
    else notifyChar->writeValue(kick, 2, true);
    delay(120);
    waitAnyNotify(250);
  }

  // AA 연결 요청(0x00/0x19). 저장 페어 모드.
  uint8_t mac[6] = {};
  NimBLEAddress addr = next->getPeerAddress();
  // NimBLEAddress 문자열 "aa:bb:..." 파싱은 생략하고 0 으로 둡니다.
  (void)addr;
  uint8_t auth[64];
  size_t authLen = djiAuthConnect(auth, sizeof(auth), seq++, 0xC3000001u, mac, 0, 0);
  if (authLen > 0) {
    clearRx();
    if (bleWrite(auth, authLen)) {
      waitAaReply(0x00, 0x19, 800);
      if (lastAaOk && lastAaCmdSet == 0x00 && lastAaCmdId == 0x19) {
        authed = (lastAaRet == 0);
        Serial.printf("로닌 AA 인증 응답 ret=%u\n", (unsigned)lastAaRet);
      } else {
        Serial.println("로닌 AA 인증 응답 없음(계속 시도).");
      }
    }
  }
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

  // 스캔에 없어도 저장·요청 MAC 으로 바로 붙습니다(광고 sleep 대비).
  char connectId[24] = {};
  uint8_t connectType = BLE_ADDR_PUBLIC;
  char connectName[40] = {};
  if (hit != nullptr) {
    strncpy(connectId, hit->id, sizeof(connectId) - 1);
    connectType = hit->addrType;
    strncpy(connectName, hit->name, sizeof(connectName) - 1);
  } else if (wantId[0]) {
    strncpy(connectId, wantId, sizeof(connectId) - 1);
    strncpy(connectName, wantName[0] ? wantName : wantId, sizeof(connectName) - 1);
  } else {
    busy = false;
    resumeProvision();
    snprintf(reason, reasonCap, "주변에서 그 로닌 이름을 찾지 못했습니다. 먼저 스캔하세요.");
    return false;
  }

  NimBLEAddress address(std::string(connectId), connectType);
  NimBLEClient* next = NimBLEDevice::createClient();
  if (next == nullptr) {
    busy = false;
    resumeProvision();
    snprintf(reason, reasonCap, "블루투스 클라이언트를 만들지 못했습니다.");
    return false;
  }
  next->setConnectTimeout(6);
  boardNetPump();
  if (!next->connect(address)) {
    boardNetPump();
    // public 실패 시 random 주소로 한 번 더(SC 일부).
    if (hit == nullptr) {
      NimBLEAddress alt(std::string(connectId), BLE_ADDR_RANDOM);
      if (!next->connect(alt)) {
        NimBLEDevice::deleteClient(next);
        busy = false;
        resumeProvision();
        snprintf(reason, reasonCap, "로닌 블루투스에 붙지 못했습니다. 짐벌 화면에서 블루투스를 켠 뒤 다시 누르세요.");
        return false;
      }
    } else {
      NimBLEDevice::deleteClient(next);
      busy = false;
      resumeProvision();
      snprintf(reason, reasonCap, "로닌 블루투스에 붙지 못했습니다. 짐벌 화면에서 블루투스를 켠 뒤 다시 누르세요.");
      return false;
    }
  }
  boardNetPump();
  if (!openServices(next, reason, reasonCap)) {
    next->disconnect();
    NimBLEDevice::deleteClient(next);
    busy = false;
    resumeProvision();
    return false;
  }
  client = next;
  linked = true;
  strncpy(linkedName, connectName, sizeof(linkedName) - 1);
  strncpy(linkedId, connectId, sizeof(linkedId) - 1);
  store.begin("ronin-c3", false);
  store.putString("gimbalName", linkedName);
  store.putString("gimbalId", linkedId);
  store.end();
  busy = false;
  snprintf(reason, reasonCap, "로닌 %s 에 블루투스로 붙었습니다.", linkedName);
  Serial.println(reason);
  return true;
}

bool roninBleAutoPair(char* reason, size_t reasonCap) {
  if (reason == nullptr || reasonCap == 0) return false;
  reason[0] = 0;
  if (roninBleLinked()) {
    snprintf(reason, reasonCap, "이미 %s 에 붙어 있습니다.", linkedName);
    return true;
  }
  if (linkedName[0]) {
    return roninBlePair(linkedName, linkedId, reason, reasonCap);
  }
  RoninFound rows[kMaxFound];
  size_t n = roninBleScan(rows, kMaxFound);
  if (n == 0) {
    snprintf(reason, reasonCap, "담당 로닌을 찾지 못했습니다.");
    return false;
  }
  return roninBlePair(rows[0].name, rows[0].id, reason, reasonCap);
}

static void hexShort(char* out, size_t cap, const uint8_t* data, size_t len) {
  if (out == nullptr || cap < 3) return;
  size_t n = len;
  if (n > 12) n = 12;
  size_t at = 0;
  for (size_t i = 0; i < n && at + 3 < cap; i++) {
    at += (size_t)snprintf(out + at, cap - at, "%02x", data[i]);
  }
  if (len > n && at + 2 < cap) snprintf(out + at, cap - at, "..");
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

  char path[48] = {};
  char txHex[40] = {};
  bool moved = false;

  // 로닌 BLE 는 DUML(0x55) 응답이 확인됨. AA(R SDK)는 CAN 용이라 BLE 에서는 먼저 쓰지 않습니다.
  // 1) DUML follow 모드 + 절대각
  {
    uint8_t mode[40];
    size_t modeLen = dumlSetMode(mode, sizeof(mode), dumlSeq++, 1);
    if (modeLen > 0) bleWrite(mode, modeLen);
    delay(40);
    uint8_t frame[48];
    size_t len = dumlAbsAngle(frame, sizeof(frame), dumlSeq++, yawDeg, pitchDeg, 2.0f);
    clearRx();
    hexShort(txHex, sizeof(txHex), frame, len);
    if (len > 0 && bleWrite(frame, len)) {
      if (waitAnyNotify(800) && lastDumlSeen) {
        moved = true;
        snprintf(path, sizeof(path), "DUML-abs notify");
      }
    }
  }

  // 2) DUML 속도 버스트(눈에 보이는 움직임)
  if (!moved) {
    uint8_t frame[48];
    float yawSpeed = home ? 0.0f : (yawDeg >= 0 ? 20.0f : -20.0f);
    float pitchSpeed = home ? 0.0f : (pitchDeg == 0 ? 0.0f : (pitchDeg >= 0 ? 15.0f : -15.0f));
    if (yawDeg == 0 && pitchDeg != 0) yawSpeed = 0;
    size_t len = dumlSpeed(frame, sizeof(frame), dumlSeq++, yawSpeed, pitchSpeed);
    clearRx();
    if (len > 0 && bleWrite(frame, len)) {
      hexShort(txHex, sizeof(txHex), frame, len);
      bool seen = waitAnyNotify(600);
      delay(500);
      uint8_t stop[48];
      size_t stopLen = dumlSpeed(stop, sizeof(stop), dumlSeq++, 0, 0);
      if (stopLen > 0) bleWrite(stop, stopLen);
      if (seen && lastDumlSeen) {
        moved = true;
        snprintf(path, sizeof(path), "DUML-speed notify");
      }
    }
  }

  // 3) AA 절대 — 예전 CAN/액션캠 경로 폴백
  if (!moved) {
    uint8_t frame[48];
    size_t len = djiMoveTo(frame, sizeof(frame), seq++, yawDeg, pitchDeg, 2.0f, true);
    clearRx();
    if (len > 0 && bleWrite(frame, len)) {
      hexShort(txHex, sizeof(txHex), frame, len);
      if (waitAaReply(0x0E, 0x00, 500) && lastAaRet == 0) {
        moved = true;
        snprintf(path, sizeof(path), "AA-abs ret0");
      }
    }
  }

  // 4) AA 상대
  if (!moved) {
    uint8_t frame[48];
    size_t len = djiMoveTo(frame, sizeof(frame), seq++, yawDeg, pitchDeg, 2.0f, false);
    clearRx();
    if (len > 0 && bleWrite(frame, len)) {
      hexShort(txHex, sizeof(txHex), frame, len);
      if (waitAaReply(0x0E, 0x00, 500) && lastAaRet == 0) {
        moved = true;
        snprintf(path, sizeof(path), "AA-rel ret0");
      }
    }
  }

  if (moved) {
    snprintf(reason, reasonCap,
             "로닌 %s 팬 %.0f° 틸트 %.0f° · %s · 특성 %s · 프로토콜응답 있음. 지금 움직이는지 봐 주세요.",
             linkedName, yawDeg, pitchDeg, path, writeUuid[0] ? writeUuid : "?");
    return true;
  }

  // write 만 되고 응답이 없으면 가짜 성공이므로 false.
  snprintf(reason, reasonCap,
           "로닌 %s BLE write 는 됐지만 짐벌 응답 없음(특성 %s tx %s aaRet=%u duml=%u). 프레임/모드 재확인 중.",
           linkedName, writeUuid[0] ? writeUuid : "?", txHex[0] ? txHex : "-",
           (unsigned)lastAaRet, (unsigned)lastDumlSeen);
  return false;
}

bool roninBleZoom(int16_t speed, char* reason, size_t reasonCap) {
  if (reason == nullptr || reasonCap == 0) return false;
  reason[0] = 0;
#if defined(BOARD_SLOT_RMSID)
  (void)speed;
  snprintf(reason, reasonCap,
           "SC 줌은 아직 없습니다. UI·프로토콜 자리만 두었고, 지금은 RS2 줌만 씁니다.");
  return false;
#else
  if (!roninBleLinked()) {
    snprintf(reason, reasonCap, "붙은 로닌이 없습니다. 앱에서 이름을 골라 붙이세요.");
    return false;
  }
  // 이름에 SC 만 있으면 RS2 줌 경로를 쓰지 않습니다.
  {
    char lower[40];
    lowerCopy(lower, sizeof(lower), linkedName);
    if (nameMatchesSc(lower) && !nameMatchesRs2(lower)) {
      snprintf(reason, reasonCap,
               "SC 줌은 아직 없습니다. UI·프로토콜 자리만 두었고, 지금은 RS2 줌만 씁니다.");
      return false;
    }
  }

  if (speed < -2048) speed = -2048;
  if (speed > 2048) speed = 2048;

  uint8_t frame[48];
  size_t len = djiDial(frame, sizeof(frame), seq++, speed);
  if (len == 0) {
    snprintf(reason, reasonCap, "줌 프레임을 만들지 못했습니다.");
    return false;
  }

  char txHex[40] = {};
  hexShort(txHex, sizeof(txHex), frame, len);
  clearRx();
  if (!bleWrite(frame, len)) {
    snprintf(reason, reasonCap, "로닌 줌 쓰기 실패(특성 %s).", writeUuid[0] ? writeUuid : "?");
    return false;
  }

  if (speed == 0) {
    snprintf(reason, reasonCap, "로닌 %s 줌 멈춤.", linkedName);
    return true;
  }

  // dial(0x0E/0x0A) 응답이 오면 성공. 없으면 write-only 가짜 성공으로 치지 않습니다.
  if (waitAaReply(0x0E, 0x0A, 900) && lastAaRet == 0) {
    snprintf(reason, reasonCap,
             "로닌 %s 줌 %s(속도 %d) · AA dial ret0 · 특성 %s. 렌즈/모터가 도는지 봐 주세요.",
             linkedName, speed > 0 ? "인" : "아웃", (int)speed, writeUuid[0] ? writeUuid : "?");
    return true;
  }
  if (waitAnyNotify(200) && lastDumlSeen) {
    snprintf(reason, reasonCap,
             "로닌 %s 줌 %s write+notify(속도 %d, aaRet=%u). 렌즈가 도는지 봐 주세요.",
             linkedName, speed > 0 ? "인" : "아웃", (int)speed, (unsigned)lastAaRet);
    return true;
  }

  snprintf(reason, reasonCap,
           "로닌 %s 줌 %s write 는 됐지만 응답 없음(속도 %d tx %s aaRet=%u). 렌즈가 도는지 확인해 주세요.",
           linkedName, speed > 0 ? "인" : "아웃", (int)speed, txHex[0] ? txHex : "-",
           (unsigned)lastAaRet);
  return false;
#endif
}
