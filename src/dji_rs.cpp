#include "dji_rs.h"

#include "driver/twai.h"

namespace {

constexpr uint32_t kTxId = 0x223;
constexpr uint32_t kRxId = 0x222;
constexpr uint8_t kSof = 0xAA;
constexpr uint8_t kCmdType = 0x03;
constexpr uint8_t kMinPacket = 16;
constexpr uint8_t kMaxPacket = 32;

constexpr uint16_t kCrc16Table[256] = {
    0x0000, 0xc0c1, 0xc181, 0x0140, 0xc301, 0x03c0, 0x0280, 0xc241, 0xc601, 0x06c0, 0x0780, 0xc741,
    0x0500, 0xc5c1, 0xc481, 0x0440, 0xcc01, 0x0cc0, 0x0d80, 0xcd41, 0x0f00, 0xcfc1, 0xce81, 0x0e40,
    0x0a00, 0xcac1, 0xcb81, 0x0b40, 0xc901, 0x09c0, 0x0880, 0xc841, 0xd801, 0x18c0, 0x1980, 0xd941,
    0x1b00, 0xdbc1, 0xda81, 0x1a40, 0x1e00, 0xdec1, 0xdf81, 0x1f40, 0xdd01, 0x1dc0, 0x1c80, 0xdc41,
    0x1400, 0xd4c1, 0xd581, 0x1540, 0xd701, 0x17c0, 0x1680, 0xd641, 0xd201, 0x12c0, 0x1380, 0xd341,
    0x1100, 0xd1c1, 0xd081, 0x1040, 0xf001, 0x30c0, 0x3180, 0xf141, 0x3300, 0xf3c1, 0xf281, 0x3240,
    0x3600, 0xf6c1, 0xf781, 0x3740, 0xf501, 0x35c0, 0x3480, 0xf441, 0x3c00, 0xfcc1, 0xfd81, 0x3d40,
    0xff01, 0x3fc0, 0x3e80, 0xfe41, 0xfa01, 0x3ac0, 0x3b80, 0xfb41, 0x3900, 0xf9c1, 0xf881, 0x3840,
    0x2800, 0xe8c1, 0xe981, 0x2940, 0xeb01, 0x2bc0, 0x2a80, 0xea41, 0xee01, 0x2ec0, 0x2f80, 0xef41,
    0x2d00, 0xedc1, 0xec81, 0x2c40, 0xe401, 0x24c0, 0x2580, 0xe541, 0x2700, 0xe7c1, 0xe681, 0x2640,
    0x2200, 0xe2c1, 0xe381, 0x2340, 0xe101, 0x21c0, 0x2080, 0xe041, 0xa001, 0x60c0, 0x6180, 0xa141,
    0x6300, 0xa3c1, 0xa281, 0x6240, 0x6600, 0xa6c1, 0xa781, 0x6740, 0xa501, 0x65c0, 0x6480, 0xa441,
    0x6c00, 0xacc1, 0xad81, 0x6d40, 0xaf01, 0x6fc0, 0x6e80, 0xae41, 0xaa01, 0x6ac0, 0x6b80, 0xab41,
    0x6900, 0xa9c1, 0xa881, 0x6840, 0x7800, 0xb8c1, 0xb981, 0x7940, 0xbb01, 0x7bc0, 0x7a80, 0xba41,
    0xbe01, 0x7ec0, 0x7f80, 0xbf41, 0x7d00, 0xbdc1, 0xbc81, 0x7c40, 0xb401, 0x74c0, 0x7580, 0xb541,
    0x7700, 0xb7c1, 0xb681, 0x7640, 0x7200, 0xb2c1, 0xb381, 0x7340, 0xb101, 0x71c0, 0x7080, 0xb041,
    0x5000, 0x90c1, 0x9181, 0x5140, 0x9301, 0x53c0, 0x5280, 0x9241, 0x9601, 0x56c0, 0x5780, 0x9741,
    0x5500, 0x95c1, 0x9481, 0x5440, 0x9c01, 0x5cc0, 0x5d80, 0x9d41, 0x5f00, 0x9fc1, 0x9e81, 0x5e40,
    0x5a00, 0x9ac1, 0x9b81, 0x5b40, 0x9901, 0x59c0, 0x5880, 0x9841, 0x8801, 0x48c0, 0x4980, 0x8941,
    0x4b00, 0x8bc1, 0x8a81, 0x4a40, 0x4e00, 0x8ec1, 0x8f81, 0x4f40, 0x8d01, 0x4dc0, 0x4c80, 0x8c41,
    0x4400, 0x84c1, 0x8581, 0x4540, 0x8701, 0x47c0, 0x4680, 0x8641, 0x8201, 0x42c0, 0x4380, 0x8341,
    0x4100, 0x81c1, 0x8081, 0x4040};

constexpr uint32_t kCrc32Table[256] = {
    0x00000000, 0x77073096, 0xee0e612c, 0x990951ba, 0x076dc419, 0x706af48f, 0xe963a535, 0x9e6495a3,
    0x0edb8832, 0x79dcb8a4, 0xe0d5e91e, 0x97d2d988, 0x09b64c2b, 0x7eb17cbd, 0xe7b82d07, 0x90bf1d91,
    0x1db71064, 0x6ab020f2, 0xf3b97148, 0x84be41de, 0x1adad47d, 0x6ddde4eb, 0xf4d4b551, 0x83d385c7,
    0x136c9856, 0x646ba8c0, 0xfd62f97a, 0x8a65c9ec, 0x14015c4f, 0x63066cd9, 0xfa0f3d63, 0x8d080df5,
    0x3b6e20c8, 0x4c69105e, 0xd56041e4, 0xa2677172, 0x3c03e4d1, 0x4b04d447, 0xd20d85fd, 0xa50ab56b,
    0x35b5a8fa, 0x42b2986c, 0xdbbbc9d6, 0xacbcf940, 0x32d86ce3, 0x45df5c75, 0xdcd60dcf, 0xabd13d59,
    0x26d930ac, 0x51de003a, 0xc8d75180, 0xbfd06116, 0x21b4f4b5, 0x56b3c423, 0xcfba9599, 0xb8bda50f,
    0x2802b89e, 0x5f058808, 0xc60cd9b2, 0xb10be924, 0x2f6f7c87, 0x58684c11, 0xc1611dab, 0xb6662d3d,
    0x76dc4190, 0x01db7106, 0x98d220bc, 0xefd5102a, 0x71b18589, 0x06b6b51f, 0x9fbfe4a5, 0xe8b8d433,
    0x7807c9a2, 0x0f00f934, 0x9609a88e, 0xe10e9818, 0x7f6a0dbb, 0x086d3d2d, 0x91646c97, 0xe6635c01,
    0x6b6b51f4, 0x1c6c6162, 0x856530d8, 0xf262004e, 0x6c0695ed, 0x1b01a57b, 0x8208f4c1, 0xf50fc457,
    0x65b0d9c6, 0x12b7e950, 0x8bbeb8ea, 0xfcb9887c, 0x62dd1ddf, 0x15da2d49, 0x8cd37cf3, 0xfbd44c65,
    0x4db26158, 0x3ab551ce, 0xa3bc0074, 0xd4bb30e2, 0x4adfa541, 0x3dd895d7, 0xa4d1c46d, 0xd3d6f4fb,
    0x4369e96a, 0x346ed9fc, 0xad678846, 0xda60b8d0, 0x44042d73, 0x33031de5, 0xaa0a4c5f, 0xdd0d7cc9,
    0x5005713c, 0x270241aa, 0xbe0b1010, 0xc90c2086, 0x5768b525, 0x206f85b3, 0xb966d409, 0xce61e49f,
    0x5edef90e, 0x29d9c998, 0xb0d09822, 0xc7d7a8b4, 0x59b33d17, 0x2eb40d81, 0xb7bd5c3b, 0xc0ba6cad,
    0xedb88320, 0x9abfb3b6, 0x03b6e20c, 0x74b1d29a, 0xead54739, 0x9dd277af, 0x04db2615, 0x73dc1683,
    0xe3630b12, 0x94643b84, 0x0d6d6a3e, 0x7a6a5aa8, 0xe40ecf0b, 0x9309ff9d, 0x0a00ae27, 0x7d079eb1,
    0xf00f9344, 0x8708a3d2, 0x1e01f268, 0x6906c2fe, 0xf762575d, 0x806567cb, 0x196c3671, 0x6e6b06e7,
    0xfed41b76, 0x89d32be0, 0x10da7a5a, 0x67dd4acc, 0xf9b9df6f, 0x8ebeeff9, 0x17b7be43, 0x60b08ed5,
    0xd6d6a3e8, 0xa1d1937e, 0x38d8c2c4, 0x4fdff252, 0xd1bb67f1, 0xa6bc5767, 0x3fb506dd, 0x48b2364b,
    0xd80d2bda, 0xaf0a1b4c, 0x36034af6, 0x41047a60, 0xdf60efc3, 0xa867df55, 0x316e8eef, 0x4669be79,
    0xcb61b38c, 0xbc66831a, 0x256fd2a0, 0x5268e236, 0xcc0c7795, 0xbb0b4703, 0x220216b9, 0x5505262f,
    0xc5ba3bbe, 0xb2bd0b28, 0x2bb45a92, 0x5cb36a04, 0xc2d7ffa7, 0xb5d0cf31, 0x2cd99e8b, 0x5bdeae1d,
    0x9b64c2b0, 0xec63f226, 0x756aa39c, 0x026d930a, 0x9c0906a9, 0xeb0e363f, 0x72076785, 0x05005713,
    0x95bf4a82, 0xe2b87a14, 0x7bb12bae, 0x0cb61b38, 0x92d28e9b, 0xe5d5be0d, 0x7cdcefb7, 0x0bdbdf21,
    0x86d3d2d4, 0xf1d4e242, 0x68ddb3f8, 0x1fda836e, 0x81be16cd, 0xf6b9265b, 0x6fb077e1, 0x18b74777,
    0x88085ae6, 0xff0f6a70, 0x66063bca, 0x11010b5c, 0x8f659eff, 0xf862ae69, 0x616bffd3, 0x166ccf45,
    0xa00ae278, 0xd70dd2ee, 0x4e048354, 0x3903b3c2, 0xa7672661, 0xd06016f7, 0x4969474d, 0x3e6e77db,
    0xaed16a4a, 0xd9d65adc, 0x40df0b66, 0x37d83bf0, 0xa9bcae53, 0xdebb9ec5, 0x47b2cf7f, 0x30b5ffe9,
    0xbdbdf21c, 0xcabac28a, 0x53b39330, 0x24b4a3a6, 0xbad03605, 0xcdd70693, 0x54de5729, 0x23d967bf,
    0xb3667a2e, 0xc4614ab8, 0x5d681b02, 0x2a6f2b94, 0xb40bbe37, 0xc30c8ea1, 0x5a05df1b, 0x2d02ef8d};

uint16_t crc16(const uint8_t* data, size_t len) {
  uint16_t crc = 0x3AA3;
  for (size_t i = 0; i < len; i++) {
    crc = ((crc >> 8) & 0xFF) ^ kCrc16Table[(crc ^ data[i]) & 0xFF];
  }
  return crc;
}

uint32_t crc32(const uint8_t* data, size_t len) {
  uint32_t crc = 0x3AA3;
  for (size_t i = 0; i < len; i++) {
    crc = ((crc >> 8) & 0x00FFFFFF) ^ kCrc32Table[(crc ^ data[i]) & 0xFF];
  }
  return crc;
}

int16_t readI16(const uint8_t* p) {
  return static_cast<int16_t>(p[0] | (static_cast<uint16_t>(p[1]) << 8));
}

void writeI16(uint8_t* p, int16_t value) {
  p[0] = static_cast<uint8_t>(value);
  p[1] = static_cast<uint8_t>(value >> 8);
}

}  // namespace

