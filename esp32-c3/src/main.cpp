#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <ESPmDNS.h>
#include <esp_coexist.h>
#include <esp_wifi.h>
#include <NimBLEDevice.h>

#if __has_include("wifi_local.h")
#include "wifi_local.h"
#else
#error "include/wifi_local.h 가 없습니다. wifi_local.example.h 를 복사해 와이파이 이름과 비밀번호를 적으세요. 그 파일은 깃허브에 올리지 않습니다."
#endif

/*
 * 고프로 액션5와 다른 고프로를 블루투스(BLE)로 켜고 끄는 다리입니다.
 * 블루투스는 아두이노 기본 스택이 아니라 NimBLE-Arduino 입니다.
 * 이 기판의 라디오는 하나라서, 와이파이 절전을 끄고 와이파이와 블루투스가 나눠 씁니다.
 * 카메라는 최대 4대까지 등록해 둡니다. 8대를 한 박자에 맞추지는 않습니다.
 *
 * 집 공유기가 있으면 아래 순서만 사용합니다. 다른 집 망에는 붙지 않습니다.
 * 1. WIFI_SSID_1
 * 2. 실패하면 WIFI_SSID_2
 * 집 공유기가 없어도 기판이 자기 이름 Ronin-C3 로 직접 연결을 엽니다.
 * 그 주소는 192.168.4.1 입니다. 직접 연결 비밀번호는 없습니다.
 * 비밀번호는 시리얼로 찍지 않습니다.
 *
 * 아이패드 호출 예:
 *   GET /shutter?mac=AA:BB:CC:DD:EE:FF&action=start
 *   GET /shutter?mac=AA:BB:CC:DD:EE:FF&action=stop
 *
 * 고프로 공식 프로파일(Open GoPro):
 *   제어 서비스는 FEA6 입니다. 명령 특성은 b5f90072 입니다.
 *   b5f90001 은 카메라 와이파이 이름/비밀번호 서비스라서 촬영 버튼을 받지 않습니다.
 *   FFE0/FFE1 은 값싼 시리얼 모듈용이라 액션5에는 쓰지 않습니다.
 *
 * 촬영 명령은 길이 1바이트짜리 옛 묶음이 아닙니다.
 * 공식 묶음은 앞에 2바이트 머리(0x2000 + 길이)를 붙입니다.
 *   시작 몸통 01 01 01  -> 전선 위에는 20 03 01 01 01
 *   정지 몸통 01 01 00  -> 전선 위에는 20 03 01 01 00
 * 명령을 보낸 뒤 그 카메라 연결을 끊지 않습니다. 시작 다음에 정지를 같은 연결로 보냅니다.
 */

static const char* kControlService = "0000fea6-0000-1000-8000-00805f9b34fb";
static const char* kCommandChar = "b5f90072-aa8d-11e3-9046-0002a5d5c51b";
static const char* kCommandRspChar = "b5f90073-aa8d-11e3-9046-0002a5d5c51b";
static const char* kSettingChar = "b5f90074-aa8d-11e3-9046-0002a5d5c51b";
static const char* kSettingRspChar = "b5f90075-aa8d-11e3-9046-0002a5d5c51b";
static const char* kQueryChar = "b5f90076-aa8d-11e3-9046-0002a5d5c51b";
static const char* kQueryRspChar = "b5f90077-aa8d-11e3-9046-0002a5d5c51b";

static const char* kDirectSsid = "Ronin-C3";
static const int kMaxCameras = 4;
static const uint32_t kWifiWaitMs = 12000;
static const uint32_t kWifiRetryGapMs = 10000;
static const uint32_t kKeepAliveMs = 3000;
static const uint32_t kKeepAliveGapMs = 250;
static const uint32_t kCommandWaitMs = 4000;

struct CamSlot {
  bool registered = false;
  bool ready = false;
  String mac;
  NimBLEClient* client = nullptr;
  NimBLERemoteCharacteristic* commandChar = nullptr;
  NimBLERemoteCharacteristic* commandRspChar = nullptr;
  NimBLERemoteCharacteristic* settingChar = nullptr;
  NimBLERemoteCharacteristic* settingRspChar = nullptr;
  NimBLERemoteCharacteristic* queryChar = nullptr;
  NimBLERemoteCharacteristic* queryRspChar = nullptr;
  uint32_t lastKeepAliveMs = 0;
};

WebServer server(80);
CamSlot cams[kMaxCameras];
bool bleStackReady = false;
bool bleBusy = false;
bool serverStarted = false;
bool mdnsUp = false;
bool radioShared = false;
String activeSsid;
uint32_t nextWifiTryMs = 0;
int keepAliveCursor = 0;
uint32_t nextKeepAliveAt = 0;

volatile bool gotNotify = false;
volatile size_t notifyLen = 0;
uint8_t notifyBuf[64];
int waitingSlot = -1;

class BridgeClientCallbacks : public NimBLEClientCallbacks {
  void onDisconnect(NimBLEClient* client, int reason) override;
  void onConfirmPasskey(NimBLEConnInfo& info, uint32_t pin) override;
  void onAuthenticationComplete(NimBLEConnInfo&) override;
};

BridgeClientCallbacks bleCallbacks;

