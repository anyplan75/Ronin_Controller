#include <Arduino.h>
#include <BLEDevice.h>
#include <Preferences.h>
#include <WebServer.h>
#include <WiFi.h>

#include "gopro_ble_frame.h"

// 이 프로그램은 로닌 ESP32-POE 에 올리지 않습니다.
// 고프로 액션 5 프로 한 대만, Open GoPro BLE(서비스 FEA6)로 붙잡고
// 집 와이파이의 HTTP 로 앱의 명령을 받습니다.
// 요청마다 블루투스를 끊지 않습니다. FFE0/FFE1 은 쓰지 않습니다.

static const char* kService = "0000fea6-0000-1000-8000-00805f9b34fb";
static const char* kCommand = "b5f90072-aa8d-11e3-9046-0002a5d5c51b";
static const char* kCommandRsp = "b5f90073-aa8d-11e3-9046-0002a5d5c51b";
static const char* kSetting = "b5f90074-aa8d-11e3-9046-0002a5d5c51b";
static const char* kSettingRsp = "b5f90075-aa8d-11e3-9046-0002a5d5c51b";

WebServer server(80);
Preferences prefs;

static BLEClient* client = nullptr;
static BLERemoteCharacteristic* commandChar = nullptr;
static BLERemoteCharacteristic* settingChar = nullptr;
static bool sessionUp = false;
static bool scanning = false;
static String savedBle;
static String foundBle;
static GoproAssembler incoming;
static volatile bool responseReady = false;
static uint8_t responseStatus = 0xFF;
static uint32_t lastReconnect = 0;

static void noteBle(const char* text) {
  Serial.println(text);
}

static void onNotify(BLERemoteCharacteristic*, uint8_t* data, size_t length, bool) {
  bool done = false;
  if (!goproAssemblerPush(&incoming, data, (uint8_t)length, &done)) {
    return;
  }
  if (done && incoming.payloadLen >= 2) {
    responseStatus = incoming.payload[1];
    responseReady = true;
  }
}

class ScanSink : public BLEAdvertisedDeviceCallbacks {
  void onResult(BLEAdvertisedDevice device) override {
    if (foundBle.length()) {
      return;
    }
    const bool named = device.getName().find("GoPro") != std::string::npos ||
                       device.getName().rfind("GP", 0) == 0;
    const bool service = device.haveServiceUUID() && device.isAdvertisingService(BLEUUID(kService));
    if (!named && !service) {
      return;
    }
    foundBle = device.getAddress().toString().c_str();
    BLEDevice::getScan()->stop();
  }
};

static void dropSession() {
  sessionUp = false;
  commandChar = nullptr;
  settingChar = nullptr;
  if (client != nullptr && client->isConnected()) {
    client->disconnect();
  }
}

static bool waitResponse() {
  const uint32_t start = millis();
  while (!responseReady && millis() - start < 4000) {
    delay(20);
  }
  return responseReady && responseStatus == 0;
}

static bool writeFrame(BLERemoteCharacteristic* channel, const GoproBytes& frame) {
  if (!sessionUp || channel == nullptr) {
    return false;
  }
  goproAssemblerReset(&incoming);
  responseReady = false;
  responseStatus = 0xFF;
  channel->writeValue((uint8_t*)frame.data, frame.length, true);
  return waitResponse();
}

static bool attachCharacteristics() {
  BLERemoteService* service = client->getService(kService);
  if (service == nullptr) {
    noteBle("FEA6 서비스가 없습니다.");
    return false;
  }
  commandChar = service->getCharacteristic(kCommand);
  settingChar = service->getCharacteristic(kSetting);
  BLERemoteCharacteristic* commandRsp = service->getCharacteristic(kCommandRsp);
  BLERemoteCharacteristic* settingRsp = service->getCharacteristic(kSettingRsp);
  if (commandChar == nullptr || settingChar == nullptr || commandRsp == nullptr || settingRsp == nullptr) {
    noteBle("Open GoPro 특성을 찾지 못했습니다.");
    return false;
  }
  commandRsp->registerForNotify(onNotify);
  settingRsp->registerForNotify(onNotify);
  return true;
}