bool DjiRs::begin(int txPin, int rxPin) {
  twai_general_config_t g_config =
      TWAI_GENERAL_CONFIG_DEFAULT(static_cast<gpio_num_t>(txPin), static_cast<gpio_num_t>(rxPin),
                                  TWAI_MODE_NORMAL);
  g_config.tx_queue_len = 8;
  g_config.rx_queue_len = 32;

  twai_timing_config_t t_config = TWAI_TIMING_CONFIG_1MBITS();
  twai_filter_config_t f_config = TWAI_FILTER_CONFIG_ACCEPT_ALL();

  if (twai_driver_install(&g_config, &t_config, &f_config) != ESP_OK) {
    Serial.println("TWAI driver_install 실패");
    return false;
  }
  if (twai_start() != ESP_OK) {
    Serial.println("TWAI start 실패");
    return false;
  }
  Serial.printf("CAN 1Mbps 시작 TX=GPIO%d RX=GPIO%d (DJI 0x223/0x222)\n", txPin, rxPin);
  return true;
}

void DjiRs::loop() {
  twai_status_info_t info;
  if (twai_get_status_info(&info) == ESP_OK && info.state == TWAI_STATE_BUS_OFF) {
    twai_initiate_recovery();
  }

  twai_message_t msg;
  while (twai_receive(&msg, 0) == ESP_OK) {
    if (msg.rtr) {
      continue;
    }
    if (listening()) {
      logFrame("RX", msg.identifier, msg.data, msg.data_length_code);
    }
    if (msg.extd || msg.identifier != kRxId) {
      continue;
    }
    for (int i = 0; i < msg.data_length_code; i++) {
      parseByte(msg.data[i]);
    }
  }
}