String hexBytes(const uint8_t* data, size_t len) {
  String out;
  for (size_t i = 0; i < len; i++) {
    if (i) out += " ";
    char tmp[4];
    snprintf(tmp, sizeof(tmp), "%02X", data[i]);
    out += tmp;
  }
  return out;
}

void onNotify(NimBLERemoteCharacteristic* chr, uint8_t* data, size_t length, bool) {
  if (waitingSlot < 0 || waitingSlot >= kMaxCameras) return;
  if (!chr) return;
  const CamSlot& slot = cams[waitingSlot];
  if (chr != slot.commandRspChar && chr != slot.queryRspChar && chr != slot.settingRspChar) return;
  size_t n = length;
  if (n > sizeof(notifyBuf)) n = sizeof(notifyBuf);
  memcpy(notifyBuf, data, n);
  notifyLen = n;
  gotNotify = true;
}

void BridgeClientCallbacks::onDisconnect(NimBLEClient* client, int reason) {
  for (int i = 0; i < kMaxCameras; i++) {
    if (cams[i].client != client) continue;
    cams[i].ready = false;
    cams[i].commandChar = nullptr;
    cams[i].commandRspChar = nullptr;
    cams[i].settingChar = nullptr;
    cams[i].settingRspChar = nullptr;
    cams[i].queryChar = nullptr;
    cams[i].queryRspChar = nullptr;
    Serial.printf("블루투스 끊김 %s 코드 %d. 등록은 유지합니다.\n", cams[i].mac.c_str(), reason);
  }
}

void BridgeClientCallbacks::onConfirmPasskey(NimBLEConnInfo& info, uint32_t pin) {
  Serial.printf("카메라에 숫자 %06lu 이 보이면 연결을 허용합니다.\n", static_cast<unsigned long>(pin));
  NimBLEDevice::injectConfirmPasskey(info, true);
}

void BridgeClientCallbacks::onAuthenticationComplete(NimBLEConnInfo&) {
  Serial.println("블루투스 짝 맞추기 절차가 끝났습니다.");
}

void shareRadio() {
  WiFi.setSleep(false);
  const esp_err_t ps = esp_wifi_set_ps(WIFI_PS_NONE);
  const esp_err_t coex = esp_coex_preference_set(ESP_COEX_PREFER_BALANCE);
  if (!radioShared || ps != ESP_OK || coex != ESP_OK) {
    Serial.printf("라디오 공유: 와이파이 절전 끄기=%d, 균형=%d\n", (int)ps, (int)coex);
    radioShared = (ps == ESP_OK && coex == ESP_OK);
  }
}

void ensureBleStack() {
  if (bleStackReady) return;
  NimBLEDevice::init("Action5Bridge");
  NimBLEDevice::setSecurityAuth(true, false, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  NimBLEDevice::setSecurityInitKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
  NimBLEDevice::setSecurityRespKey(BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID);
  NimBLEDevice::setMTU(128);
  bleStackReady = true;
  Serial.printf("NimBLE 준비됨. 카메라 등록은 최대 %d대입니다.\n", kMaxCameras);
}

String normalizeMac(const String& raw) {
  String hex;
  for (unsigned i = 0; i < raw.length(); i++) {
    char c = raw[i];
    if (isxdigit(static_cast<unsigned char>(c))) hex += (char)tolower(c);
  }
  if (hex.length() != 12) return "";
  String out;
  for (int i = 0; i < 12; i += 2) {
    if (i) out += ":";
    out += hex.substring(i, i + 2);
  }
  return out;
}

int findMac(const String& mac) {
  for (int i = 0; i < kMaxCameras; i++) {
    if (cams[i].registered && cams[i].mac == mac) return i;
  }
  return -1;
}

int findFree() {
  for (int i = 0; i < kMaxCameras; i++) {
    if (!cams[i].registered) return i;
  }
  return -1;
}

int registeredCount() {
  int n = 0;
  for (int i = 0; i < kMaxCameras; i++) {
    if (cams[i].registered) n++;
  }
  return n;
}

void ensureDirect() {
  if (WiFi.getMode() != WIFI_AP_STA) WiFi.mode(WIFI_AP_STA);
  const IPAddress now = WiFi.softAPIP();
  if (now != IPAddress(0, 0, 0, 0)) return;
  WiFi.softAPConfig(IPAddress(192, 168, 4, 1), IPAddress(192, 168, 4, 1), IPAddress(255, 255, 255, 0));
  const bool up = WiFi.softAP(kDirectSsid);
  shareRadio();
  Serial.printf("직접 연결 %s %s\n", kDirectSsid, up ? WiFi.softAPIP().toString().c_str() : "열지 못했습니다");
}

String directIpText() {
  const IPAddress ip = WiFi.softAPIP();
  if (ip == IPAddress(0, 0, 0, 0)) return "192.168.4.1";
  return ip.toString();
}

bool joinOne(const char* ssid) {
  Serial.printf("Wi-Fi 연결 시도: %s\n", ssid);
  ensureDirect();
  shareRadio();
  WiFi.begin(ssid, WIFI_PASS);
  const uint32_t started = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - started < kWifiWaitMs) {
    delay(200);
    server.handleClient();
  }
  if (WiFi.status() == WL_CONNECTED) {
    shareRadio();
    activeSsid = ssid;
    Serial.printf("연결됨 SSID: %s\n", ssid);
    Serial.printf("IP: %s\n", WiFi.localIP().toString().c_str());
    return true;
  }
  Serial.printf("연결 실패: %s\n", ssid);
  WiFi.disconnect(false, false);
  delay(200);
  return false;
}

