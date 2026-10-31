#include <Arduino.h>
#include <ETH.h>
#include <WebServer.h>

#include "dji_rs.h"
#include "shot_player.h"
#include "sony_remote.h"

/*
 * 배선 (중요)
 * SN65HVD230는 짐벌 USB-C(흰색 D- / 녹색 D+)에 꽂지 마세요. USB PHY가 손상될 수 있습니다.
 *
 * Olimex ESP32-POE          SN65HVD230              RS 2 / RS 2 Pro RSA/NATO
 * 3V3                   ->  3.3V
 * GND                   ->  GND                 ->  pin6 GND   (필수, 공통 GND)
 * GPIO13 CAN TX         ->  TXD / CTX
 * GPIO16 CAN RX         ->  RXD / CRX
 *                           CANH                ->  pin4 CANH
 *                           CANL                ->  pin2 CANL
 *                           Rs: GND 또는 10k→GND (1Mbps)
 *
 * USB-C 케이블을 "연장선"으로만 쓸 경우에도 반대쪽은 RSA CAN 핀이어야 합니다.
 * 검정(GND)도 반드시 같이 연결하세요. 빨강(VBUS)은 트랜시버 3.3V에 넣지 마세요.
 */

#define CAN_TX_PIN 13
#define CAN_RX_PIN 16
#define DEFAULT_JOG_DPS 30.0f
#define DEFAULT_MOVE_SEC 1.0f
#define ATTITUDE_INTERVAL_MS 200
#define DEFAULT_DIAL 800
#define CAM_SHUTTER 0x0001
#define CAM_REC_START 0x0003
#define CAM_REC_STOP 0x0004

WebServer server(80);
DjiRs gimbal;
ShotPlayer shots(gimbal);
SonyRemote sony;
bool ethGotIP = false;

void cancelShot() {
  shots.cancel();
}

float argOr(const char* name, float fallback) {
  if (!server.hasArg(name)) {
    return fallback;
  }
  return server.arg(name).toFloat();
}

void sendText(int code, const String& body) {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(code, "text/plain; charset=utf-8", body);
}

void sendJson(int code, const String& body) {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(code, "application/json; charset=utf-8", body);
}

String ok(const char* action) {
  return String(action) + (gimbal.lastSendOk() ? " ok" : " CAN_TX_FAIL");
}

