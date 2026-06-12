// ═══════════════════════════════════════════════════════════════
// AuTOMATO — ESP32 Greenhouse Firmware (v2.0.0)
//
// Talks to the AuTOMATO Flutter app via Firebase Realtime Database.
// This version aligns the firmware with the app's data contract:
//
//   • Timestamps are MILLISECONDS (app uses fromMillisecondsSinceEpoch)
//   • Device control: reads /commands/{id}, drives relays, writes
//     /devices/{id} state, and ACKs commands
//   • Local automation for devices in "auto" mode
//   • Alert generation to /alerts (create on breach, resolve on recovery)
//   • Seeds /config/sensors + /config/automationRules once on boot
//   • Always writes /sensors/{id}/value (so the app never null-crashes)
//
// Libraries: WiFi, FirebaseESP32 (Mobizt), Adafruit_BME280, BH1750,
//            NTPClient, WiFiUdp, ArduinoJson
// ═══════════════════════════════════════════════════════════════

#include <WiFi.h>
#include <FirebaseESP32.h>
#include <Wire.h>
#include <Adafruit_BME280.h>
#include <BH1750.h>
#include <NTPClient.h>
#include <WiFiUdp.h>

#include "secrets.h"   // WIFI_SSID, WIFI_PASSWORD, DATABASE_URL, DATABASE_SECRET

// ── Analog pin assignments ────────────────────────────────────
#define PIN_PH          34
#define PIN_TDS         35
#define PIN_MOISTURE    32

// ── Relay GPIOs (one per actuator) ────────────────────────────
// Avoid 34/35/32 (analog in) and 21/22 (I2C). Adjust to your wiring.
#define RELAY_EXHAUST_FAN     25
#define RELAY_CIRC_FAN_1      26
#define RELAY_CIRC_FAN_2      27
#define RELAY_PUMP            14
#define RELAY_GROW_LIGHT      13
// Most relay modules are active-LOW (LOW = ON). Set false if active-HIGH.
#define RELAY_ACTIVE_LOW      true

// ── Calibration — adjust after physical calibration ───────────
#define PH_OFFSET       0.0f
#define MOISTURE_AIR    2800    // raw ADC in open air (dry)
#define MOISTURE_WATER  1200    // raw ADC submerged (wet)

// ── Timing ────────────────────────────────────────────────────
#define UPLOAD_INTERVAL_MS   5000    // sensor read + device sync cadence
#define HISTORY_INTERVAL_MS  60000   // log /history at most once a minute

// ── Disconnection thresholds (analog) ─────────────────────────
#define DISCONNECTED_LOW     100
#define DISCONNECTED_HIGH    4000
#define DISCONNECT_THRESHOLD 3

// ── Valid ranges (digital sensors) ────────────────────────────
#define TEMP_MIN_VALID      -50.0f
#define TEMP_MAX_VALID      100.0f
#define HUMIDITY_MIN_VALID  0.0f
#define HUMIDITY_MAX_VALID  100.0f
#define LUX_MIN_VALID       0.0f

#define FW_VERSION          "2.0.0"

// ─────────────────────────────────────────────────────────────
FirebaseData   fbData;     // used for all reads/writes in loop()
FirebaseAuth   fbAuth;
FirebaseConfig fbConfig;

Adafruit_BME280 bme;
BH1750          lightMeter;

WiFiUDP   ntpUDP;
NTPClient timeClient(ntpUDP, "pool.ntp.org", 28800, 60000);  // UTC+8

unsigned long lastUpload  = 0;
unsigned long lastHistory = 0;

int moistureDisconnectCount = 0;
int phDisconnectCount       = 0;
int tdsDisconnectCount      = 0;

// ─────────────────────────────────────────────────────────────
// SENSOR METADATA (mirrors the Flutter app's mock config so the
// dashboard shows identical labels / ranges / thresholds).
// ─────────────────────────────────────────────────────────────
struct SensorMeta {
  const char* id;
  const char* label;
  const char* unit;
  float min;
  float max;
  float warningLow;
  float warningHigh;
  const char* icon;
};