static bool connectAddress(const String& address) {
  if (address.length() < 11) {
    return false;
  }
  if (client == nullptr) {
    client = BLEDevice::createClient();
  }
  if (client->isConnected()) {
    client->disconnect();
    delay(200);
  }
  BLEAddress ble(address.c_str());
  if (!client->connect(ble)) {
    sessionUp = false;
    return false;
  }
  if (!attachCharacteristics()) {
    dropSession();
    return false;
  }
  sessionUp = true;
  savedBle = address;
  prefs.putString("ble", address);
  noteBle("Open GoPro 세션을 유지합니다.");
  return true;
}

static bool scanAndConnect() {
  if (scanning) {
    return false;
  }
  scanning = true;
  foundBle = "";
  static ScanSink sink;
  BLEScan* scan = BLEDevice::getScan();
  scan->setAdvertisedDeviceCallbacks(&sink, true);
  scan->setActiveScan(true);
  scan->start(8, false);
  scan->clearResults();
  scanning = false;
  if (!foundBle.length()) {
    noteBle("GoPro 광고를 찾지 못했습니다.");
    return false;
  }
  return connectAddress(foundBle);
}

static void sendText(int code, const String& body) {
  server.send(code, "text/plain; charset=utf-8", body);
}

static void sendJson(int code, const String& body) {
  server.send(code, "application/json; charset=utf-8", body);
}

static bool requireSession() {
  if (sessionUp && client != nullptr && client->isConnected()) {
    return true;
  }
  sessionUp = false;
  sendText(503, "블루투스 세션이 없습니다. /pair 로 한 번 연결하세요.");
  return false;
}

static void handleRoot() {
  const char* page =
      "<!doctype html><meta charset=utf-8><title>액션 5 중계</title>"
      "<h1>고프로 액션 5 프로 중계</h1>"
      "<p>이 기판은 로닌 PoE가 아닙니다. 카메라 한 대의 Open GoPro 블루투스를 붙잡고 있습니다.</p>"
      "<p>앱에는 이 기판의 집 와이파이 주소를 넣으세요. 카메라 주소 10.5.5.9 가 아닙니다.</p>"
      "<pre id=s></pre><script>fetch('/status').then(r=>r.text()).then(t=>s.textContent=t)</script>";
  server.send(200, "text/html; charset=utf-8", page);
}

static void handleStatus() {
  String json = "{";
  json += "\"relay\":true,";
  json += "\"ip\":\"" + WiFi.localIP().toString() + "\",";
  json += "\"ap\":\"" + WiFi.softAPIP().toString() + "\",";
  json += "\"ble\":" + String(sessionUp ? "true" : "false") + ",";
  json += "\"relay_ble\":\"" + String(sessionUp ? "연결됨" : "연결 안 됨") + "\",";
  json += "\"status\":{},\"settings\":{}";
  json += "}";
  sendJson(200, json);
}

static void handlePair() {
  const bool ok = scanAndConnect();
  sendText(ok ? 200 : 503, ok ? "paired" : "pair failed");
}

static void handleKeepAlive() {
  if (!requireSession()) {
    return;
  }
  GoproBytes frame;
  if (!goproKeepAliveFrame(&frame) || !writeFrame(commandChar, frame)) {
    sendText(503, "keep_alive failed");
    return;
  }
  sendText(200, "alive");
}

static void handleShutterStart() {
  if (!requireSession()) {
    return;
  }
  GoproBytes frame;
  if (!goproShutterFrame(true, &frame) || !writeFrame(commandChar, frame)) {
    sendText(503, "shutter start failed");
    return;
  }
  sendText(200, "started");
}