void DjiRs::startListen(uint32_t durationMs) {
  listenUntilMs_ = millis() + durationMs;
  Serial.printf("CAN listen %lu초. 로닌 녹화 버튼을 누르세요. 프레임이 없으면 그 버튼은 RSA CAN을 안 씁니다.\n",
                durationMs / 1000);
}

bool DjiRs::listening() const {
  return listenUntilMs_ != 0 && millis() < listenUntilMs_;
}

void DjiRs::logFrame(const char* dir, uint32_t id, const uint8_t* data, uint8_t dlc) {
  Serial.printf("CAN %s id=0x%03X dlc=%u", dir, id, dlc);
  for (uint8_t i = 0; i < dlc; i++) {
    Serial.printf(" %02X", data[i]);
  }
  Serial.println();
}

int16_t DjiRs::toDecideg(float deg, int16_t minV, int16_t maxV) {
  int32_t value = lroundf(deg * 10.0f);
  if (value < minV) {
    value = minV;
  }
  if (value > maxV) {
    value = maxV;
  }
  return static_cast<int16_t>(value);
}

uint8_t DjiRs::toTimeTenth(float timeSec) {
  if (timeSec < 0.1f) {
    timeSec = 0.1f;
  }
  if (timeSec > 25.0f) {
    timeSec = 25.0f;
  }
  return static_cast<uint8_t>(lroundf(timeSec * 10.0f));
}