const SensorMeta SENSORS[] = {
  {"temperature", "Air Temperature",    "°C",    20,   40,    24,    28,    "thermostat"},
  {"humidity",    "Relative Humidity",  "%",     40,   100,   50,    75,    "water_drop"},
  {"light",       "Light Intensity",    "lux",   0,    25000, 10000, 20000, "wb_sunny"},
  {"moisture",    "Substrate Moisture", "%",     0,    100,   60,    90,    "grass"},
  {"ph",          "Nutrient pH",        "pH",    4.0,  9.0,   5.5,   7.0,   "science"},
  {"ec",          "Nutrient EC",        "mS/cm", 0.5,  4.0,   1.2,   2.5,   "bolt"},
};
const int SENSOR_COUNT = sizeof(SENSORS) / sizeof(SENSORS[0]);

int sensorIndex(const char* id) {
  for (int i = 0; i < SENSOR_COUNT; i++)
    if (strcmp(SENSORS[i].id, id) == 0) return i;
  return -1;
}

// ─────────────────────────────────────────────────────────────
// DEVICE TABLE (mirrors the app's mock devices + relay wiring).
// mode: 0 = auto, 1 = manual_on, 2 = manual_off
// ─────────────────────────────────────────────────────────────
struct Device {
  const char* id;
  const char* label;
  const char* icon;
  int   relayPin;
  bool  isOn;          // current physical state
  int   mode;          // 0 auto / 1 manual_on / 2 manual_off
  const char* reason;  // last trigger reason
};

Device DEVICES[] = {
  {"exhaust_fan",       "Exhaust Fan",       "air",        RELAY_EXHAUST_FAN, false, 0, "Auto"},
  {"circulation_fan_1", "Circulation Fan 1", "cyclone",    RELAY_CIRC_FAN_1,  false, 0, "Auto"},
  {"circulation_fan_2", "Circulation Fan 2", "cyclone",    RELAY_CIRC_FAN_2,  false, 0, "Auto"},
  {"pump",              "Submersible Pump",  "water",      RELAY_PUMP,        false, 0, "Auto"},
  {"grow_light",        "LED Grow Light",    "light_mode", RELAY_GROW_LIGHT,  false, 0, "Auto"},
};
const int DEVICE_COUNT = sizeof(DEVICES) / sizeof(DEVICES[0]);

int deviceIndex(const char* id) {
  for (int i = 0; i < DEVICE_COUNT; i++)
    if (strcmp(DEVICES[i].id, id) == 0) return i;
  return -1;
}

// Latest sensor values (for automation + alert evaluation).
// Indexed to match SENSORS[]. NAN = unknown/disconnected.
float latestValue[8];
bool  latestValid[8];

// Active (unresolved) alert push-keys, one slot per sensor (-1 = none).
String activeAlertKey[8];

// ─────────────────────────────────────────────────────────────
// TIME HELPERS — everything in milliseconds
// ─────────────────────────────────────────────────────────────
double nowMillis() {
  // epoch seconds (from NTP) → ms as double (avoids 32-bit int overflow)
  return (double)timeClient.getEpochTime() * 1000.0;
}

void writeMs(const String& path, double ms) {
  // RTDB stores it as a number; the app reads it via
  // DateTime.fromMillisecondsSinceEpoch(...).
  Firebase.setDouble(fbData, path, ms);
}

void relayWrite(int pin, bool on) {
  bool level = RELAY_ACTIVE_LOW ? !on : on;
  digitalWrite(pin, level ? HIGH : LOW);
}

