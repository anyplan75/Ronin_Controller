#include <Arduino.h>
#include <ArduinoJson.h>
#include <NimBLEDevice.h>
#include <Preferences.h>
#include <WebSocketsServer.h>
#include <WiFi.h>
#include <esp_netif.h>
#include <esp_wifi.h>
#include <math.h>

#include "board_net.h"
#include "board_oled.h"
#include "board_ota.h"
#include "board_slot.h"
#if defined(BOARD_HAS_RONIN)
#include "ronin_ble.h"
#endif
#if defined(BOARD_HAS_LIGHT)
#include "ulanzi_ble.h"
#endif

#if __has_include("wifi_local.h")
#include "wifi_local.h"
#define C3_HAS_WIFI 1
#else
#define C3_HAS_WIFI 0
#endif

// 보드 슬롯: OLED=RS2, RMSID=SC, S3=울란지. 역할을 섞지 않습니다.
// 로닌·울란지는 블루투스. CAN 아님. 조명은 카메라 탈리와 별개입니다.

static WebSocketsServer socket(82);
static Preferences prefs;
static BoardSlot slot = kDefaultSlot;
static String job = "ronin";
static bool clientUp = false;
static uint32_t nextAutoPairAt = 0;

void boardNetPump() {
  socket.loop();
  yield();
}

static void applySlot(BoardSlot next) {
  slot = next;
  prefs.putString("slot", slotId(slot));
  if (slotIsLight(slot)) {
    job = "light";
#if defined(BOARD_HAS_RONIN)
    roninBleDrop();
#endif
#if defined(BOARD_HAS_LIGHT)
    ulanziBleBegin();
#endif
  } else {
    job = "ronin";
#if defined(BOARD_HAS_LIGHT)
    ulanziBleDrop();
#endif
#if defined(BOARD_HAS_RONIN)
    roninBleSetTarget(slot == BoardSlot::OledRs2 ? RoninTarget::Rs2Only : RoninTarget::ScOnly);
    roninBleBegin();
#endif
  }
  prefs.putString("job", job);
}

// OLED/I2C 는 BLE 를 밀 수 있어, 내용이 바뀌거나 150~200ms 마다만 갱신.
static uint32_t lastOledMs = 0;
static char lastOledSig[72] = {};

static void refreshOled(bool force = false) {
  if (slot != BoardSlot::OledRs2) return;
  char l1[24];
  char l2[24];
  char l3[40];
  snprintf(l1, sizeof(l1), "%s", slotTitle(slot));
  if (WiFi.status() == WL_CONNECTED) {
    String ip = WiFi.localIP().toString();
    snprintf(l2, sizeof(l2), "%s", ip.c_str());
  } else {
    snprintf(l2, sizeof(l2), "WiFi...");
  }
#if defined(BOARD_HAS_RONIN)
  if (roninBleLinked()) snprintf(l3, sizeof(l3), "%s", roninBleName());
  else snprintf(l3, sizeof(l3), "no pair");
#else
  snprintf(l3, sizeof(l3), "light");
#endif
  char sig[72];
  snprintf(sig, sizeof(sig), "%s|%s|%s", l1, l2, l3);
  uint32_t now = millis();
  bool changed = strcmp(sig, lastOledSig) != 0;
  if (!force && !changed && (now - lastOledMs) < 180) return;
  if (!force && changed && (now - lastOledMs) < 120) return;  // 제어 중 과다 I2C 억제
  strncpy(lastOledSig, sig, sizeof(lastOledSig) - 1);
  lastOledMs = now;
  boardOledShow(l1, l2, l3);
}

static void replyDoc(uint8_t num, JsonDocument& doc) {
  doc["job"] = job;
  doc["slot"] = slotId(slot);
  doc["fw"] = FW_VERSION;
  doc["wifiMac"] = WiFi.macAddress();
  doc["apMac"] = WiFi.softAPmacAddress();
  if (WiFi.status() == WL_CONNECTED) doc["host"] = WiFi.localIP().toString();
  if (slot == BoardSlot::OledRs2) doc["oledReady"] = boardOledReady() ? 1 : 0;
  if (job == "ronin") {
#if defined(BOARD_HAS_RONIN)
    if (roninBleLinked()) doc["paired"] = roninBleName();
#endif
  } else if (job == "light") {
#if defined(BOARD_HAS_LIGHT)
    if (ulanziBleLinked()) doc["paired"] = ulanziBleName();
    doc["savedLights"] = ulanziBleSavedCount();
    ulanziBleFillSaved(doc);
#endif
  }
  String out;
  serializeJson(doc, out);
  socket.sendTXT(num, out);
}