bool connectWifi() {
  if (WiFi.status() == WL_CONNECTED) return true;
  activeSsid = "";
  if (joinOne(WIFI_SSID_1)) return true;
  if (joinOne(WIFI_SSID_2)) return true;
  ensureDirect();
  Serial.println("집 와이파이에 붙지 않았습니다. 직접 연결은 그대로 열려 있습니다.");
  return false;
}

bool writeFramed(CamSlot& cam, NimBLERemoteCharacteristic* writeTo, const uint8_t* body, size_t bodyLen,
                 uint32_t waitMs, String& responseHex, bool waitForNotify) {
  if (!writeTo || !body || bodyLen == 0 || bodyLen > 18) return false;
  uint8_t packet[20];
  const uint16_t header = (uint16_t)(0x2000u | (uint16_t)bodyLen);
  packet[0] = (uint8_t)(header >> 8);
  packet[1] = (uint8_t)(header & 0xFF);
  memcpy(packet + 2, body, bodyLen);

  gotNotify = false;
  notifyLen = 0;
  waitingSlot = waitForNotify ? (int)(&cam - cams) : -1;

  const bool wrote = writeTo->writeValue(packet, bodyLen + 2, true);
  if (!waitForNotify) {
    waitingSlot = -1;
    responseHex = "";
    return wrote;
  }
  const uint32_t started = millis();
  while (!gotNotify && millis() - started < waitMs) delay(10);
  responseHex = gotNotify ? hexBytes(notifyBuf, notifyLen) : "";
  waitingSlot = -1;
  return wrote && gotNotify;
}

bool tlvStatus(const uint8_t* data, size_t len, uint8_t expectCmd, int& status) {
  const uint8_t* p = data;
  size_t n = len;
  if (n >= 2 && (p[0] & 0x80) == 0 && ((p[0] >> 5) & 0x03) == 0x01) {
    p += 2;
    n -= 2;
  } else if (n >= 2 && p[0] == (uint8_t)(n - 1)) {
    p += 1;
    n -= 1;
  }
  if (n < 2 || p[0] != expectCmd) return false;
  status = p[1];
  return true;
}

bool connectSlot(CamSlot& cam) {
  if (!cam.client) {
    cam.client = NimBLEDevice::createClient();
    if (!cam.client) return false;
    cam.client->setClientCallbacks(&bleCallbacks, false);
    cam.client->setConnectTimeout(8000);
    cam.client->setConnectionParams(24, 80, 0, 400);
  }
  if (cam.client->isConnected() && cam.ready) return true;
  if (cam.client->isConnected()) cam.client->disconnect();

  const NimBLEAddress randomAddr(cam.mac.c_str(), BLE_ADDR_RANDOM);
  Serial.printf("블루투스 연결 시도: %s (random)\n", cam.mac.c_str());
  if (cam.client->connect(randomAddr)) {
    Serial.println("블루투스 연결됨. 카메라에 허용 창이 뜨면 눌러 주세요.");
    cam.client->secureConnection();
    return true;
  }
  const NimBLEAddress publicAddr(cam.mac.c_str(), BLE_ADDR_PUBLIC);
  Serial.printf("블루투스 연결 시도: %s (public)\n", cam.mac.c_str());
  if (!cam.client->connect(publicAddr)) {
    Serial.println("블루투스 연결 실패");
    return false;
  }
  Serial.println("블루투스 연결됨. 카메라에 허용 창이 뜨면 눌러 주세요.");
  cam.client->secureConnection();
  return true;
}