void handleRoot() {
  const char* page =
      "<!DOCTYPE html><html><head><meta charset='utf-8'><meta name='viewport' "
      "content='width=device-width,initial-scale=1'><title>Ronin Controller</title>"
      "<style>body{font-family:sans-serif;margin:16px;max-width:720px}button,a.btn{display:inline-block;"
      "margin:4px;padding:10px 14px;font-size:16px;text-decoration:none;color:#000;background:#eee;"
      "border:1px solid #999}pre{background:#111;color:#9f9;padding:12px;overflow:auto}</style></head>"
      "<body><h1>RS2 Companion API</h1>"
      "<p>짐벌은 RSA/NATO CANH·CANL로 연결해야 합니다. USB-C 흰색/녹색은 USB 데이터선입니다.</p>"
      "<p>"
      "<a class='btn' href='/recenter'>Recenter</a>"
      "<a class='btn' href='/preset/down'>Look Down</a>"
      "<a class='btn' href='/preset/up'>Look Up</a>"
      "<a class='btn' href='/stop'>Stop</a>"
      "</p><p>"
      "<a class='btn' href='/jog/yaw/left'>Yaw L</a>"
      "<a class='btn' href='/jog/yaw/right'>Yaw R</a>"
      "<a class='btn' href='/jog/pitch/up'>Pitch Up</a>"
      "<a class='btn' href='/jog/pitch/down'>Pitch Down</a>"
      "<a class='btn' href='/jog/roll/left'>Roll L</a>"
      "<a class='btn' href='/jog/roll/right'>Roll R</a>"
      "<a class='btn' href='/record'>Record</a>"
      "<a class='btn' href='/photo'>Photo</a>"
      "<a class='btn' href='/can/listen?sec=30'>CAN Listen 30s</a>"
      "</p><p>"
      "<a class='btn' href='/shot/front'>Front</a>"
      "<a class='btn' href='/shot/wide'>Wide</a>"
      "<a class='btn' href='/shot/tight'>Tight</a>"
      "<a class='btn' href='/shot/verse'>Verse</a>"
      "<a class='btn' href='/shot/chorus'>Chorus</a>"
      "<a class='btn' href='/shot/hero'>Hero</a>"
      "<a class='btn' href='/shot/high'>High</a>"
      "<a class='btn' href='/shot/hands'>Hands</a>"
      "<a class='btn' href='/shot/reveal'>Reveal</a>"
      "<a class='btn' href='/shot/drop'>Drop</a>"
      "<a class='btn' href='/shot/profile-l'>Profile L</a>"
      "<a class='btn' href='/shot/profile-r'>Profile R</a>"
      "<a class='btn' href='/shot/qtr-l'>3/4 L</a>"
      "<a class='btn' href='/shot/qtr-r'>3/4 R</a>"
      "<a class='btn' href='/shot/whip-l'>Whip L</a>"
      "<a class='btn' href='/shot/whip-r'>Whip R</a>"
      "<a class='btn' href='/shot/drift-l'>Drift L</a>"
      "<a class='btn' href='/shot/drift-r'>Drift R</a>"
      "<a class='btn' href='/shot/dutch-l'>Dutch L</a>"
      "<a class='btn' href='/shot/dutch-r'>Dutch R</a>"
      "<a class='btn' href='/shot/level'>Level</a>"
      "<a class='btn' href='/shot/sway'>Sway</a>"
      "<a class='btn' href='/shot/push'>Push</a>"
      "<a class='btn' href='/shot/pull'>Pull</a>"
      "<a class='btn' href='/shot/crash'>Crash</a>"
      "<a class='btn' href='/shot/snap-wide'>Snap Wide</a>"
      "<a class='btn' href='/shot/snap-tight'>Snap Tight</a>"
      "<a class='btn' href='/zoom/in'>Zoom In</a>"
      "<a class='btn' href='/zoom/out'>Zoom Out</a>"
      "<a class='btn' href='/zoom/stop'>Zoom Stop</a>"
      "</p><pre id='s'>loading...</pre>"
      "<script>async function t(){s.textContent=await (await fetch('/status')).text()}t();setInterval(t,1000)</script>"
      "<h2>Companion Generic HTTP</h2>"
      "<pre>GET /status\n"
      "GET /recenter\n"
      "GET /stop\n"
      "GET /move?yaw=0&roll=0&pitch=0&time=1\n"
      "GET /relative?yaw=15&roll=0&pitch=0&time=0.5\n"
      "GET /preset/front  /preset/down  /preset/up\n"
      "GET /jog/yaw/left?speed=30     (누르기)\n"
      "GET /jog/yaw/right?speed=30\n"
      "GET /jog/pitch/up?speed=30\n"
      "GET /jog/pitch/down?speed=30\n"
      "GET /jog/roll/left?speed=20\n"
      "GET /jog/roll/right?speed=20\n"
      "GET /stop                      (떼기)\n"
      "GET /speed?yaw=0&roll=0&pitch=0\n"
      "GET /record?action=toggle|start|stop\n"
      "GET /photo\n"
      "GET /sony/connect?ssid=DIRECT-xxxx&pass=비밀번호\n"
      "GET /sony/status\n"
      "GET /can/listen?sec=30\n"
      "GET /shots\n"
      "GET /shot/front|wide|tight|verse|chorus|hero|high|hands\n"
      "GET /shot/reveal|drop|profile-l|profile-r|qtr-l|qtr-r\n"
      "GET /shot/whip-l|whip-r|drift-l|drift-r\n"
      "GET /shot/dutch-l|dutch-r|level|sway|push|pull|crash\n"
      "GET /shot/snap-wide|snap-tight\n"
      "  ?t=1  (0.25~4, 클수록 느림). drift/sway는 /stop 으로 정지\n"
      "  축+24-70 줌 동시. +줌인 / -줌아웃. 모터는 줌링에 물려 있어야 함\n"
      "GET /zoom/in?speed=800   (누르기, 포커스모터)\n"
      "GET /zoom/out?speed=800\n"
      "GET /zoom/stop           (떼기)\n"
      "GET /focus/in /focus/out /focus/stop  (같은 모터)\n"
      "GET /record?action=toggle|start|stop  (로닌 RSS)\n"
      "GET /photo</pre>"
      "</body></html>";
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(200, "text/html; charset=utf-8", page);
}