// ─────────────────────────────────────────────────────────────
// SETUP
// ─────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  Wire.begin(21, 22);

  // ── Relays default OFF ──────────────────────────────────────
  for (int i = 0; i < DEVICE_COUNT; i++) {
    pinMode(DEVICES[i].relayPin, OUTPUT);
    relayWrite(DEVICES[i].relayPin, false);
  }

  // ── Sensors ────────────────────────────────────────────────
  if (!bme.begin(0x76) && !bme.begin(0x77)) {
    Serial.println("BME280 not found — continuing, will report disconnected.");
  } else {
    Serial.println("BME280 OK");
  }
  if (!lightMeter.begin(BH1750::CONTINUOUS_HIGH_RES_MODE)) {
    Serial.println("BH1750 not found — continuing, will report disconnected.");
  } else {
    Serial.println("BH1750 OK");
  }

  analogReadResolution(12);
  analogSetAttenuation(ADC_11db);

  for (int i = 0; i < 8; i++) { latestValid[i] = false; activeAlertKey[i] = ""; }

  // ── WiFi ───────────────────────────────────────────────────
  Serial.print("Connecting to WiFi");
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  while (WiFi.status() != WL_CONNECTED) { delay(500); Serial.print("."); }
  Serial.println("\nWiFi connected: " + WiFi.localIP().toString());

  // ── NTP (with timeout so boot can't hang forever) ──────────
  timeClient.begin();
  timeClient.setTimeOffset(28800);
  Serial.print("Syncing NTP");
  unsigned long ntpStart = millis();
  while (!timeClient.update() && millis() - ntpStart < 15000) {
    delay(500); Serial.print(".");
  }
  Serial.println(timeClient.getEpochTime() > 100000 ? "\nNTP synced" : "\nNTP timeout (continuing)");

  // ── Firebase ───────────────────────────────────────────────
  fbConfig.database_url = DATABASE_URL;
  fbConfig.signer.tokens.legacy_token = DATABASE_SECRET;
  Firebase.begin(&fbConfig, &fbAuth);
  Firebase.reconnectWiFi(true);
  fbData.setResponseSize(4096);
  Serial.println("Firebase connected");

  seedConfig();          // /config/sensors + /config/automationRules (once)
  seedDevices();         // initial /devices/{id} state

  // ── Initial heartbeat ──────────────────────────────────────
  writeMs("/system/lastSeen", nowMillis());
  Firebase.setString(fbData, "/system/firmwareVersion", FW_VERSION);
}

// ─────────────────────────────────────────────────────────────
// LOOP
// ─────────────────────────────────────────────────────────────
void loop() {
  if (millis() - lastUpload < UPLOAD_INTERVAL_MS) return;
  lastUpload = millis();

  timeClient.update();
  double ms = nowMillis();
  bool logHistory = (millis() - lastHistory >= HISTORY_INTERVAL_MS);
  if (logHistory) lastHistory = millis();

  readSensors(ms, logHistory);   // also updates latestValue[] + alerts
  syncDevices(ms);               // apply /commands, run automation, write /devices

  // ── Heartbeat ──────────────────────────────────────────────
  writeMs("/system/lastSeen", ms);

  Serial.println("---- cycle done ----");
}

