#include "shot_player.h"

#include <string.h>

namespace {

#define MV(y, r, p, t) \
  { SHOT_MOVE, (y), (r), (p), (t), true, 0 }
#define REL(y, r, p, t) \
  { SHOT_MOVE, (y), (r), (p), (t), false, 0 }
#define MZ(y, r, p, t, d) \
  { SHOT_MOVE_ZOOM, (y), (r), (p), (t), true, (d) }
#define RZ(y, r, p, t, d) \
  { SHOT_MOVE_ZOOM, (y), (r), (p), (t), false, (d) }
#define Z(d, t) \
  { SHOT_DIAL, 0, 0, 0, (t), false, (d) }
#define SPD(y, r, p) \
  { SHOT_SPEED, (y), (r), (p), 0, false, 0 }
#define WAIT(t) \
  { SHOT_WAIT, 0, 0, 0, (t), false, 0 }
#define HALT \
  { SHOT_STOP, 0, 0, 0, 0, false, 0 }
#define LOOP \
  { SHOT_LOOP, 0, 0, 0, 0, false, 0 }

bool usesDial(ShotStepType type) {
  return type == SHOT_DIAL || type == SHOT_MOVE_ZOOM;
}

void copyScaled(ShotStep* dst, const ShotStep* src, size_t n, float scale) {
  for (size_t i = 0; i < n; i++) {
    dst[i] = src[i];
    if (dst[i].type == SHOT_MOVE || dst[i].type == SHOT_MOVE_ZOOM ||
        dst[i].type == SHOT_WAIT || dst[i].type == SHOT_DIAL) {
      dst[i].dur *= scale;
      if (dst[i].dur < 0.1f &&
          (dst[i].type == SHOT_MOVE || dst[i].type == SHOT_MOVE_ZOOM)) {
        dst[i].dur = 0.1f;
      }
    }
  }
}

}  // namespace

ShotPlayer::ShotPlayer(DjiRs& gimbal) : gimbal_(gimbal) {}

bool ShotPlayer::start(const char* name, float timeScale) {
  if (timeScale < 0.25f) {
    timeScale = 0.25f;
  }
  if (timeScale > 4.0f) {
    timeScale = 4.0f;
  }
  cancel();
  if (!load(name, timeScale)) {
    return false;
  }
  name_ = name;
  index_ = 0;
  running_ = true;
  holdSpeed_ = false;
  fire(steps_[0]);
  stepEndMs_ = millis() + stepDurationMs(steps_[0]);
  Serial.printf("SHOT %s scale=%.2f\n", name_, timeScale);
  return true;
}

void ShotPlayer::stopDial() { gimbal_.setDial(0); }

void ShotPlayer::cancel() {
  if (running_) {
    stopDial();
  }
  running_ = false;
  holdSpeed_ = false;
  count_ = 0;
  index_ = 0;
  name_ = "";
}

void ShotPlayer::loop() {
  if (!running_ || holdSpeed_) {
    return;
  }
  if (millis() < stepEndMs_) {
    return;
  }
  if (usesDial(steps_[index_].type)) {
    stopDial();
  }
  index_++;
  if (index_ >= count_) {
    running_ = false;
    return;
  }
  const ShotStep& step = steps_[index_];
  if (step.type == SHOT_LOOP) {
    index_ = 0;
  }
  fire(steps_[index_]);
  stepEndMs_ = millis() + stepDurationMs(steps_[index_]);
}

uint32_t ShotPlayer::stepDurationMs(const ShotStep& step) const {
  if (step.type == SHOT_SPEED || step.type == SHOT_STOP) {
    return 0;
  }
  return static_cast<uint32_t>(step.dur * 1000.0f);
}

void ShotPlayer::fire(const ShotStep& step) {
  switch (step.type) {
    case SHOT_MOVE:
      gimbal_.moveTo(step.yaw, step.roll, step.pitch, step.dur, step.abs);
      holdSpeed_ = false;
      break;
    case SHOT_MOVE_ZOOM:
      gimbal_.moveTo(step.yaw, step.roll, step.pitch, step.dur, step.abs);
      gimbal_.setDial(step.dial);
      holdSpeed_ = false;
      break;
    case SHOT_DIAL:
      gimbal_.setDial(step.dial);
      holdSpeed_ = false;
      break;
    case SHOT_SPEED:
      gimbal_.setSpeed(step.yaw, step.roll, step.pitch);
      holdSpeed_ = true;
      running_ = true;
      break;
    case SHOT_STOP:
      gimbal_.stop();
      holdSpeed_ = false;
      running_ = false;
      break;
    case SHOT_WAIT:
    case SHOT_LOOP:
      break;
  }
}