void handleStatus() {
  const DjiAttitude& a = gimbal.attitude();
  const DjiCanStats& s = gimbal.stats();

  String json = "{";
  json += "\"ip\":\"" + ETH.localIP().toString() + "\",";
  json += "\"eth_link\":" + String(ETH.linkUp() ? "true" : "false") + ",";
  json += "\"twai\":\"" + String(gimbal.twaiState()) + "\",";
  json += "\"tx_error\":" + String(gimbal.txErrorCounter()) + ",";
  json += "\"rx_error\":" + String(gimbal.rxErrorCounter()) + ",";
  json += "\"yaw\":" + String(a.yaw, 1) + ",";
  json += "\"roll\":" + String(a.roll, 1) + ",";
  json += "\"pitch\":" + String(a.pitch, 1) + ",";
  json += "\"attitude_valid\":" + String(a.valid ? "true" : "false") + ",";
  json += "\"attitude_age_ms\":" + String(a.valid ? (millis() - a.updatedMs) : -1) + ",";
  json += "\"tx_frames\":" + String(s.txFrames) + ",";
  json += "\"rx_bytes\":" + String(s.rxBytes) + ",";
  json += "\"tx_fails\":" + String(s.txFails) + ",";
  json += "\"parse_errors\":" + String(s.parseErrors) + ",";
  json += "\"replies\":" + String(s.replies) + ",";
  json += "\"sony_wifi\":" + String(sony.wifiConnected() ? "true" : "false") + ",";
  json += "\"sony_ssid\":\"" + sony.ssid() + "\",";
  json += "\"sony_recording\":" + String(sony.recording() ? "true" : "false") + ",";
  String sonyErr = sony.lastError();
  sonyErr.replace("\"", "'");
  json += "\"sony_error\":\"" + sonyErr + "\",";
  json += "\"shot\":\"" + String(shots.name()) + "\",";
  json += "\"shot_busy\":" + String(shots.busy() ? "true" : "false");
  json += "}";
  sendJson(200, json);
}

void handleRecenter() {
  cancelShot();
  gimbal.moveTo(0, 0, 0, argOr("time", 1.5f), true);
  sendText(200, ok("recenter"));
}

void handleStop() {
  cancelShot();
  gimbal.stop();
  sendText(200, ok("stop"));
}

void handleMove() {
  cancelShot();
  const bool relative = server.uri() == "/relative";
  gimbal.moveTo(argOr("yaw", 0), argOr("roll", 0), argOr("pitch", 0),
                argOr("time", DEFAULT_MOVE_SEC), !relative);
  sendText(200, ok(relative ? "relative" : "move"));
}

void handlePresetFront() {
  cancelShot();
  gimbal.moveTo(0, 0, 0, 1.5f, true);
  sendText(200, ok("preset/front"));
}

void handlePresetDown() {
  cancelShot();
  gimbal.moveTo(0, 0, 90, 1.5f, true);
  sendText(200, ok("preset/down"));
}

void handlePresetUp() {
  cancelShot();
  gimbal.moveTo(0, 0, -30, 1.5f, true);
  sendText(200, ok("preset/up"));
}

void handleSpeed() {
  cancelShot();
  gimbal.setSpeed(argOr("yaw", 0), argOr("roll", 0), argOr("pitch", 0));
  sendText(200, ok("speed"));
}

void handleJog() {
  cancelShot();
  const float speed = argOr("speed", DEFAULT_JOG_DPS);
  const String uri = server.uri();
  float yaw = 0, roll = 0, pitch = 0;
  if (uri.endsWith("/yaw/left")) {
    yaw = -speed;
  } else if (uri.endsWith("/yaw/right")) {
    yaw = speed;
  } else if (uri.endsWith("/pitch/up")) {
    pitch = -speed;
  } else if (uri.endsWith("/pitch/down")) {
    pitch = speed;
  } else if (uri.endsWith("/roll/left")) {
    roll = -speed;
  } else if (uri.endsWith("/roll/right")) {
    roll = speed;
  } else {
    sendText(404, "unknown jog");
    return;
  }
  gimbal.setSpeed(yaw, roll, pitch);
  sendText(200, ok("jog"));
}

void handleRecord() {
  const String action = server.hasArg("action") ? server.arg("action") : "toggle";
  static bool rec = false;
  uint16_t cam = CAM_REC_START;
  if (action == "stop" || (action == "toggle" && rec)) {
    cam = CAM_REC_STOP;
    rec = false;
  } else {
    rec = true;
  }
  const bool okSend = gimbal.cameraAction(cam);
  sendText(okSend ? 200 : 503, okSend ? (rec ? "recording" : "stopped") : "CAM_TX_FAIL");
}