bool DjiRs::sendPacket(const uint8_t* data, size_t len) {
  lastSendOk_ = true;
  size_t offset = 0;
  while (offset < len) {
    twai_message_t msg = {};
    msg.identifier = kTxId;
    msg.extd = 0;
    msg.rtr = 0;
    msg.data_length_code = static_cast<uint8_t>(min(len - offset, static_cast<size_t>(8)));
    memcpy(msg.data, data + offset, msg.data_length_code);
    if (twai_transmit(&msg, pdMS_TO_TICKS(20)) != ESP_OK) {
      stats_.txFails++;
      lastSendOk_ = false;
      static uint32_t lastFailMs = 0;
      if (millis() - lastFailMs > 2000) {
        lastFailMs = millis();
        Serial.println("CAN 송신 실패 (RSA CANH/CANL/GND, 짐벌 전원 확인)");
      }
      return false;
    }
    stats_.txFrames++;
    if (listening()) {
      logFrame("TX", msg.identifier, msg.data, msg.data_length_code);
    }
    offset += msg.data_length_code;
  }
  return true;
}

bool DjiRs::sendCommand(uint8_t cmdSet, uint8_t cmdId, const uint8_t* payload, size_t payloadLen) {
  const uint16_t total = static_cast<uint16_t>(12 + 2 + payloadLen + 4);
  if (total > kMaxPacket) {
    return false;
  }

  uint8_t pkt[kMaxPacket] = {};
  pkt[0] = kSof;
  pkt[1] = static_cast<uint8_t>(total);
  pkt[2] = static_cast<uint8_t>(total >> 8);
  pkt[3] = kCmdType;
  seq_++;
  pkt[8] = static_cast<uint8_t>(seq_);
  pkt[9] = static_cast<uint8_t>(seq_ >> 8);

  const uint16_t headerCrc = crc16(pkt, 10);
  pkt[10] = static_cast<uint8_t>(headerCrc);
  pkt[11] = static_cast<uint8_t>(headerCrc >> 8);
  pkt[12] = cmdSet;
  pkt[13] = cmdId;
  if (payloadLen > 0) {
    memcpy(pkt + 14, payload, payloadLen);
  }

  const uint32_t frameCrc = crc32(pkt, total - 4);
  pkt[total - 4] = static_cast<uint8_t>(frameCrc);
  pkt[total - 3] = static_cast<uint8_t>(frameCrc >> 8);
  pkt[total - 2] = static_cast<uint8_t>(frameCrc >> 16);
  pkt[total - 1] = static_cast<uint8_t>(frameCrc >> 24);
  return sendPacket(pkt, total);
}