static void reply(uint8_t num, bool ack, const char* reason) {
  JsonDocument doc;
  doc["ack"] = ack;
  doc["reason"] = reason;
  replyDoc(num, doc);
}

static const char* kProvService = "7b1e9c10-5a20-4c31-8d10-726f6e696e31";
static const char* kProvChar = "7b1e9c11-5a20-4c31-8d10-726f6e696e31";
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
  doc["apMac"] = WiFi.softAPmacAddress();
  doc["slot"] = slotId(slot);
  doc["job"] = slotIsLight(slot) ? "light" : "ronin";
  doc["host"] = slotDefaultIp(slot);
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
  NimBLEDevice::init(slotBleName(slot));
  NimBLEServer* server = NimBLEDevice::createServer();
  NimBLEService* service = server->createService(kProvService);
  provChar = service->createCharacteristic(
      kProvChar, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY, 240);
  provChar->setCallbacks(new ProvCallbacks());
  service->start();
  showIdentity();
  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(kProvService);
  advertising->setName(slotBleName(slot));
  advertising->start();
  Serial.print("블루투스 이름 ");
  Serial.print(slotBleName(slot));
  Serial.println(". 처음 설정은 이 이름으로 받습니다.");
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
  if (channel >= 1 && channel <= 13) WiFi.softAP("Ronin-C3", nullptr, channel);
  else WiFi.softAP("Ronin-C3");
}

/// 랜(STA)에 붙었으면 핫스팟을 끕니다. AP+STA 동시는 C3에서 ping은 되는데 HTTP/WS가 끊기는 원인이었습니다.
static void stopHotspotKeepStation() {
  // BLE와 같이 쓸 때는 modem sleep 을 끄면 abort 됩니다. 핫스팟만 끕니다.
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_STA);
}

