# 보드 펌웨어 (앱 와이파이 OTA)

앱이 C3·S3 에 붙으면 `/version` 을 보고, `BoardOta.expectedFw` 와 다르면 여기 bin 을 `http://보드/update` 로 올립니다.

| 파일 | 슬롯 | 빌드 | fw | 크기(≤1310720) |
| --- | --- | --- | --- | --- |
| `firmware-c3-oled.bin` | oled | `c3-oled` (Arduino/-Os, U8g2 없음) | **1.0.61** | 1081856 |
| `firmware-c3-rmsid.bin` | rmsid | `c3-rmsid` | **1.0.61** | 1078448 |
| `firmware-s3-light.bin` | s3 | `s3-light` | (이전) | — |

맥미니 IDF 빌드가 칸을 넘으면, 위 bin 을 그대로 OTA 하세요(재빌드 불필요).

```bash
# 예: curl raw (브랜치 tip)
BASE=https://raw.githubusercontent.com/anyplan75/Ronin_Controller/cursor/c3-ronin-ble-6a5c/apple/RoninControl/Firmware
curl -fsSL -o firmware-c3-oled.bin  "$BASE/firmware-c3-oled.bin"
curl -fsSL -o firmware-c3-rmsid.bin "$BASE/firmware-c3-rmsid.bin"
# 보드 OTA
curl -fsS "http://192.168.10.152:80/update" -F "update=@firmware-c3-oled.bin"
curl -fsS "http://192.168.10.154:80/update" -F "update=@firmware-c3-rmsid.bin"
```

갱신(맥북 Arduino PlatformIO):

```bash
(cd esp32-c3 && pio run -e c3-oled -e c3-rmsid -e s3-light)
cp esp32-c3/.pio/build/c3-oled/firmware.bin apple/RoninControl/Firmware/firmware-c3-oled.bin
cp esp32-c3/.pio/build/c3-rmsid/firmware.bin apple/RoninControl/Firmware/firmware-c3-rmsid.bin
cp esp32-c3/.pio/build/s3-light/firmware.bin apple/RoninControl/Firmware/firmware-s3-light.bin
```