void handlePhoto() {
  const bool okSend = gimbal.cameraAction(CAM_SHUTTER);
  sendText(okSend ? 200 : 503, okSend ? "photo" : "CAM_TX_FAIL");
}

void handleMotor() {
  const String uri = server.uri();
  const int speed = static_cast<int>(argOr("speed", DEFAULT_DIAL));
  int dial = 0;
  if (uri.endsWith("/in")) {
    dial = speed;
  } else if (uri.endsWith("/out")) {
    dial = -speed;
  } else if (uri.endsWith("/stop")) {
    dial = 0;
  } else {
    sendText(404, "unknown motor");
    return;
  }
  const bool okSend = gimbal.setDial(static_cast<int16_t>(dial));
  sendText(okSend ? 200 : 503, okSend ? "motor" : "DIAL_TX_FAIL");
}

void handleSonyConnect() {
  if (!server.hasArg("ssid") || !server.hasArg("pass")) {
    sendText(400, "ssid and pass required");
    return;
  }
  const String host = server.hasArg("host") ? server.arg("host") : "192.168.122.1";
  const bool okSend = sony.saveAndConnect(server.arg("ssid"), server.arg("pass"), host);
  sendText(okSend ? 200 : 503, okSend ? "sony wifi connected" : sony.lastError());
}

void handleSonyStatus() {
  String json = "{";
  json += "\"ssid\":\"" + sony.ssid() + "\",";
  json += "\"host\":\"" + sony.host() + "\",";
  json += "\"wifi\":" + String(sony.wifiConnected() ? "true" : "false") + ",";
  json += "\"recording\":" + String(sony.recording() ? "true" : "false") + ",";
  String err = sony.lastError();
  err.replace("\"", "'");
  json += "\"error\":\"" + err + "\",";
  json += "\"api\":" + String(sony.apiList().length() ? sony.apiList() : "null");
  json += "}";
  sendJson(200, json);
}

void handleShot() {
  const String uri = server.uri();
  const String name = uri.substring(String("/shot/").length());
  if (shots.start(name.c_str(), argOr("t", 1.0f))) {
    sendText(200, String("shot ") + name);
  } else {
    sendText(404, "unknown shot");
  }
}

void handleShotList() {
  sendJson(200,
           "{\"shots\":[\"front\",\"wide\",\"tight\",\"verse\",\"chorus\",\"hero\","
           "\"high\",\"hands\",\"reveal\",\"drop\",\"profile-l\",\"profile-r\","
           "\"qtr-l\",\"qtr-r\",\"whip-l\",\"whip-r\",\"drift-l\",\"drift-r\","
           "\"dutch-l\",\"dutch-r\",\"level\",\"sway\",\"push\",\"pull\",\"crash\","
           "\"snap-wide\",\"snap-tight\"]}");
}

void handleCanListen() {
  float sec = argOr("sec", 30);
  if (sec < 5) {
    sec = 5;
  }
  if (sec > 120) {
    sec = 120;
  }
  gimbal.startListen(static_cast<uint32_t>(sec * 1000.0f));
  sendText(200, "CAN listen started. Watch serial, press the Ronin record button.");
}