bool DjiRs::moveTo(float yawDeg, float rollDeg, float pitchDeg, float timeSec, bool absolute) {
  uint8_t payload[8];
  writeI16(payload + 0, toDecideg(yawDeg, -1800, 1800));
  writeI16(payload + 2, toDecideg(rollDeg, -300, 300));
  writeI16(payload + 4, toDecideg(pitchDeg, -560, 1460));
  payload[6] = absolute ? 0x01 : 0x00;
  payload[7] = toTimeTenth(timeSec);
  Serial.printf("MOVE %s yaw=%.1f roll=%.1f pitch=%.1f t=%.1fs\n", absolute ? "ABS" : "REL",
                yawDeg, rollDeg, pitchDeg, timeSec);
  return sendCommand(0x0E, 0x00, payload, sizeof(payload));
}

bool DjiRs::setSpeed(float yawDps, float rollDps, float pitchDps) {
  uint8_t payload[7];
  writeI16(payload + 0, toDecideg(yawDps, -3600, 3600));
  writeI16(payload + 2, toDecideg(rollDps, -3600, 3600));
  writeI16(payload + 4, toDecideg(pitchDps, -3600, 3600));
  payload[6] = 0x88;
  Serial.printf("SPEED yaw=%.1f roll=%.1f pitch=%.1f\n", yawDps, rollDps, pitchDps);
  return sendCommand(0x0E, 0x01, payload, sizeof(payload));
}

bool DjiRs::stop() {
  setDial(0);
  return setSpeed(0, 0, 0);
}

bool DjiRs::requestAttitude() {
  const uint8_t payload[] = {0x01};
  return sendCommand(0x0E, 0x02, payload, 1);
}

bool DjiRs::setDial(int16_t speed) {
  if (speed < -2048) {
    speed = -2048;
  }
  if (speed > 2048) {
    speed = 2048;
  }
  uint8_t payload[3];
  payload[0] = 0x02;
  writeI16(payload + 1, speed);
  Serial.printf("DIAL %d\n", speed);
  return sendCommand(0x0E, 0x0A, payload, sizeof(payload));
}

bool DjiRs::cameraAction(uint16_t action) {
  uint8_t payload[2];
  payload[0] = static_cast<uint8_t>(action);
  payload[1] = static_cast<uint8_t>(action >> 8);
  Serial.printf("CAM 0x%04X\n", action);
  return sendCommand(0x0D, 0x00, payload, sizeof(payload));
}