bool prepareSession(const String& mac, int& slot, String& detail) {
  ensureBleStack();
  int idx = findMac(mac);
  bool fresh = false;
  if (idx < 0) {
    idx = findFree();
    if (idx < 0) {
      detail = "카메라 4대가 이미 등록되어 있습니다";
      return false;
    }
    cams[idx].registered = true;
    cams[idx].mac = mac;
    cams[idx].ready = false;
    fresh = true;
  }
  slot = idx;
  CamSlot& cam = cams[idx];
  if (cam.ready && cam.client && cam.client->isConnected() && cam.commandChar && cam.commandRspChar) {
    detail = "이미 등록된 카메라를 그대로 사용합니다";
    return true;
  }

  if (!connectSlot(cam)) {
    if (fresh) {
      cam.registered = false;
      cam.mac = "";
    }
    detail = "카메라 블루투스에 연결하지 못했습니다";
    return false;
  }

  NimBLERemoteService* service = cam.client->getService(kControlService);
  if (!service) {
    cam.client->getServices(true);
    service = cam.client->getService(kControlService);
  }
  if (!service) {
    detail = "Open GoPro 제어 서비스 FEA6 를 찾지 못했습니다";
    return false;
  }

  cam.commandChar = service->getCharacteristic(kCommandChar);
  cam.commandRspChar = service->getCharacteristic(kCommandRspChar);
  cam.settingChar = service->getCharacteristic(kSettingChar);
  cam.settingRspChar = service->getCharacteristic(kSettingRspChar);
  cam.queryChar = service->getCharacteristic(kQueryChar);
  cam.queryRspChar = service->getCharacteristic(kQueryRspChar);
  NimBLERemoteCharacteristic* settingRsp = cam.settingRspChar;
  if (!cam.commandChar || !cam.commandRspChar) {
    detail = "명령 특성 b5f90072 를 찾지 못했습니다";
    return false;
  }
  if (!cam.commandRspChar->subscribe(true, onNotify, true)) {
    detail = "명령 응답 알림을 켜지 못했습니다";
    return false;
  }
  if (settingRsp) settingRsp->subscribe(true, onNotify, true);
  if (cam.queryRspChar) cam.queryRspChar->subscribe(true, onNotify, true);

  String responseHex;
  const uint8_t thirdParty[] = {0x50};
  writeFramed(cam, cam.commandChar, thirdParty, sizeof(thirdParty), 1500, responseHex, true);
  if (responseHex.length()) Serial.printf("제3자 등록 응답: %s\n", responseHex.c_str());

  const uint8_t externalControl[] = {0xF1, 0x69, 0x08, 0x02};
  const bool claimed = writeFramed(cam, cam.commandChar, externalControl, sizeof(externalControl), kCommandWaitMs, responseHex, true);
  Serial.printf("%s 외부 제어 요청 %s", cam.mac.c_str(), claimed ? "응답 있음" : "응답 없음");
  if (responseHex.length()) Serial.printf(": %s", responseHex.c_str());
  Serial.println();

  cam.ready = true;
  cam.lastKeepAliveMs = millis();
  detail = "카메라를 등록하고 연결을 유지합니다";
  Serial.printf("등록 %d/%d %s\n", registeredCount(), kMaxCameras, cam.mac.c_str());
  return true;
}

void serviceKeepAlive() {
  if (bleBusy || (int32_t)(millis() - nextKeepAliveAt) < 0) return;
  for (int n = 0; n < kMaxCameras; n++) {
    const int i = (keepAliveCursor + n) % kMaxCameras;
    CamSlot& cam = cams[i];
    if (!cam.ready || !cam.settingChar || !cam.client || !cam.client->isConnected()) continue;
    if (millis() - cam.lastKeepAliveMs < kKeepAliveMs) continue;
    const uint8_t body[] = {0x5B, 0x01, 0x42};
    String ignored;
    writeFramed(cam, cam.settingChar, body, sizeof(body), 0, ignored, false);
    cam.lastKeepAliveMs = millis();
    keepAliveCursor = (i + 1) % kMaxCameras;
    nextKeepAliveAt = millis() + kKeepAliveGapMs;
    return;
  }
}

void sendJson(int code, bool ok, const String& mac, const String& action, const String& detail, const String& responseHex) {
  String json = "{";
  json += "\"ok\":";
  json += ok ? "true" : "false";
  json += ",\"ssid\":\"" + activeSsid + "\"";
  json += ",\"ip\":\"" + WiFi.localIP().toString() + "\"";
  json += ",\"mac\":\"" + mac + "\"";
  json += ",\"action\":\"" + action + "\"";
  json += ",\"detail\":\"" + detail + "\"";
  if (responseHex.length()) json += ",\"response\":\"" + responseHex + "\"";
  json += ",\"registered\":" + String(registeredCount());
  json += ",\"max\":" + String(kMaxCameras);
  json += "}";
  server.send(code, "application/json", json);
}

String wifiMacText();

void handleRoot() {
  const bool house = WiFi.status() == WL_CONNECTED;
  String page;
  page += "액션5 브리지\n";
  page += "SSID: " + (house ? activeSsid : String("없음")) + "\n";
  page += "IP: " + (house ? WiFi.localIP().toString() : String("없음")) + "\n";
  page += "MAC: " + wifiMacText() + "\n";
  page += "DIRECT_SSID: " + String(kDirectSsid) + "\n";
  page += "DIRECT_IP: " + directIpText() + "\n";
  page += "블루투스: NimBLE\n";
  page += "등록 " + String(registeredCount()) + "/" + String(kMaxCameras) + "\n";
  page += "8대 동시 촬영은 되지 않습니다. 라디오 하나를 와이파이와 블루투스가 나눠 씁니다.\n";
  for (int i = 0; i < kMaxCameras; i++) {
    if (!cams[i].registered) continue;
    const bool up = cams[i].client && cams[i].client->isConnected() && cams[i].ready;
    page += cams[i].mac + (up ? " 연결됨\n" : " 등록됨, 연결 끊김\n");
  }
  page += "GET /shutter?mac=AA:BB:CC:DD:EE:FF&action=start\n";
  page += "GET /shutter?mac=AA:BB:CC:DD:EE:FF&action=stop\n";
  server.send(200, "text/plain; charset=utf-8", page);
}