// ═════════════════════════════════════════════════════════════
// SENSORS
// ═════════════════════════════════════════════════════════════
void readSensors(double ms, bool logHistory) {
  // ── BME280: temperature + humidity ─────────────────────────
  float temperature = bme.readTemperature();
  float humidity    = bme.readHumidity();
  bool bmeOk = (!isnan(temperature) && !isnan(humidity) &&
                temperature > TEMP_MIN_VALID && temperature < TEMP_MAX_VALID &&
                humidity > HUMIDITY_MIN_VALID && humidity < HUMIDITY_MAX_VALID);
  pushSensor("temperature", temperature, bmeOk, ms, logHistory);
  pushSensor("humidity",    humidity,    bmeOk, ms, logHistory);

  // ── BH1750: light ──────────────────────────────────────────
  float lux = lightMeter.readLightLevel();
  bool lightOk = (!isnan(lux) && lux >= LUX_MIN_VALID);
  pushSensor("light", lux, lightOk, ms, logHistory);

  // ── Soil moisture (hysteresis) ─────────────────────────────
  int rawMoist = analogRead(PIN_MOISTURE);
  bool moistRaw = (rawMoist > DISCONNECTED_LOW && rawMoist < DISCONNECTED_HIGH);
  if (moistRaw) {
    if (moistureDisconnectCount > 0) moistureDisconnectCount--;
    float pct = constrain((float)map(rawMoist, MOISTURE_AIR, MOISTURE_WATER, 0, 100), 0.0f, 100.0f);
    pushSensor("moisture", pct, true, ms, logHistory);
  } else if (++moistureDisconnectCount >= DISCONNECT_THRESHOLD) {
    pushSensor("moisture", latestValue[sensorIndex("moisture")], false, ms, logHistory);
  }

  // ── pH (averaged + hysteresis) ─────────────────────────────
  int rawPH = readAnalogAvg(PIN_PH);
  bool phRaw = (rawPH > DISCONNECTED_LOW && rawPH < DISCONNECTED_HIGH);
  if (phRaw) {
    if (phDisconnectCount > 0) phDisconnectCount--;
    float voltage = rawPH * (3.3f / 4095.0f);
    float ph = constrain(3.5f * voltage + PH_OFFSET, 0.0f, 14.0f);
    pushSensor("ph", ph, true, ms, logHistory);
  } else if (++phDisconnectCount >= DISCONNECT_THRESHOLD) {
    pushSensor("ph", latestValue[sensorIndex("ph")], false, ms, logHistory);
  }

  // ── TDS → EC (averaged + hysteresis) ───────────────────────
  int rawTDS = readAnalogAvg(PIN_TDS);
  bool tdsRaw = (rawTDS > DISCONNECTED_LOW && rawTDS < DISCONNECTED_HIGH);
  if (tdsRaw) {
    if (tdsDisconnectCount > 0) tdsDisconnectCount--;
    float v = rawTDS * (3.3f / 4095.0f);
    float tds = (133.42f*v*v*v - 255.86f*v*v + 857.39f*v) * 0.5f; // ppm
    float ec = constrain(tds / 1000.0f, 0.0f, 5.0f);              // mS/cm (calibrate!)
    pushSensor("ec", ec, true, ms, logHistory);
  } else if (++tdsDisconnectCount >= DISCONNECT_THRESHOLD) {
    pushSensor("ec", latestValue[sensorIndex("ec")], false, ms, logHistory);
  }
}

int readAnalogAvg(int pin) {
  long sum = 0;
  for (int i = 0; i < 10; i++) { sum += analogRead(pin); delay(10); }
  return (int)(sum / 10);
}

// Writes /sensors/{id} = {value, timestamp(ms), connected}, optionally /history,
// updates latestValue[] and evaluates alerts.
void pushSensor(const char* id, float value, bool connected, double ms, bool logHistory) {
  int idx = sensorIndex(id);
  if (idx < 0) return;

  // Always keep a numeric value so the app never null-crashes.
  float safeValue = isnan(value) ? (latestValid[idx] ? latestValue[idx] : 0.0f) : value;
  latestValue[idx] = safeValue;
  latestValid[idx] = connected;

  FirebaseJson json;
  json.set("value", (double)safeValue);
  json.set("timestamp", ms);          // milliseconds
  json.set("connected", connected);
  if (!Firebase.setJSON(fbData, String("/sensors/") + id, json)) {
    Serial.printf("Failed /sensors/%s: %s\n", id, fbData.errorReason().c_str());
  }

  if (logHistory && connected) {
    // node key = ms (string); value/timestamp inside
    FirebaseJson h;
    h.set("value", (double)safeValue);
    h.set("timestamp", ms);
    Firebase.setJSON(fbData, String("/history/") + id + "/" + String((long long)ms), h);
  }

  if (connected) evaluateAlert(idx, safeValue, ms);
}