/// 핫스팟을 먼저 켜면 라디오가 1번 채널에 고정됩니다. 집 2.4GHz는 다른 채널이라 붙지 못합니다.
static bool beginStation(const String& ssid, const String& pass, const String& ipText) {
  staWanted = true;
  joinSsid = ssid;
  joinPass = pass;
  IPAddress parsed;
  String useIp = ipText;
  if (!fixedLan(useIp, &parsed)) {
    useIp = slotDefaultIp(slot);
    Serial.print("고정 주소가 없어 ");
    Serial.print(useIp);
    Serial.println(" 을 씁니다.");
  }
  joinIp = useIp;
  if (ssid.isEmpty()) {
    startHotspot(0);
    nextStaTry = millis() + 15000;
    return false;
  }
  WiFi.persistent(false);
  WiFi.setAutoReconnect(true);
  WiFi.softAPdisconnect(true);
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
  prefs.putString("wifiIp", useIp);
  if (ok) {
    // 랜 성공 뒤에는 핫스팟을 끄고 STA만 유지합니다(HTTP/WS 안정).
    stopHotspotKeepStation();
    if (fixedLan(useIp, &wanted)) pinAddress(wanted);
    Serial.print("같은 와이파이 주소 ");
    Serial.println(WiFi.localIP());
    Serial.println("핫스팟 끔(랜 전용).");
  } else if (WiFi.status() == WL_CONNECT_FAILED) {
    startHotspot(bestChannel);
    Serial.println("2.4GHz에 비밀번호가 맞지 않습니다. 처음 연결에서 다시 넣으세요.");
  } else {
    startHotspot(bestChannel);
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
  prefs.putString("wifiSsid", joinSsid);
  prefs.putString("wifiPass", joinPass);
  prefs.putString("wifiIp", joinIp);
  prefs.putString("mode", "lan");
  if (!beginStation(joinSsid, joinPass, joinIp)) {
    tellProvision("{\"ok\":false,\"reason\":\"그 와이파이에 붙지 못했습니다. 핫스팟 Ronin-C3 는 그대로입니다.\"}");
    return;
  }
  const String ip = WiFi.localIP().toString();
  String note = "{\"ok\":true,\"ip\":\"" + ip + "\",\"port\":82,\"wifiMac\":\"" + WiFi.macAddress() +
                "\",\"apMac\":\"" + WiFi.softAPmacAddress() + "\",\"slot\":\"" + slotId(slot) +
                "\",\"job\":\"" + (slotIsLight(slot) ? "light" : "ronin") + "\"}";
  tellProvision(note.c_str());
  Serial.print("같은 와이파이 주소 ");
  Serial.println(ip);
}

static void banner() {
  Serial.println();
  Serial.println("단일 담당 기판");
  Serial.print("슬롯: ");
  Serial.println(slotTitle(slot));
  Serial.print("펌웨어: ");
  Serial.println(FW_VERSION);
  Serial.print("맡은 일: ");
  Serial.println(job == "light" ? "울란지 조명" : "로닌 제어(블루투스)");
  Serial.println("핫스팟 Ronin-C3 192.168.4.1 웹소켓 82 · OTA http://ip/update");
  Serial.print("같은 와이파이 기본 ");
  Serial.print(slotDefaultIp(slot));
  Serial.println(":82. CAN 아님. 조명은 탈리와 별개.");
#if defined(BOARD_HAS_RONIN)
  if (job == "ronin" && roninBleName()[0]) {
    Serial.print("저장된 로닌 이름: ");
    Serial.println(roninBleName());
  }
#endif
#if defined(BOARD_HAS_LIGHT)
  if (job == "light" && ulanziBleName()[0]) {
    Serial.print("저장된 울란지 이름: ");
    Serial.println(ulanziBleName());
  }
#endif
  refreshOled();
}

static void applyMode(const char* mode) {
  if (mode != nullptr && strcmp(mode, "ap") == 0) {
    staWanted = false;
    prefs.putString("mode", "ap");
    WiFi.mode(WIFI_AP);
    WiFi.softAPConfig(IPAddress(192, 168, 4, 1), IPAddress(192, 168, 4, 1), IPAddress(255, 255, 255, 0));
    WiFi.softAP("Ronin-C3");
    Serial.println("핫스팟 Ronin-C3 로 바꿨습니다.");
    return;
  }
  prefs.putString("mode", "lan");
  if (prefs.isKey("wifiSsid")) {
    String savedIp = prefs.getString("wifiIp", "");
    if (savedIp.isEmpty() || savedIp == "192.168.10.205") {
      savedIp = slotDefaultIp(slot);
    }
    // 슬롯 기본 IP가 바뀌었거나 다른 보드 IP를 물려받은 경우 교정
    if (slot == BoardSlot::RmsidSc && (savedIp == "192.168.10.152" || savedIp == "192.168.10.153")) {
      savedIp = slotDefaultIp(slot);
    }
    if (slot == BoardSlot::OledRs2 && (savedIp == "192.168.10.153" || savedIp == "192.168.10.154")) {
      savedIp = slotDefaultIp(slot);
    }
    if (slot == BoardSlot::S3Light && (savedIp == "192.168.10.152" || savedIp == "192.168.10.154")) {
      savedIp = slotDefaultIp(slot);
    }
    beginStation(prefs.getString("wifiSsid", ""), prefs.getString("wifiPass", ""), savedIp);
    return;
  }
#if C3_HAS_WIFI
  Serial.println("저장된 설정이 없어 비밀 파일의 와이파이로 붙습니다. 비밀번호는 찍지 않습니다.");
  beginStation(WIFI_SSID_1, WIFI_PASS, slotDefaultIp(slot));
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
    // hello 에 ack 를 넣지 않습니다. ack:false 가 앱의 대기 중인 명령을 가로채 무반응처럼 보였습니다.
    JsonDocument hello;
    hello["hello"] = true;
    hello["reason"] = "연결만 되었습니다. 아직 명령을 수행하지 않았습니다.";
    replyDoc(num, hello);
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
  if (strcmp(op, "ping") == 0) {
    // ack 없이 pong 만. 대기 중인 명령을 가로채지 않습니다.
    JsonDocument pong;
    pong["pong"] = true;
    replyDoc(num, pong);
    return;
  }
  if (strcmp(op, "slot") == 0) {
    BoardSlot next = slotFromText(doc["slot"] | slotId(slot), slot);
    applySlot(next);
    reply(num, true, slotTitle(slot));
    banner();
    return;
  }
  if (strcmp(op, "job") == 0) {
    // 슬롯이 고정 담당입니다. job 요청은 슬롯과 맞을 때만 받습니다.
    const char* next = doc["job"] | "ronin";
    bool wantLight = strcmp(next, "light") == 0;
    if (wantLight != slotIsLight(slot)) {
      reply(num, false, "이 보드 슬롯 담당과 다른 일입니다. 바꾸지 않았습니다.");
      return;
    }
    applySlot(slot);
    reply(num, true, job == "light" ? "조명만 맡도록 저장했습니다." : "로닌 제어만 맡도록 저장했습니다.");
    banner();
    return;
  }
  if (strcmp(op, "mode") == 0) {
    applyMode(doc["mode"] | "lan");
    reply(num, true, "연결 방식을 저장했습니다. 웹소켓은 잠깐 끊길 수 있습니다.");
    return;
  }
#if defined(BOARD_HAS_RONIN)
  if (strcmp(op, "scan") == 0) {
    if (job != "ronin") {
      reply(num, false, "이 C3 는 로닌 제어가 아닙니다. 스캔하지 않았습니다.");
      return;
    }
    RoninFound rows[8];
    size_t count = roninBleScan(rows, 8);
    JsonDocument doc;
    doc["ack"] = true;
    char reason[96];
    snprintf(reason, sizeof(reason), "로닌 후보 %u 대를 블루투스에서 찾았습니다.", (unsigned)count);
    doc["reason"] = reason;
    roninBleFillList(doc);
    replyDoc(num, doc);
    return;
  }
  if (strcmp(op, "pair") == 0) {
    if (job != "ronin") {
      reply(num, false, "이 C3 는 로닌 제어가 아닙니다. 붙이지 않았습니다.");
      return;
    }
    const char* name = doc["name"] | "";
    const char* id = doc["id"] | "";
    char reason[180];
    bool ok = roninBlePair(name, id, reason, sizeof(reason));
    JsonDocument out;
    out["ack"] = ok;
    out["reason"] = reason;
    if (ok) out["paired"] = roninBleName();
    replyDoc(num, out);
    return;
  }
  if (strcmp(op, "ronin") == 0) {
    if (job != "ronin") {
      reply(num, false, "이 C3 는 로닌 제어가 아닙니다. 명령을 수행하지 않았습니다.");
      return;
    }
    const char* action = doc["action"] | "";
    if (strcmp(action, "scan") == 0) {
      RoninFound rows[8];
      size_t count = roninBleScan(rows, 8);
      JsonDocument out;
      out["ack"] = true;
      char reason[96];
      snprintf(reason, sizeof(reason), "로닌 후보 %u 대를 블루투스에서 찾았습니다.", (unsigned)count);
      out["reason"] = reason;
      roninBleFillList(out);
      replyDoc(num, out);
      return;
    }
    if (strcmp(action, "pair") == 0) {
      const char* name = doc["name"] | "";
      const char* id = doc["id"] | "";
      char reason[180];
      bool ok = roninBlePair(name, id, reason, sizeof(reason));
      JsonDocument out;
      out["ack"] = ok;
      out["reason"] = reason;
      if (ok) out["paired"] = roninBleName();
      replyDoc(num, out);
      return;
    }
    if (strcmp(action, "drop") == 0) {
      roninBleDrop();
      reply(num, true, "로닌 블루투스를 끊었습니다.");
      return;
    }
    if (strcmp(action, "zoom") == 0 || strcmp(action, "zoomIn") == 0 ||
        strcmp(action, "zoomOut") == 0 || strcmp(action, "zoomStop") == 0) {
      int speed = doc["speed"] | 0;
      if (strcmp(action, "zoomIn") == 0 && speed == 0) speed = 800;
      if (strcmp(action, "zoomOut") == 0 && speed == 0) speed = -800;
      if (strcmp(action, "zoomStop") == 0) speed = 0;
#if defined(BOARD_SLOT_RMSID)
      reply(num, false, "SC 줌은 아직 없습니다. UI·프로토콜 자리만 두었고, 지금은 RS2 줌만 씁니다.");
      return;
#else
      // 최신 속도만 남기고 40ms 간격 송신. 가짜 dial ack 없음.
      roninBleOfferZoom((int16_t)speed);
      roninBleLoop();
      refreshOled(false);
      char reason[160];
      snprintf(reason, sizeof(reason),
               "줌 최신값 %d 을 덮어썼습니다. 렌즈/다이얼이 도는지 봐 주세요.", speed);
      reply(num, true, reason);
      return;
#endif
    }
    if (strcmp(action, "probe") == 0 || strcmp(action, "probeByte") == 0) {
      // Yaw/Zoom·축 바이트 분리 시험. 눈확인 전 「된다」 금지.
      int axis = doc["axis"] | -1;
      float deg = doc["deg"] | (doc["value"] | 0.0f);
      int rawByte = doc["byte"] | (doc["rawByte"] | -1);
      int rawValue = doc["raw"] | (doc["rawValue"] | 0);
      char reason[220];
      bool ok = roninBleProbePayload(axis, deg, rawByte, rawValue, reason, sizeof(reason));
      refreshOled(true);
      reply(num, ok, reason);
      return;
    }
    bool home = doc["home"] | false;
    // 팬: pan 우선, 없으면 예전 호환 yaw. 요: roll(롤 모터). 팬≠요.
    float pan = doc["pan"] | (doc["yaw"] | 0.0f);
    float pitch = doc["pitch"] | 0.0f;
    float roll = doc["roll"] | 0.0f;
    if (strcmp(action, "home") == 0) home = true;
    // action:yaw → 요(롤)만. 팬·틸트 필드는 무시.
    if (strcmp(action, "yaw") == 0) {
      roll = doc["roll"] | (doc["yaw"] | 0.0f);
      pan = 0;
      pitch = 0;
      home = false;
    }
    // 제자리만 동기(notify 확인). 연속 팬·틸트·요는 최신값 덮어쓰기+40ms 송신.
    if (home) {
      char reason[200];
      bool ok = roninBleMove(pan, pitch, true, reason, sizeof(reason), roll);
      refreshOled(true);
      reply(num, ok, reason);
      return;
    }
    roninBleOfferMove(pan, pitch, roll, false);
    roninBleLoop();  // 간격 되면 즉시 1회 송신
    refreshOled(false);
    {
      char reason[180];
      if (strcmp(action, "yaw") == 0) {
        snprintf(reason, sizeof(reason),
                 "요(롤) 최신값 %d° 를 덮어썼습니다. 같은 쪽으로 기울는지 봐 주세요.", (int)lroundf(roll));
      } else {
        snprintf(reason, sizeof(reason),
                 "팬 %d° 틸트 %d° 요 %d° 최신값을 덮어썼습니다. 따라오는지 봐 주세요.",
                 (int)lroundf(pan), (int)lroundf(pitch), (int)lroundf(roll));
      }
      reply(num, true, reason);
    }
    return;
  }
#else
  if (strcmp(op, "scan") == 0 || strcmp(op, "pair") == 0 || strcmp(op, "ronin") == 0) {
    reply(num, false, "이 빌드는 로닌 제어가 아닙니다.");
    return;
  }
#endif
#if defined(BOARD_HAS_LIGHT)
  if (strcmp(op, "light") == 0) {
    if (job != "light") {
      reply(num, false, "이 C3 는 조명이 아닙니다. 명령을 수행하지 않았습니다.");
      return;
    }
    const char* action = doc["action"] | "";
    if (strcmp(action, "scan") == 0) {
      UlanziFound rows[8];
      size_t count = ulanziBleScan(rows, 8);
      JsonDocument out;
      out["ack"] = true;
      char reason[96];
      snprintf(reason, sizeof(reason), "울란지 후보 %u 대를 블루투스에서 찾았습니다.", (unsigned)count);
      out["reason"] = reason;
      ulanziBleFillList(out);
      replyDoc(num, out);
      return;
    }
    if (strcmp(action, "pair") == 0) {
      const char* name = doc["name"] | "";
      const char* id = doc["id"] | "";
      char reason[180];
      bool ok = ulanziBlePair(name, id, reason, sizeof(reason));
      JsonDocument out;
      out["ack"] = ok;
      out["reason"] = reason;
      if (ok) out["paired"] = ulanziBleName();
      replyDoc(num, out);
      return;
    }
    if (strcmp(action, "drop") == 0) {
      ulanziBleDrop();
      reply(num, true, "울란지 블루투스를 끊었습니다.");
      return;
    }
    if (strcmp(action, "auto") == 0) {
      char reason[180];
      bool ok = ulanziBleAutoPair(reason, sizeof(reason));
      reply(num, ok, reason);
      return;
    }
    int brightness = doc["brightness"] | 40;
    int kelvin = doc["kelvin"] | 4500;
    bool on = doc["on"] | true;
    char reason[200];
    bool ok = false;
    // 개별이 기본입니다. index / id / name 중 하나로 한 대만 보냅니다.
    // action=all 일 때만 묶음입니다.
    if (strcmp(action, "all") == 0) {
      ok = ulanziBleApplyAll(brightness, kelvin, on, reason, sizeof(reason));
    } else if (doc["index"].is<int>()) {
      int idx = doc["index"] | -1;
      ok = (idx >= 0 && idx < 2)
               ? ulanziBleApplyIndex((uint8_t)idx, brightness, kelvin, on, reason, sizeof(reason))
               : false;
      if (!ok && reason[0] == 0) snprintf(reason, sizeof(reason), "울란지 칸 번호가 잘못되었습니다.");
    } else {
      const char* name = doc["name"] | "";
      const char* id = doc["id"] | "";
      if (id[0] || name[0]) {
        char pairReason[160];
        if (!ulanziBlePair(name, id, pairReason, sizeof(pairReason))) {
          snprintf(reason, sizeof(reason), "%s", pairReason);
          ok = false;
        } else {
          ok = ulanziBleApply(brightness, kelvin, on, reason, sizeof(reason));
        }
      } else if (ulanziBleSavedCount() == 1) {
        ok = ulanziBleApplyIndex(0, brightness, kelvin, on, reason, sizeof(reason));
      } else {
        snprintf(reason, sizeof(reason),
                 "울란지 칸(index) 또는 이름을 지정하세요. 2대는 묶음이 아니라 개별로 조절합니다.");
        ok = false;
      }
    }
    JsonDocument out;
    out["ack"] = ok;
    out["reason"] = reason;
    ulanziBleFillSaved(out);
    replyDoc(num, out);
    return;
  }
#else
  if (strcmp(op, "light") == 0) {
    reply(num, false, "이 빌드는 조명이 아닙니다.");
    return;
  }
#endif
  reply(num, false, "이 기판이 받지 않는 명령입니다.");
}

void setup() {
  Serial.begin(115200);
  delay(400);
  prefs.begin("ronin-c3", false);
  // 빌드 env 슬롯이 담당을 고정합니다. 예전 prefs(slot) 때문에 OLED/SC/조명이 섞이지 않게 합니다.
#if defined(BOARD_SLOT_OLED) || defined(BOARD_SLOT_RMSID) || defined(BOARD_SLOT_S3)
  slot = kDefaultSlot;
  prefs.putString("slot", slotId(slot));
#else
  slot = slotFromText(prefs.getString("slot", slotId(kDefaultSlot)).c_str(), kDefaultSlot);
#endif
  startProvision();
  applySlot(slot);
  banner();
  String mode = prefs.isKey("mode") ? prefs.getString("mode", "lan") : "lan";
  applyMode(mode.c_str());
  // OLED I2C 는 와이파이 뒤에 켠다. 버스가 멈춰도 망·웹소켓은 이미 열린 뒤다.
  boardOledBegin(slot == BoardSlot::OledRs2);
  showIdentity();
  Serial.print("와이파이 MAC ");
  Serial.println(WiFi.macAddress());
  socket.begin();
  socket.onEvent(onEvent);
  // 앱 keepalive 와 맞춥니다. 스캔 라운드(2초)보다 여유 있게.
  socket.enableHeartbeat(20000, 8000, 3);
  Serial.println("웹소켓 82번을 열었습니다.");
  nextAutoPairAt = millis() + 12000;
  refreshOled();
}

void loop() {
  if (joinAsked) finishJoin();
  else keepStation();
  boardOtaLoop();
#if defined(BOARD_HAS_LIGHT)
  if (job == "light") {
    ulanziBleLoop();
    if (WiFi.status() == WL_CONNECTED && !ulanziBleBusy() && ulanziBleSavedCount() < 2 && millis() >= nextAutoPairAt) {
      nextAutoPairAt = millis() + 25000;
      char reason[180];
      if (ulanziBleAutoPair(reason, sizeof(reason))) Serial.println(reason);
      else Serial.println(reason);
    }
  }
#endif
#if defined(BOARD_HAS_RONIN)
  if (job != "light") {
    // 로닌 자동 재페어는 roninBleLoop 한곳만. 여기서 또 스캔하면 WS 가 깜빡입니다.
    roninBleLoop();
  }
#endif
  refreshOled(false);
  boardNetPump();
  (void)clientUp;
}
