#pragma once

#include "dji_rs.h"

enum ShotStepType {
  SHOT_MOVE,
  SHOT_MOVE_ZOOM,
  SHOT_DIAL,
  SHOT_SPEED,
  SHOT_WAIT,
  SHOT_STOP,
  SHOT_LOOP
};

struct ShotStep {
  ShotStepType type;
  float yaw;
  float roll;
  float pitch;
  float dur;
  bool abs;
  int16_t dial;
};

class ShotPlayer {
 public:
  explicit ShotPlayer(DjiRs& gimbal);
  bool start(const char* name, float timeScale);
  void loop();
  void cancel();
  bool busy() const { return running_; }
  const char* name() const { return name_; }

 private:
  bool load(const char* name, float timeScale);
  void fire(const ShotStep& step);
  void stopDial();
  uint32_t stepDurationMs(const ShotStep& step) const;

  DjiRs& gimbal_;
  ShotStep steps_[16];
  size_t count_ = 0;
  size_t index_ = 0;
  uint32_t stepEndMs_ = 0;
  bool running_ = false;
  bool holdSpeed_ = false;
  const char* name_ = "";
};