// ═════════════════════════════════════════════════════════════
// ALERTS  → /alerts/{pushKey}
// Mirrors SensorReading.status: alert when value < warningLow ||
// value > warningHigh. Resolves the open alert when back in range.
// ═════════════════════════════════════════════════════════════
void evaluateAlert(int idx, float value, double ms) {
  const SensorMeta& s = SENSORS[idx];
  bool breach = (value < s.warningLow || value > s.warningHigh);

  if (breach && activeAlertKey[idx].length() == 0) {
    FirebaseJson a;
    a.set("sensorId",    s.id);
    a.set("sensorLabel", s.label);
    a.set("value",       (double)value);
    a.set("unit",        s.unit);
    a.set("alertType",   "alert");      // "warning" | "alert"
    a.set("createdAt",   ms);
    a.set("isResolved",  false);
    if (Firebase.pushJSON(fbData, "/alerts", a)) {
      activeAlertKey[idx] = fbData.pushName();   // remember key to resolve later
      Serial.printf("ALERT raised: %s = %.2f\n", s.label, value);
    }
  } else if (!breach && activeAlertKey[idx].length() > 0) {
    FirebaseJson r;
    r.set("isResolved", true);
    r.set("resolvedAt", ms);
    Firebase.updateNode(fbData, String("/alerts/") + activeAlertKey[idx], r);
    Serial.printf("ALERT resolved: %s\n", s.label);
    activeAlertKey[idx] = "";
  }
}

// ═════════════════════════════════════════════════════════════
// DEVICES  →  /commands (in)  +  /devices (out)
// ═════════════════════════════════════════════════════════════
void syncDevices(double ms) {
  for (int i = 0; i < DEVICE_COUNT; i++) {
    applyCommand(i, ms);     // honor any pending app command
    runAutomation(i, ms);    // auto-mode devices react to sensors
  }
}

// Reads /commands/{id}; if status == "pending", applies it and ACKs.
void applyCommand(int i, double ms) {
  Device& d = DEVICES[i];
  String path = String("/commands/") + d.id;
  if (!Firebase.getJSON(fbData, path)) return;          // no command node yet
  FirebaseJson& json = fbData.jsonObject();
  FirebaseJsonData out;

  json.get(out, "status");
  if (!out.success || out.stringValue != "pending") return;  // already handled

  String modeStr = "auto";
  bool   target  = false;
  if (json.get(out, "mode"))        modeStr = out.stringValue;
  if (json.get(out, "targetState")) target  = out.boolValue;

  if (modeStr == "manual_on")       { d.mode = 1; d.isOn = true;  d.reason = "Manual override"; }
  else if (modeStr == "manual_off") { d.mode = 2; d.isOn = false; d.reason = "Manual override"; }
  else                              { d.mode = 0;                  d.reason = "Auto"; }
  if (d.mode != 0) d.isOn = target;   // manual: honor requested state

  relayWrite(d.relayPin, d.isOn);
  writeDeviceState(i, ms);

  // ACK back on the command node
  FirebaseJson ack;
  ack.set("status", "acknowledged");
  ack.set("acknowledgedAt", ms);
  Firebase.updateNode(fbData, path, ack);
  Serial.printf("Command applied: %s mode=%s on=%d\n", d.id, modeStr.c_str(), d.isOn);
}

