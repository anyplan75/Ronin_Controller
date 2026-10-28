#pragma once

#include <Arduino.h>

struct DjiAttitude {
  float yaw = 0;
  float roll = 0;
  float pitch = 0;
  uint32_t updatedMs = 0;
  bool valid = false;
};

struct DjiCanStats {
  uint32_t txFrames = 0;
  uint32_t rxBytes = 0;
  uint32_t parseErrors = 0;
  uint32_t txFails = 0;
  uint32_t replies = 0;
};

class DjiRs {
 public:
  bool begin(int txPin, int rxPin);
  void loop();

  bool moveTo(float yawDeg, float rollDeg, float pitchDeg, float timeSec, bool absolute);
  bool setSpeed(float yawDps, float rollDps, float pitchDps);
  bool stop();
  bool requestAttitude();
  bool setDial(int16_t speed);
  bool cameraAction(uint16_t action);
  void startListen(uint32_t durationMs);
  bool listening() const;

  const DjiAttitude& attitude() const { return attitude_; }
  const DjiCanStats& stats() const { return stats_; }
  bool lastSendOk() const { return lastSendOk_; }
  const char* twaiState() const;
  uint32_t txErrorCounter() const;
  uint32_t rxErrorCounter() const;

 private:
  enum ParseState { WAIT_SOF, WAIT_LEN, WAIT_BODY };

  bool sendPacket(const uint8_t* data, size_t len);
  bool sendCommand(uint8_t cmdSet, uint8_t cmdId, const uint8_t* payload, size_t payloadLen);
  void parseByte(uint8_t b);
  void handlePacket();
  static int16_t toDecideg(float deg, int16_t minV, int16_t maxV);
  static uint8_t toTimeTenth(float timeSec);

  void logFrame(const char* dir, uint32_t id, const uint8_t* data, uint8_t dlc);

  DjiAttitude attitude_;
  DjiCanStats stats_;
  bool lastSendOk_ = false;
  uint16_t seq_ = 0;
  uint32_t listenUntilMs_ = 0;

  ParseState parseState_ = WAIT_SOF;
  uint8_t parseBuf_[32];
  uint16_t parseLen_ = 0;
  uint8_t parseCount_ = 0;
};
