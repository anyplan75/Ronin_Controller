# 보드 펌웨어 (앱 와이파이 OTA)

앱이 C3·S3 에 붙으면 `/version` 을 보고, `BoardOta.expectedFw` 와 다르면 여기 bin 을 `http://보드/update` 로 올립니다.

| 파일 | 슬롯 | 빌드 |
| --- | --- | --- |
| `firmware-c3-oled.bin` | oled | `esp32-c3` → `c3-oled` |
| `firmware-c3-rmsid.bin` | rmsid | `c3-rmsid` |
| `firmware-s3-light.bin` | s3 | `s3-light` |

갱신:

```bash
(cd esp32-c3 && pio run -e c3-oled -e c3-rmsid -e s3-light)
cp esp32-c3/.pio/build/c3-oled/firmware.bin apple/RoninControl/Firmware/firmware-c3-oled.bin
cp esp32-c3/.pio/build/c3-rmsid/firmware.bin apple/RoninControl/Firmware/firmware-c3-rmsid.bin
cp esp32-c3/.pio/build/s3-light/firmware.bin apple/RoninControl/Firmware/firmware-s3-light.bin
```