// Simple threshold automation for devices in auto mode (matches
// /config/automationRules). Uses small hysteresis margins.
void runAutomation(int i, double ms) {
  Device& d = DEVICES[i];
  if (d.mode != 0) return;   // only auto-mode devices

  bool desired = d.isOn;
  int it = sensorIndex("temperature");
  int ih = sensorIndex("humidity");
  int im = sensorIndex("moisture");
  int il = sensorIndex("light");

  if (strcmp(d.id, "exhaust_fan") == 0 && latestValid[it]) {
    if (latestValue[it] > 28.0) desired = true;
    else if (latestValue[it] <= 26.0) desired = false;
  } else if ((strcmp(d.id, "circulation_fan_1") == 0 ||
              strcmp(d.id, "circulation_fan_2") == 0) && latestValid[ih]) {
    if (latestValue[ih] > 75.0) desired = true;
    else if (latestValue[ih] <= 70.0) desired = false;
  } else if (strcmp(d.id, "pump") == 0 && latestValid[im]) {
    if (latestValue[im] < 60.0) desired = true;
    else if (latestValue[im] >= 65.0) desired = false;
  } else if (strcmp(d.id, "grow_light") == 0 && latestValid[il]) {
    if (latestValue[il] < 10000.0) desired = true;
    else if (latestValue[il] >= 12000.0) desired = false;
  }

  if (desired != d.isOn) {
    d.isOn = desired;
    d.reason = "Auto: threshold";
    relayWrite(d.relayPin, d.isOn);
    writeDeviceState(i, ms);
    Serial.printf("Automation: %s -> %s\n", d.id, d.isOn ? "ON" : "OFF");
  }
}

void writeDeviceState(int i, double ms) {
  Device& d = DEVICES[i];
  const char* modeStr = d.mode == 1 ? "manual_on" : d.mode == 2 ? "manual_off" : "auto";
  FirebaseJson j;
  j.set("label", d.label);
  j.set("icon", d.icon);
  j.set("isOn", d.isOn);
  j.set("mode", modeStr);
  j.set("lastTriggered", ms);
  j.set("triggerReason", d.reason);
  j.set("updatedBy", "esp32");
  Firebase.setJSON(fbData, String("/devices/") + d.id, j);
}

// ═════════════════════════════════════════════════════════════
// CONFIG SEED (run once; safe to re-run — it just overwrites config)
// ═════════════════════════════════════════════════════════════
void seedConfig() {
  for (int i = 0; i < SENSOR_COUNT; i++) {
    const SensorMeta& s = SENSORS[i];
    FirebaseJson c;
    c.set("label", s.label);
    c.set("unit", s.unit);
    c.set("min", (double)s.min);
    c.set("max", (double)s.max);
    c.set("warningLow", (double)s.warningLow);
    c.set("warningHigh", (double)s.warningHigh);
    c.set("icon", s.icon);
    Firebase.setJSON(fbData, String("/config/sensors/") + s.id, c);
  }

  // Automation rules (informational; mirrors the app's display).
  struct Rule { const char* sid; const char* did; double lo; double hi; const char* desc; };
  const Rule rules[] = {
    {"temperature", "exhaust_fan",       0,     28.0,  "Turn ON exhaust fan when temp > 28C, OFF when <= 26C"},
    {"humidity",    "circulation_fan_1", 0,     75.0,  "Turn ON circulation fans when RH > 75%, OFF when <= 70%"},
    {"moisture",    "pump",              60.0,  100,   "Run pump when moisture < 60%, stop when >= 65%"},
    {"light",       "grow_light",        10000, 99999, "Turn ON grow light when lux < 10,000"},
  };
  for (unsigned i = 0; i < sizeof(rules)/sizeof(rules[0]); i++) {
    FirebaseJson r;
    r.set("sensorId", rules[i].sid);
    r.set("deviceId", rules[i].did);
    r.set("triggerLow", rules[i].lo);
    r.set("triggerHigh", rules[i].hi);
    r.set("actionDescription", rules[i].desc);
    r.set("isActive", true);
    Firebase.setJSON(fbData, String("/config/automationRules/rule") + String(i), r);
  }
  Serial.println("Config seeded.");
}

void seedDevices() {
  double ms = nowMillis();
  for (int i = 0; i < DEVICE_COUNT; i++) {
    relayWrite(DEVICES[i].relayPin, DEVICES[i].isOn);
    writeDeviceState(i, ms);
  }
  Serial.println("Devices seeded.");
}