void handleShutter() {
  if (!server.hasArg("mac") || !server.hasArg("action")) {
    sendJson(400, false, "", "", "mac 과 action 이 필요합니다", "");
    return;
  }
  const String mac = normalizeMac(server.arg("mac"));
  String action = server.arg("action");
  action.toLowerCase();
  if (!mac.length()) {
    sendJson(400, false, server.arg("mac"), action, "맥 주소 형식이 아닙니다", "");
    return;
  }
  if (action != "start" && action != "stop") {
    sendJson(400, false, mac, action, "action 은 start 또는 stop 만 됩니다", "");
    return;
  }
  if (bleBusy) {
    sendJson(503, false, mac, action, "이미 카메라와 이야기하는 중입니다", "");
    return;
  }

  bleBusy = true;
  Serial.printf("촬영 요청 mac=%s action=%s\n", mac.c_str(), action.c_str());
  String detail;
  int slot = -1;
  if (!prepareSession(mac, slot, detail)) {
    bleBusy = false;
    sendJson(502, false, mac, action, detail, "");
    return;
  }

  CamSlot& cam = cams[slot];
  const uint8_t startBody[] = {0x01, 0x01, 0x01};
  const uint8_t stopBody[] = {0x01, 0x01, 0x00};
  const uint8_t* body = action == "start" ? startBody : stopBody;
  String responseHex;
  const bool notified = writeFramed(cam, cam.commandChar, body, 3, kCommandWaitMs, responseHex, true);
  int status = -1;
  const bool accepted = notified && tlvStatus(notifyBuf, notifyLen, 0x01, status) && status == 0;
  bleBusy = false;
  cam.lastKeepAliveMs = millis();

  if (accepted) {
    detail = action == "start" ? "촬영 시작 명령을 카메라가 받았습니다" : "촬영 정지 명령을 카메라가 받았습니다";
    Serial.printf("카메라 응답: %s\n", responseHex.c_str());
    sendJson(200, true, mac, action, detail, responseHex);
    return;
  }
  if (!notified) detail = "명령을 보냈지만 카메라 응답이 없습니다. 등록과 연결은 유지합니다";
  else detail = "카메라가 명령을 거절했습니다. 상태 " + String(status);
  Serial.printf("촬영 실패: %s / %s\n", detail.c_str(), responseHex.c_str());
  sendJson(502, false, mac, action, detail, responseHex);
}