bool ShotPlayer::load(const char* name, float timeScale) {
  const ShotStep* src = nullptr;
  size_t n = 0;

  // +dial = 줌 인(타이트), -dial = 줌 아웃(와이드). 24-70 기계줌 모터 기준.
  static const ShotStep front[] = {MZ(0, 0, 0, 1.6f, -900)};
  static const ShotStep wide[] = {MZ(0, 0, 10, 2.2f, -1100)};
  static const ShotStep tight[] = {MZ(0, 0, -8, 2.0f, 1100)};
  static const ShotStep verse[] = {MZ(0, 0, 16, 2.6f, -700)};
  static const ShotStep chorus[] = {MZ(0, 0, -6, 0.5f, 1600)};
  static const ShotStep hero[] = {MZ(0, 0, -22, 1.8f, 1000)};
  static const ShotStep high[] = {MZ(0, 0, 62, 2.0f, -900)};
  static const ShotStep hands[] = {MZ(0, 0, 72, 1.8f, 1200)};
  static const ShotStep reveal[] = {MZ(0, 0, 75, 0.4f, 800), MZ(0, 0, 0, 3.2f, -1000)};
  static const ShotStep drop[] = {MZ(0, 0, 0, 0.35f, -400), MZ(0, 0, 58, 2.4f, 1100)};
  static const ShotStep profileL[] = {MZ(-80, 0, 0, 1.8f, 600)};
  static const ShotStep profileR[] = {MZ(80, 0, 0, 1.8f, 600)};
  static const ShotStep qtrL[] = {MZ(-40, 0, -4, 1.6f, 500)};
  static const ShotStep qtrR[] = {MZ(40, 0, -4, 1.6f, 500)};
  static const ShotStep whipL[] = {MZ(-75, 0, 0, 0.28f, 0)};
  static const ShotStep whipR[] = {MZ(75, 0, 0, 0.28f, 0)};
  static const ShotStep driftL[] = {SPD(-8, 0, 0)};
  static const ShotStep driftR[] = {SPD(8, 0, 0)};
  static const ShotStep dutchL[] = {REL(0, -18, 0, 1.0f)};
  static const ShotStep dutchR[] = {REL(0, 18, 0, 1.0f)};
  static const ShotStep level[] = {MV(0, 0, 0, 1.0f)};
  static const ShotStep sway[] = {REL(-10, 0, 0, 1.5f), REL(10, 0, 0, 1.5f), LOOP};
  static const ShotStep push[] = {RZ(0, 0, -20, 3.0f, 750)};
  static const ShotStep pull[] = {RZ(0, 0, 20, 3.0f, -750)};
  static const ShotStep crash[] = {MZ(0, 0, -18, 0.45f, 1800)};
  static const ShotStep snapWide[] = {Z(-1800, 0.7f)};
  static const ShotStep snapTight[] = {Z(1800, 0.7f)};

  if (!strcmp(name, "front")) {
    src = front;
    n = 1;
  } else if (!strcmp(name, "wide")) {
    src = wide;
    n = 1;
  } else if (!strcmp(name, "tight")) {
    src = tight;
    n = 1;
  } else if (!strcmp(name, "verse")) {
    src = verse;
    n = 1;
  } else if (!strcmp(name, "chorus")) {
    src = chorus;
    n = 1;
  } else if (!strcmp(name, "hero")) {
    src = hero;
    n = 1;
  } else if (!strcmp(name, "high")) {
    src = high;
    n = 1;
  } else if (!strcmp(name, "hands")) {
    src = hands;
    n = 1;
  } else if (!strcmp(name, "reveal")) {
    src = reveal;
    n = 2;
  } else if (!strcmp(name, "drop")) {
    src = drop;
    n = 2;
  } else if (!strcmp(name, "profile-l")) {
    src = profileL;
    n = 1;
  } else if (!strcmp(name, "profile-r")) {
    src = profileR;
    n = 1;
  } else if (!strcmp(name, "qtr-l")) {
    src = qtrL;
    n = 1;
  } else if (!strcmp(name, "qtr-r")) {
    src = qtrR;
    n = 1;
  } else if (!strcmp(name, "whip-l")) {
    src = whipL;
    n = 1;
  } else if (!strcmp(name, "whip-r")) {
    src = whipR;
    n = 1;
  } else if (!strcmp(name, "drift-l")) {
    src = driftL;
    n = 1;
  } else if (!strcmp(name, "drift-r")) {
    src = driftR;
    n = 1;
  } else if (!strcmp(name, "dutch-l")) {
    src = dutchL;
    n = 1;
  } else if (!strcmp(name, "dutch-r")) {
    src = dutchR;
    n = 1;
  } else if (!strcmp(name, "level")) {
    src = level;
    n = 1;
  } else if (!strcmp(name, "sway")) {
    src = sway;
    n = 3;
  } else if (!strcmp(name, "push")) {
    src = push;
    n = 1;
  } else if (!strcmp(name, "pull")) {
    src = pull;
    n = 1;
  } else if (!strcmp(name, "crash")) {
    src = crash;
    n = 1;
  } else if (!strcmp(name, "snap-wide")) {
    src = snapWide;
    n = 1;
  } else if (!strcmp(name, "snap-tight")) {
    src = snapTight;
    n = 1;
  } else {
    return false;
  }

  copyScaled(steps_, src, n, timeScale);
  count_ = n;

  if (!strcmp(name, "level") && gimbal_.attitude().valid) {
    const DjiAttitude& a = gimbal_.attitude();
    steps_[0] = {SHOT_MOVE, a.yaw, 0, a.pitch, 1.0f * timeScale, true, 0};
    count_ = 1;
  }
  return true;
}
