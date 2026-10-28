#pragma once

#include <Arduino.h>

class SonyRemote {
 public:
  void begin();
  void loop();

  bool saveAndConnect(const String& ssid, const String& pass, const String& host);
  bool ensureReady();
  bool toggleRecord();
  bool startRecord();
  bool stopRecord();
  bool takePhoto();

  bool wifiConnected() const;
  bool recording() const { return recording_; }
  String lastError() const { return lastError_; }
  String ssid() const { return ssid_; }
  String host() const { return host_; }
  String apiList() const { return apiList_; }

 private:
  bool connectWifi();
  bool rpc(const char* method, const char* params, String* response);
  bool hasApi(const char* name) const;

  String ssid_;
  String pass_;
  String host_ = "192.168.122.1";
  String apiList_;
  String lastError_;
  bool recording_ = false;
  bool ready_ = false;
  uint32_t lastWifiAttemptMs_ = 0;
};
