# 보드 펌웨어 (앱 와이파이 OTA)

앱이 C3·S3 에 붙으면 `/version` 을 보고, `BoardOta.expectedFw` 와 다르면 여기 bin 을 `http://보드/update` 로 올립니다.

| 파일 | 슬롯 | 빌드 | fw | 크기 |
| --- | --- | --- | --- | --- |
| `firmware-c3-oled.bin` | oled | `c3-oled` | **1.0.62** | ≤1.25MB |
| `firmware-c3-rmsid.bin` | rmsid | `c3-rmsid` | **1.0.62** | ≤1.25MB |
| `firmware-s3-light.bin` | s3 | `s3-light` | **1.0.62** | (울란지 이중연결·최신값) |

올리멕스 허브도 C3·S3와 같이 와이파이 HTTP OTA(`http://192.168.10.151/update`, `/version`)를 씁니다. USB는 최초·비상만. bin은 `Firmware/firmware-olimex-hub-1.0.62.bin` 입니다.

```bash
# 예: curl raw (브랜치 tip)
BASE=https://raw.githubusercontent.com/anyplan75/Ronin_Controller/cursor/cam-light-latency-ptz-ui-c885/apple/RoninControl/Firmware
curl -fsSL -o firmware-s3-light.bin "$BASE/firmware-s3-light.bin"
curl -fsS "http://192.168.10.153:80/update" -F "update=@firmware-s3-light.bin"

HUB=https://raw.githubusercontent.com/anyplan75/Ronin_Controller/cursor/cam-light-latency-ptz-ui-c885/Firmware
curl -fsSL -o firmware-olimex-hub-1.0.62.bin "$HUB/firmware-olimex-hub-1.0.62.bin"
curl -fsS "http://192.168.10.151:80/update" -F "update=@firmware-olimex-hub-1.0.62.bin"
```