void onEthEvent(WiFiEvent_t event) {
  switch (event) {
    case ARDUINO_EVENT_ETH_START:
      Serial.println("이더넷 시작");
      ETH.setHostname("ronin-controller");
      ETH.config(IPAddress(192, 168, 100, 100), IPAddress(192, 168, 100, 1), IPAddress(255, 255, 255, 0), IPAddress(192, 168, 100, 1));
      Serial.println("고정 주소 192.168.100.100");
      break;
    case ARDUINO_EVENT_ETH_CONNECTED:
      Serial.println("랜선 연결됨 (링크 업)");
      break;
    case ARDUINO_EVENT_ETH_GOT_IP:
      ethGotIP = true;
      Serial.println("IP 할당됨. 브라우저/컴패니언에 이 주소를 입력하세요:");
      Serial.println(ETH.localIP());
      break;
    case ARDUINO_EVENT_ETH_DISCONNECTED:
      ethGotIP = false;
      Serial.println("랜선 분리됨");
      break;
    case ARDUINO_EVENT_ETH_STOP:
      ethGotIP = false;
      Serial.println("이더넷 중지");
      break;
    case ARDUINO_EVENT_WIFI_STA_GOT_IP:
      Serial.print("카메라 Wi-Fi STA IP: ");
      Serial.println(WiFi.localIP());
      break;
    case ARDUINO_EVENT_WIFI_STA_DISCONNECTED:
      Serial.println("카메라 Wi-Fi 끊김");
      break;
    default:
      break;
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println();
  Serial.println("Ronin Controller 부팅");
  Serial.println("짐벌 연결: RSA CANH/CANL + GND. USB-C D+/D- 사용 금지.");

  if (!gimbal.begin(CAN_TX_PIN, CAN_RX_PIN)) {
    Serial.println("CAN 초기화 실패");
  }

  WiFi.onEvent(onEthEvent);
  Serial.println("이더넷 PHY 초기화 중...");
  if (!ETH.begin()) {
    Serial.println("ETH.begin() 실패. USB 전원/보드 종류를 확인하세요.");
  }
  sony.begin();

  server.on("/", handleRoot);
  server.on("/status", handleStatus);
  server.on("/recenter", handleRecenter);
  server.on("/stop", handleStop);
  server.on("/move", handleMove);
  server.on("/relative", handleMove);
  server.on("/preset/front", handlePresetFront);
  server.on("/preset/down", handlePresetDown);
  server.on("/preset/up", handlePresetUp);
  server.on("/speed", handleSpeed);
  server.on("/jog/yaw/left", handleJog);
  server.on("/jog/yaw/right", handleJog);
  server.on("/jog/pitch/up", handleJog);
  server.on("/jog/pitch/down", handleJog);
  server.on("/jog/roll/left", handleJog);
  server.on("/jog/roll/right", handleJog);
  server.on("/record", handleRecord);
  server.on("/photo", handlePhoto);
  server.on("/zoom/in", handleMotor);
  server.on("/zoom/out", handleMotor);
  server.on("/zoom/stop", handleMotor);
  server.on("/focus/in", handleMotor);
  server.on("/focus/out", handleMotor);
  server.on("/focus/stop", handleMotor);
  server.on("/motor/in", handleMotor);
  server.on("/motor/out", handleMotor);
  server.on("/motor/stop", handleMotor);
  server.on("/sony/connect", handleSonyConnect);
  server.on("/sony/status", handleSonyStatus);
  server.on("/can/listen", handleCanListen);
  server.on("/shots", handleShotList);
  server.on("/shot/front", handleShot);
  server.on("/shot/wide", handleShot);
  server.on("/shot/tight", handleShot);
  server.on("/shot/verse", handleShot);
  server.on("/shot/chorus", handleShot);
  server.on("/shot/hero", handleShot);
  server.on("/shot/high", handleShot);
  server.on("/shot/hands", handleShot);
  server.on("/shot/reveal", handleShot);
  server.on("/shot/drop", handleShot);
  server.on("/shot/profile-l", handleShot);
  server.on("/shot/profile-r", handleShot);
  server.on("/shot/qtr-l", handleShot);
  server.on("/shot/qtr-r", handleShot);
  server.on("/shot/whip-l", handleShot);
  server.on("/shot/whip-r", handleShot);
  server.on("/shot/drift-l", handleShot);
  server.on("/shot/drift-r", handleShot);
  server.on("/shot/dutch-l", handleShot);
  server.on("/shot/dutch-r", handleShot);
  server.on("/shot/level", handleShot);
  server.on("/shot/sway", handleShot);
  server.on("/shot/push", handleShot);
  server.on("/shot/pull", handleShot);
  server.on("/shot/crash", handleShot);
  server.on("/shot/snap-wide", handleShot);
  server.on("/shot/snap-tight", handleShot);
  server.begin();
}

void loop() {
  server.handleClient();
  gimbal.loop();
  shots.loop();
  sony.loop();

  static unsigned long lastAttitudeMs = 0;
  if (!gimbal.listening()) {
    const uint32_t attitudeInterval = gimbal.lastSendOk() ? ATTITUDE_INTERVAL_MS : 1000;
    if (millis() - lastAttitudeMs >= attitudeInterval) {
      lastAttitudeMs = millis();
      gimbal.requestAttitude();
    }
  }

  static unsigned long lastStatusMs = 0;
  if (!ethGotIP && (millis() - lastStatusMs) > 5000) {
    lastStatusMs = millis();
    Serial.printf("IP 대기 중... link=%s can=%s\n", ETH.linkUp() ? "UP" : "DOWN",
                  gimbal.twaiState());
  }
}
