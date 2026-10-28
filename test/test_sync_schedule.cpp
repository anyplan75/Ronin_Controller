#include "../src/sync_schedule.h"

#include <stdio.h>

static int fails = 0;

static void expect(const char* name, bool ok) {
  if (!ok) {
    printf("실패: %s\n", name);
    fails++;
  }
}

int main() {
  uint32_t fire = 0;
  bool now = false;

  expect("미래 500ms", planSyncFire(true, 1500, false, 0, 1000, &fire, &now) && !now && fire == 1500);
  expect("너무 먼 시각", !planSyncFire(true, 1000 + 10001, false, 0, 1000, &fire, &now));
  expect("200ms보다 더 늦음",
         planSyncFire(true, 1000 - 500, false, 0, 1000, &fire, &now) && now && fire == 1000);
  expect("조금 늦음", planSyncFire(true, 900, false, 0, 1000, &fire, &now) && now && fire == 900);
  expect("delay 250", planSyncFire(false, 0, true, 250, 1000, &fire, &now) && !now && fire == 1250);
  expect("시각 없음", planSyncFire(false, 0, false, 999, 1000, &fire, &now) && now && fire == 1000);
  expect("delay 음수", planSyncFire(false, 0, true, -5, 1000, &fire, &now) && now && fire == 1000);
  expect("delay 상한", planSyncFire(false, 0, true, 20000, 1000, &fire, &now) && !now && fire == 11000);
  expect("at_ms가 delay보다 우선",
         planSyncFire(true, 1300, true, 10, 1000, &fire, &now) && !now && fire == 1300);

  if (fails) {
    printf("%d개 실패\n", fails);
    return 1;
  }
  printf("동기 시각 계산 통과\n");
  return 0;
}