void DjiRs::parseByte(uint8_t b) {
  stats_.rxBytes++;

  if (parseState_ == WAIT_SOF) {
    parseCount_ = 0;
    if (b != kSof) {
      return;
    }
    parseBuf_[parseCount_++] = b;
    parseState_ = WAIT_LEN;
    return;
  }

  if (parseCount_ >= sizeof(parseBuf_)) {
    parseState_ = WAIT_SOF;
    stats_.parseErrors++;
    return;
  }
  parseBuf_[parseCount_++] = b;

  if (parseState_ == WAIT_LEN && parseCount_ >= 3) {
    parseLen_ = static_cast<uint16_t>(parseBuf_[1] | ((parseBuf_[2] & 0x03) << 8));
    if (parseLen_ < kMinPacket || parseLen_ > kMaxPacket) {
      parseState_ = WAIT_SOF;
      stats_.parseErrors++;
      return;
    }
    parseState_ = WAIT_BODY;
  }

  if (parseState_ == WAIT_BODY && parseCount_ >= parseLen_) {
    handlePacket();
    parseState_ = WAIT_SOF;
  }
}

void DjiRs::handlePacket() {
  const uint16_t expect16 = crc16(parseBuf_, 10);
  const uint16_t got16 = static_cast<uint16_t>(parseBuf_[10] | (parseBuf_[11] << 8));
  if (expect16 != got16) {
    stats_.parseErrors++;
    return;
  }

  const uint32_t expect32 = crc32(parseBuf_, parseLen_ - 4);
  const uint32_t got32 = static_cast<uint32_t>(parseBuf_[parseLen_ - 4]) |
                         (static_cast<uint32_t>(parseBuf_[parseLen_ - 3]) << 8) |
                         (static_cast<uint32_t>(parseBuf_[parseLen_ - 2]) << 16) |
                         (static_cast<uint32_t>(parseBuf_[parseLen_ - 1]) << 24);
  if (expect32 != got32) {
    stats_.parseErrors++;
    return;
  }

  stats_.replies++;
  if ((parseBuf_[3] & 0x20) == 0) {
    return;
  }

  // 0x0E/0x02 attitude reply: legacy 24B or latest 26B
  if (parseLen_ >= 24) {
    const bool latest = parseLen_ >= 26;
    const uint8_t retCode = latest ? parseBuf_[14] : parseBuf_[12];
    if (retCode != 0x00) {
      return;
    }
    const uint8_t* yawP = latest ? parseBuf_ + 16 : parseBuf_ + 14;
    const uint8_t* rollP = latest ? parseBuf_ + 18 : parseBuf_ + 18;
    const uint8_t* pitchP = latest ? parseBuf_ + 20 : parseBuf_ + 16;
    attitude_.yaw = readI16(yawP) * 0.1f;
    attitude_.roll = readI16(rollP) * 0.1f;
    attitude_.pitch = readI16(pitchP) * 0.1f;
    attitude_.updatedMs = millis();
    attitude_.valid = true;
  }
}

const char* DjiRs::twaiState() const {
  twai_status_info_t info;
  if (twai_get_status_info(&info) != ESP_OK) {
    return "unknown";
  }
  switch (info.state) {
    case TWAI_STATE_STOPPED:
      return "stopped";
    case TWAI_STATE_RUNNING:
      return "running";
    case TWAI_STATE_BUS_OFF:
      return "bus_off";
    case TWAI_STATE_RECOVERING:
      return "recovering";
    default:
      return "other";
  }
}

uint32_t DjiRs::txErrorCounter() const {
  twai_status_info_t info;
  return twai_get_status_info(&info) == ESP_OK ? info.tx_error_counter : 0;
}

uint32_t DjiRs::rxErrorCounter() const {
  twai_status_info_t info;
  return twai_get_status_info(&info) == ESP_OK ? info.rx_error_counter : 0;
}