String wifiMacText() {
  uint8_t mac[6] = {0};
  if (esp_wifi_get_mac(WIFI_IF_STA, mac) != ESP_OK) return "";
  char buf[18];
  snprintf(buf, sizeof(buf), "%02X:%02X:%02X:%02X:%02X:%02X",
           mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
  return String(buf);
}

void stopBoardName() {
  if (!mdnsUp) return;
  MDNS.end();
  mdnsUp = false;
}

// 아이폰이 숫자 주소 없이 이 기판을 찾습니다. 이름은 맥 주소만 담고, 비밀번호는 넣지 않습니다.
void publishBoard() {
  if (mdnsUp || WiFi.status() != WL_CONNECTED) return;
  const String mac = wifiMacText();
  if (!mac.length()) {
    Serial.println("기판 맥 주소를 읽지 못했습니다.");
    return;
  }
  String compact = mac;
  compact.replace(":", "");
  compact.toLowerCase();
  const String host = "link-" + compact;
  if (!MDNS.begin(host.c_str())) {
    Serial.println("이름 알림을 열지 못했습니다.");
    return;
  }
  MDNS.addService("ronin-c3", "tcp", 80);
  MDNS.addServiceTxt("ronin-c3", "tcp", "mac", mac.c_str());
  mdnsUp = true;
  Serial.printf("이름 알림 _ronin-c3._tcp 맥 주소 %s\n", mac.c_str());
}

String jsonEscape(const String& raw) {
  String out;
  for (unsigned i = 0; i < raw.length(); i++) {
    const char c = raw[i];
    if (c == '"' || c == '\\') {
      out += '\\';
      out += c;
    } else if (c >= 32) {
      out += c;
    }
  }
  return out;
}

// 고프로 HERO와 오즈모 액션 5 프로(Open GoPro FEA6)를 같은 찾기 목록에 넣습니다.
bool looksLikeBridgeCamera(const NimBLEAdvertisedDevice* device) {
  if (!device) return false;
  if (device->isAdvertisingService(NimBLEUUID(kControlService))) return true;
  if (device->isAdvertisingService(NimBLEUUID("FEA6"))) return true;
  String name(device->getName().c_str());
  name.toLowerCase();
  if (name.indexOf("gopro") >= 0 || name.indexOf("hero") >= 0) return true;
  if (name.indexOf("action") >= 0) return true;
  if (name.indexOf("osmo") >= 0) return true;
  if (name.indexOf("oa5") >= 0 || name.indexOf("ac5") >= 0) return true;
  return false;
}

struct ScanHit {
  char mac[18];
  char name[32];
  int rssi;
};

ScanHit scanHits[4];
volatile int scanCount = 0;
bool scanWanted = false;
bool scanRunning = false;
uint32_t scanBegan = 0;
String lastScanJson;

void rememberGoPro(const NimBLEAdvertisedDevice* device) {
  if (!looksLikeBridgeCamera(device)) return;
  const String mac = normalizeMac(String(device->getAddress().toString().c_str()));
  if (mac.length() != 17) return;
  const int rssi = device->getRSSI();
  const int held = scanCount;
  for (int i = 0; i < held && i < 4; i++) {
    if (strcmp(scanHits[i].mac, mac.c_str()) == 0) return;
  }
  int slot = -1;
  if (held < 4) {
    slot = held;
    scanCount = held + 1;
  } else {
    int weak = 0;
    for (int i = 1; i < 4; i++) {
      if (scanHits[i].rssi < scanHits[weak].rssi) weak = i;
    }
    if (rssi <= scanHits[weak].rssi) return;
    slot = weak;
  }
  strncpy(scanHits[slot].mac, mac.c_str(), sizeof(scanHits[slot].mac) - 1);
  scanHits[slot].mac[sizeof(scanHits[slot].mac) - 1] = 0;
  String name(device->getName().c_str());
  name.toCharArray(scanHits[slot].name, sizeof(scanHits[slot].name));
  scanHits[slot].rssi = rssi;
}

class GoProScanCallbacks : public NimBLEScanCallbacks {
  void onResult(const NimBLEAdvertisedDevice* device) override { rememberGoPro(device); }
};

GoProScanCallbacks goProScanCallbacks;

// 광고만 들은 카메라는 붙지 않은 것입니다. 이미 블루투스로 붙어 있을 때만 붙음입니다.
bool cameraAttached(const char* mac) {
  for (int i = 0; i < kMaxCameras; i++) {
    if (!cams[i].registered) continue;
    if (!cams[i].mac.equalsIgnoreCase(mac)) continue;
    return cams[i].ready && cams[i].client && cams[i].client->isConnected();
  }
  return false;
}

void finishScanJson() {
  const int count = scanCount > 4 ? 4 : scanCount;
  for (int a = 0; a < count; a++) {
    for (int b = a + 1; b < count; b++) {
      if (scanHits[b].rssi > scanHits[a].rssi) {
        const ScanHit swap = scanHits[a];
        scanHits[a] = scanHits[b];
        scanHits[b] = swap;
      }
    }
  }
  String json = "{\"ok\":true,\"pending\":false,\"cameras\":[";
  for (int i = 0; i < count; i++) {
    if (i) json += ",";
    const bool up = cameraAttached(scanHits[i].mac);
    json += "{\"mac\":\"" + String(scanHits[i].mac) + "\",\"name\":\"" + jsonEscape(String(scanHits[i].name)) + "\",\"rssi\":" + String(scanHits[i].rssi) + ",\"attached\":" + (up ? "true" : "false") + "}";
  }
  json += "]}";
  lastScanJson = json;
  Serial.printf("주변 고프로·액션5 %d대를 찾았습니다.\n", count);
}

// 찾기는 웹 요청 안에서 기다리지 않습니다. 결과가 나오면 다음 요청이 가져갑니다.
void serviceScan() {
  if (scanWanted && !scanRunning) {
    if (bleBusy) return;
    ensureBleStack();
    bleBusy = true;
    scanCount = 0;
    memset(scanHits, 0, sizeof(scanHits));
    NimBLEScan* scan = NimBLEDevice::getScan();
    scan->setScanCallbacks(&goProScanCallbacks, false);
    scan->setActiveScan(true);
    scan->setInterval(100);
    scan->setWindow(99);
    scan->setDuplicateFilter(1);
    if (!scan->start(3000, false, true)) {
      bleBusy = false;
      scanWanted = false;
      lastScanJson = "{\"ok\":false,\"pending\":false,\"cameras\":[],\"detail\":\"블루투스 찾기를 시작하지 못했습니다\"}";
      return;
    }
    scanWanted = false;
    scanRunning = true;
    scanBegan = millis();
  }
  if (!scanRunning) return;
  NimBLEScan* scan = NimBLEDevice::getScan();
  if (scan->isScanning() && millis() - scanBegan < 4000) return;
  if (scan->isScanning()) scan->stop();
  scan->clearResults();
  finishScanJson();
  scanRunning = false;
  bleBusy = false;
}

// 주변 고프로·액션 5 프로의 블루투스 맥 주소를 최대 4개 모읍니다. 아이폰은 이 번호를 직접 읽지 못합니다.
void handleScan() {
  const bool startNow = server.hasArg("start");
  if (startNow && !scanRunning) {
    if (bleBusy) {
      sendJson(503, false, "", "scan", "이미 카메라와 이야기하는 중입니다", "");
      return;
    }
    scanWanted = true;
    lastScanJson = "";
    server.send(200, "application/json", "{\"ok\":true,\"pending\":true,\"cameras\":[]}");
    return;
  }
  if (scanWanted || scanRunning || !lastScanJson.length()) {
    server.send(200, "application/json", "{\"ok\":true,\"pending\":true,\"cameras\":[]}");
    return;
  }
  server.send(200, "application/json", lastScanJson);
}

bool readVarint(const uint8_t* data, size_t len, size_t& index, uint32_t& value) {
  value = 0;
  int shift = 0;
  while (index < len && shift <= 28) {
    const uint8_t byte = data[index++];
    value |= (uint32_t)(byte & 0x7F) << shift;
    if ((byte & 0x80) == 0) return true;
    shift += 7;
  }
  return false;
}

struct FoundPreset {
  int id = -1;
  int titleId = -1;
  char name[24];
};

void readPresetMessage(const uint8_t* data, size_t len, FoundPreset& hit) {
  memset(hit.name, 0, sizeof(hit.name));
  size_t index = 0;
  while (index < len) {
    uint32_t key = 0;
    if (!readVarint(data, len, index, key)) return;
    const uint32_t field = key >> 3;
    const uint32_t wire = key & 7;
    if (wire == 0) {
      uint32_t number = 0;
      if (!readVarint(data, len, index, number)) return;
      if (field == 1) hit.id = (int)number;
      if (field == 3) hit.titleId = (int)number;
    } else if (wire == 2) {
      uint32_t size = 0;
      if (!readVarint(data, len, index, size)) return;
      if (index + size > len) return;
      if (field == 10 && size > 0 && size < sizeof(hit.name)) {
        memcpy(hit.name, data + index, size);
        hit.name[size] = 0;
      }
      index += size;
    } else if (wire == 5) {
      index += 4;
    } else if (wire == 1) {
      index += 8;
    } else {
      return;
    }
  }
}

int collectPresets(const uint8_t* data, size_t len, FoundPreset* out, int maxOut) {
  int count = 0;
  size_t index = 0;
  if (len >= 2 && data[0] == 0xF5 && data[1] == 0xF2) index = 2;
  while (index < len && count < maxOut) {
    uint32_t key = 0;
    if (!readVarint(data, len, index, key)) break;
    const uint32_t field = key >> 3;
    const uint32_t wire = key & 7;
    if (wire == 0) {
      uint32_t ignored = 0;
      if (!readVarint(data, len, index, ignored)) break;
      continue;
    }
    if (wire != 2) break;
    uint32_t size = 0;
    if (!readVarint(data, len, index, size) || index + size > len) break;
    if (field == 1) {
      const uint8_t* group = data + index;
      size_t cursor = 0;
      while (cursor < size && count < maxOut) {
        uint32_t groupKey = 0;
        if (!readVarint(group, size, cursor, groupKey)) break;
        const uint32_t groupField = groupKey >> 3;
        const uint32_t groupWire = groupKey & 7;
        if (groupWire == 0) {
          uint32_t ignored = 0;
          if (!readVarint(group, size, cursor, ignored)) break;
          continue;
        }
        if (groupWire != 2) break;
        uint32_t presetSize = 0;
        if (!readVarint(group, size, cursor, presetSize) || cursor + presetSize > size) break;
        if (groupField == 2) {
          FoundPreset hit;
          readPresetMessage(group + cursor, presetSize, hit);
          if (hit.id >= 0) out[count++] = hit;
        }
        cursor += presetSize;
      }
    }
    index += size;
  }
  return count;
}

bool gatherNotifies(CamSlot& cam, NimBLERemoteCharacteristic* writeTo, const uint8_t* body, size_t bodyLen,
                    uint8_t* out, size_t& outLen, size_t outMax) {
  outLen = 0;
  auto take = [&](const uint8_t* chunk, size_t chunkLen) {
    if (chunkLen >= 2 && (chunk[0] & 0xE0) == 0x20) {
      chunk += 2;
      chunkLen -= 2;
    } else if (chunkLen >= 1 && (chunk[0] & 0x80) != 0) {
      chunk += 1;
      chunkLen -= 1;
    }
    if (chunkLen == 0 || outLen >= outMax) return;
    if (outLen + chunkLen > outMax) chunkLen = outMax - outLen;
    memcpy(out + outLen, chunk, chunkLen);
    outLen += chunkLen;
  };
  String ignored;
  const int slot = (int)(&cam - cams);
  waitingSlot = slot;
  const bool wrote = writeFramed(cam, writeTo, body, bodyLen, 500, ignored, true);
  if (notifyLen > 0) take(notifyBuf, notifyLen);
  waitingSlot = slot;
  gotNotify = false;
  const uint32_t started = millis();
  while (wrote && millis() - started < 900 && outLen + 8 < outMax) {
    if (!gotNotify) {
      delay(15);
      continue;
    }
    gotNotify = false;
    take(notifyBuf, notifyLen);
  }
  waitingSlot = -1;
  return wrote && outLen > 0;
}

void handleCameraPresets() {
  if (!server.hasArg("mac")) {
    sendJson(400, false, "", "presets", "mac 이 필요합니다", "");
    return;
  }
  const String mac = normalizeMac(server.arg("mac"));
  if (!mac.length() || bleBusy) {
    sendJson(bleBusy ? 503 : 400, false, mac, "presets", bleBusy ? "이미 카메라와 이야기하는 중입니다" : "맥 주소 형식이 아닙니다", "");
    return;
  }
  bleBusy = true;
  String detail;
  int slot = -1;
  if (!prepareSession(mac, slot, detail) || slot < 0 || !cams[slot].queryChar) {
    bleBusy = false;
    sendJson(502, false, mac, "presets", "카메라 질의 특성을 찾지 못했거나 연결하지 못했습니다", "");
    return;
  }
  const uint8_t body[] = {0xF5, 0x72, 0x18, 0x01, 0x20, 0x01};
  uint8_t raw[480];
  size_t rawLen = 0;
  waitingSlot = slot;
  const bool heard = gatherNotifies(cams[slot], cams[slot].queryChar, body, sizeof(body), raw, rawLen, sizeof(raw));
  waitingSlot = -1;
  bleBusy = false;
  FoundPreset found[12];
  const int count = heard ? collectPresets(raw, rawLen, found, 12) : 0;
  String json = "{\"ok\":true,\"presets\":[";
  for (int i = 0; i < count; i++) {
    if (i) json += ",";
    json += "{\"id\":" + String(found[i].id) + ",\"titleId\":" + String(found[i].titleId) + ",\"name\":\"" + jsonEscape(String(found[i].name)) + "\"}";
  }
  json += "]}";
  server.send(200, "application/json", json);
  Serial.printf("카메라 프리셋 %d개\n", count);
}

void handleCameraPresetLoad() {
  if (!server.hasArg("mac") || !server.hasArg("id")) {
    sendJson(400, false, "", "load", "mac 과 id 가 필요합니다", "");
    return;
  }
  const String mac = normalizeMac(server.arg("mac"));
  const int presetId = server.arg("id").toInt();
  if (!mac.length() || bleBusy) {
    sendJson(bleBusy ? 503 : 400, false, mac, "load", bleBusy ? "이미 카메라와 이야기하는 중입니다" : "맥 주소 형식이 아닙니다", "");
    return;
  }
  bleBusy = true;
  String detail;
  int slot = -1;
  if (!prepareSession(mac, slot, detail)) {
    bleBusy = false;
    sendJson(502, false, mac, "load", detail, "");
    return;
  }
  const uint8_t body[] = {
    0x40,
    (uint8_t)((presetId >> 24) & 0xFF),
    (uint8_t)((presetId >> 16) & 0xFF),
    (uint8_t)((presetId >> 8) & 0xFF),
    (uint8_t)(presetId & 0xFF),
  };
  String responseHex;
  const bool notified = writeFramed(cams[slot], cams[slot].commandChar, body, sizeof(body), kCommandWaitMs, responseHex, true);
  bleBusy = false;
  sendJson(notified ? 200 : 502, notified, mac, "load", notified ? "카메라 프리셋을 불렀습니다" : "카메라가 프리셋 불러오기에 답하지 않았습니다", responseHex);
}

void handleCameraSetting() {
  if (!server.hasArg("mac") || !server.hasArg("setting") || !server.hasArg("option")) {
    sendJson(400, false, "", "setting", "mac, setting, option 이 필요합니다", "");
    return;
  }
  const String mac = normalizeMac(server.arg("mac"));
  const int setting = server.arg("setting").toInt();
  const int option = server.arg("option").toInt();
  if (!mac.length() || setting < 0 || setting > 255 || option < 0 || option > 255 || bleBusy) {
    sendJson(400, false, mac, "setting", "설정 번호가 범위 밖이거나 지금 바쁠 수 있습니다", "");
    return;
  }
  bleBusy = true;
  String detail;
  int slot = -1;
  if (!prepareSession(mac, slot, detail) || !cams[slot].commandChar) {
    bleBusy = false;
    sendJson(502, false, mac, "setting", detail, "");
    return;
  }
  const uint8_t body[] = {0x03, (uint8_t)setting, (uint8_t)option};
  String responseHex;
  const bool notified = writeFramed(cams[slot], cams[slot].commandChar, body, sizeof(body), kCommandWaitMs, responseHex, true);
  bleBusy = false;
  sendJson(notified ? 200 : 502, notified, mac, "setting", notified ? "카메라 설정을 보냈습니다" : "카메라가 설정에 답하지 않았습니다", responseHex);
}

void startServerOnce() {
  if (serverStarted) return;
  server.on("/", HTTP_GET, handleRoot);
  server.on("/shutter", HTTP_GET, handleShutter);
  server.on("/presets", HTTP_GET, handleCameraPresets);
  server.on("/preset/load", HTTP_GET, handleCameraPresetLoad);
  server.on("/setting", HTTP_GET, handleCameraSetting);
  server.on("/scan", HTTP_GET, handleScan);
  server.begin();
  serverStarted = true;
  Serial.println("HTTP 80번 포트를 열었습니다.");
  Serial.printf("직접 연결 주소: http://%s/\n", directIpText().c_str());
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("와이파이 주소: http://%s/\n", WiFi.localIP().toString().c_str());
  }
  publishBoard();
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("액션5 브리지 시작");
  Serial.println("NimBLE로 고프로를 최대 4대까지 등록합니다. 8대 동기 촬영은 이 보드에서 되지 않습니다.");
  WiFi.persistent(false);
  WiFi.setAutoReconnect(true);
  ensureDirect();
  startServerOnce();
  connectWifi();
  nextWifiTryMs = millis() + kWifiRetryGapMs;
}

void loop() {
  ensureDirect();
  if (!serverStarted) startServerOnce();
  if (WiFi.status() != WL_CONNECTED) {
    stopBoardName();
    if ((int32_t)(millis() - nextWifiTryMs) >= 0) {
      connectWifi();
      nextWifiTryMs = millis() + kWifiRetryGapMs;
    }
  } else if (!mdnsUp) {
    publishBoard();
  }
  server.handleClient();
  serviceScan();
  serviceKeepAlive();
}
