#include <stdio.h>
#include <string.h>

#include "../src/gopro_relay/gopro_ble_frame.h"

static int fails = 0;

static void expect(bool ok, const char* name) {
  if (!ok) {
    printf("실패: %s\n", name);
    fails += 1;
  }
}

int main() {
  GoproBytes frame;
  const uint8_t banned[4] = {0x03, 0x01, 0x01, 0x01};

  expect(goproShutterFrame(true, &frame), "시작 프레임");
  expect(frame.length == 5, "시작 길이");
  expect(frame.data[0] == 0x20 && frame.data[1] == 0x03, "13비트 헤더");
  expect(frame.data[2] == 0x01 && frame.data[3] == 0x01 && frame.data[4] == 0x01, "TLV 본문");
  expect(!(frame.length == 4 && memcmp(frame.data, banned, 4) == 0), "옛 4바이트가 아님");

  expect(goproShutterFrame(false, &frame), "정지 프레임");
  expect(frame.data[4] == 0x00, "정지 값");

  expect(goproKeepAliveFrame(&frame), "유지");
  expect(frame.length == 3 && frame.data[0] == 0x20 && frame.data[1] == 0x01 && frame.data[2] == 0x5B,
         "유지 바이트");

  expect(goproSettingFrame(2, 9, &frame), "설정");
  expect(frame.length == 5 && frame.data[2] == 2 && frame.data[3] == 1 && frame.data[4] == 9, "설정 본문");

  GoproAssembler rx;
  goproAssemblerReset(&rx);
  bool done = false;
  const uint8_t response[] = {0x20, 0x02, 0x01, 0x00};
  expect(goproAssemblerPush(&rx, response, 4, &done) && done, "응답 조립");
  expect(rx.payloadLen == 2 && rx.payload[0] == 0x01 && rx.payload[1] == 0x00, "성공 상태");

  if (fails) {
    printf("고프로 프레임 %d건 실패\n", fails);
    return 1;
  }
  printf("고프로 프레임 통과\n");
  return 0;
}