static void handleShutterStop() {
  if (!requireSession()) {
    return;
  }
  GoproBytes frame;
  if (!goproShutterFrame(false, &frame) || !writeFrame(commandChar, frame)) {
    sendText(503, "shutter stop failed");
    return;
  }
  sendText(200, "stopped");
}

static void handleSetting() {
  if (!server.hasArg("setting") || !server.hasArg("option")) {
    sendText(400, "setting and option required");
    return;
  }
  if (!requireSession()) {
    return;
  }
  const int setting = server.arg("setting").toInt();
  const int option = server.arg("option").toInt();
  if (setting < 0 || setting > 255 || option < 0 || option > 255) {
    sendText(400, "bad setting");
    return;
  }
  GoproBytes frame;
  if (!goproSettingFrame((uint8_t)setting, (uint8_t)option, &frame) || !writeFrame(settingChar, frame)) {
    sendText(503, "setting failed");
    return;
  }
  sendText(200, "setting");
}

static void handleUnavailable() {
  sendText(501, "이 중계는 셔터, 설정, 세션 유지만 보냅니다. 줌·웹캠·카메라 프리셋은 없습니다.");
}

static void handleWifi() {
  if (!server.hasArg("ssid") || !server.hasArg("pass")) {
    sendText(400, "ssid and pass required");
    return;
  }
  const String ssid = server.arg("ssid");
  const String pass = server.arg("pass");
  if (ssid.length() == 0) {
    sendText(400, "ssid required");
    return;
  }
  prefs.putString("ssid", ssid);
  prefs.putString("pass", pass);
  sendText(200, "wifi saved");
  delay(200);
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid.c_str(), pass.c_str());
  noteBle("집 와이파이로 옮기는 중. 비밀번호는 적지 않습니다.");
}

static void handleState() {
  handleStatus();
}

void setup() {
  Serial.begin(115200);
  prefs.begin("gopro-relay", false);
  savedBle = prefs.getString("ble", "");
  const String ssid = prefs.getString("ssid", "");
  const String pass = prefs.getString("pass", "");
  if (ssid.length()) {
    WiFi.mode(WIFI_STA);
    WiFi.begin(ssid.c_str(), pass.c_str());
    noteBle("저장된 집 와이파이에 붙는 중");
  } else {
    WiFi.mode(WIFI_AP);
    WiFi.softAP("Ronin-Action5");
    noteBle("설정용 와이파이 Ronin-Action5, 주소 192.168.4.1");
  }
  BLEDevice::init("Ronin-Action5");
  server.on("/", handleRoot);
  server.on("/status", handleStatus);
  server.on("/pair", handlePair);
  server.on("/gopro/camera/state", handleState);
  server.on("/gopro/camera/keep_alive", handleKeepAlive);
  server.on("/gopro/camera/shutter/start", handleShutterStart);
  server.on("/gopro/camera/shutter/stop", handleShutterStop);
  server.on("/gopro/camera/setting", handleSetting);
  server.on("/gopro/camera/presets/get", handleUnavailable);
  server.on("/gopro/camera/presets/load", handleUnavailable);
  server.on("/gopro/camera/digital_zoom", handleUnavailable);
  server.on("/gopro/webcam/start", handleUnavailable);
  server.on("/gopro/webcam/stop", handleUnavailable);
  server.on("/wifi", handleWifi);
  server.begin();
  goproAssemblerReset(&incoming);
}

void loop() {
  server.handleClient();
  if (client != nullptr && sessionUp && !client->isConnected()) {
    sessionUp = false;
    commandChar = nullptr;
    settingChar = nullptr;
    noteBle("블루투스 세션이 끊겼습니다. 다시 붙입니다.");
  }
  if (!sessionUp && savedBle.length() && !scanning && millis() - lastReconnect > 15000) {
    lastReconnect = millis();
    connectAddress(savedBle);
  }
}
