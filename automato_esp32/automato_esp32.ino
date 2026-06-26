// ═══════════════════════════════════════════════════════════════
// AuTOMATO — ESP32 Greenhouse Firmware (v2.1.2)
//
// Updated: Calibrated sensor formulas applied
//          pH, TDS, Moisture calibrated with buffer solutions
//          BH1750 replaced with simulated lux (25-50)
//          Pin assignments aligned with hardware wiring
//          MOISTURE PIN CHANGED: 32 → 36 (conflict with pump relay)
//
// Hardware Wiring (30-pin ESP32):
//   • PH-4502C:    GPIO 33 (with 2:1 voltage divider)
//   • TDS v1.0:    GPIO 34 (direct)
//   • Moisture v2.0: GPIO 36 (direct) ← CHANGED
//   • BME280:      SDA=GPIO21, SCL=GPIO22
//   • IN1 (GPIO 25): Exhaust Fan (12V DC)
//   • IN2 (GPIO 14): Circulation Fans 1 & 2 (shared relay, 12V DC)
//   • IN4 (GPIO 26): LED Grow Light (AC 50W)
//   • IN5 (GPIO 32): Submersible Water Pump (AC 20W)
//
// Relay Module: Active-LOW (LOW = ON, HIGH = OFF)
// Power: Smart Wall Adapter 5V/3.5A via ESP32 VIN
// ═══════════════════════════════════════════════════════════════

#include <WiFi.h>
#include <FirebaseESP32.h>
#include <Wire.h>
#include <Adafruit_BME280.h>
#include <NTPClient.h>
#include <WiFiUdp.h>

#include "secrets.h"

// ── Analog pin assignments (CALIBRATED) ─────────────────────
#define PIN_PH          33   // pH-4502C with 2:1 divider
#define PIN_TDS         34   // TDS v1.0 direct
#define PIN_MOISTURE    36   // ← CHANGED: Capacitive Moisture v2.0 direct (was 32)

// ── Relay GPIOs (aligned with actual hardware wiring) ─────────
#define RELAY_EXHAUST_FAN     25
#define RELAY_CIRC_FANS       14
#define RELAY_GROW_LIGHT      26
#define RELAY_PUMP            32   // Pump relay (no conflict now)

#define RELAY_ACTIVE_LOW      true

// ── Staggered Switching Delays ────────────────────────────────
#define RELAY_STAGGER_ON_MS   1000
#define RELAY_STAGGER_OFF_MS  800

// ── CALIBRATED SENSOR CONSTANTS ─────────────────────────────
// pH-4502C (2:1 voltage divider, calibrated with pH 4.01, 6.86, 9.18)
const float PH_PIN_V_401 = 1.353;    // Voltage at GPIO33 in pH 4.01
const float PH_PIN_V_686 = 1.101;    // Voltage at GPIO33 in pH 6.86
const float PH_SLOPE = 0.0880;       // V per pH unit at pin level
const float PH_OFFSET = 0.05;        // Final offset correction

// TDS v1.0 (direct wiring, calibrated with distilled water + 1.4 EC)
const float TDS_VOLTAGE_0EC = 0.000;   // Voltage in distilled water
const float TDS_VOLTAGE_14EC = 1.104;  // Voltage in 1.4 EC solution
const float TDS_EC_SLOPE = TDS_VOLTAGE_14EC / 1.4;  // V per mS/cm

// Moisture v2.0 (direct wiring, calibrated with dry air + water)
const float MOIST_VOLTAGE_DRY = 2.495;   // Voltage in dry air
const float MOIST_VOLTAGE_WET = 1.610;   // Voltage in water

// BME280 (calibrated with Lopez, Quezon weather reference)
const float TEMP_OFFSET = 2.5;    // BME280 reads 2.5°C high
const float HUM_OFFSET = -11.5;   // BME280 reads 11.5% low (or weather app high)

// ── Timing ────────────────────────────────────────────────────
#define UPLOAD_INTERVAL_MS   5000
#define HISTORY_INTERVAL_MS  60000

// ── Disconnection thresholds ──────────────────────────────────
#define DISCONNECTED_LOW     100
#define DISCONNECTED_HIGH    4000
#define DISCONNECT_THRESHOLD 3

// ── Valid ranges ──────────────────────────────────────────────
#define TEMP_MIN_VALID      -50.0f
#define TEMP_MAX_VALID      100.0f
#define HUMIDITY_MIN_VALID  0.0f
#define HUMIDITY_MAX_VALID  100.0f
#define LUX_MIN_VALID       0.0f

#define FW_VERSION          "2.1.3"

// ─────────────────────────────────────────────────────────────
FirebaseData   fbData;
FirebaseAuth   fbAuth;
FirebaseConfig fbConfig;

Adafruit_BME280 bme;

WiFiUDP   ntpUDP;
NTPClient timeClient(ntpUDP, "pool.ntp.org", 28800, 60000);

unsigned long lastUpload  = 0;
unsigned long lastHistory = 0;

int moistureDisconnectCount = 0;
int phDisconnectCount       = 0;
int tdsDisconnectCount      = 0;

// ─────────────────────────────────────────────────────────────
// SENSOR METADATA
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
// DEVICE TABLE
// ─────────────────────────────────────────────────────────────
struct Device {
  const char* id;
  const char* label;
  const char* icon;
  int   relayPin;
  bool  isOn;
  int   mode;          // 0 auto / 1 manual_on / 2 manual_off
  const char* reason;
};

Device DEVICES[] = {
  {"exhaust_fan",       "Exhaust Fan",       "air",        RELAY_EXHAUST_FAN, false, 0, "Auto"},
  {"circulation_fans",  "Circulation Fans",  "cyclone",    RELAY_CIRC_FANS,   false, 0, "Auto"},
  {"grow_light",        "LED Grow Light",    "light_mode", RELAY_GROW_LIGHT,  false, 0, "Auto"},
  {"pump",              "Submersible Pump",  "water",      RELAY_PUMP,        false, 0, "Auto"},
};
const int DEVICE_COUNT = sizeof(DEVICES) / sizeof(DEVICES[0]);

int deviceIndex(const char* id) {
  for (int i = 0; i < DEVICE_COUNT; i++)
    if (strcmp(DEVICES[i].id, id) == 0) return i;
  return -1;
}

// ── Batch command structure ─────────────────────────────────
struct PendingCommand {
  int deviceIndex;
  bool targetState;
  int mode;
  String reason;
  unsigned long timestamp;
};

float latestValue[8];
bool  latestValid[8];
String activeAlertKey[8];

// Command deduplication: track last processed timestamp per device
unsigned long lastCommandTimestamp[DEVICE_COUNT] = {0};

// ─────────────────────────────────────────────────────────────
// TIME HELPERS
// ─────────────────────────────────────────────────────────────
double nowMillis() {
  return (double)timeClient.getEpochTime() * 1000.0;
}

void writeMs(const String& path, double ms) {
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

  // ── Relays default OFF ────────────────────────────────────
  for (int i = 0; i < DEVICE_COUNT; i++) {
    pinMode(DEVICES[i].relayPin, OUTPUT);
    relayWrite(DEVICES[i].relayPin, false);
  }
  Serial.println("All relays OFF (safe state)");

  // ── Sensors ────────────────────────────────────────────────
  if (!bme.begin(0x76) && !bme.begin(0x77)) {
    Serial.println("BME280 not found");
  } else {
    Serial.println("BME280 OK");
  }

  analogReadResolution(12);
  analogSetAttenuation(ADC_11db);

  for (int i = 0; i < 8; i++) { latestValid[i] = false; activeAlertKey[i] = ""; }

  // ── WiFi ───────────────────────────────────────────────────
  Serial.print("Connecting to WiFi");
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  while (WiFi.status() != WL_CONNECTED) { delay(500); Serial.print("."); }
  Serial.println("\nWiFi connected: " + WiFi.localIP().toString());

  // ── NTP ────────────────────────────────────────────────────
  timeClient.begin();
  timeClient.setTimeOffset(28800);
  Serial.print("Syncing NTP");
  unsigned long ntpStart = millis();
  while (!timeClient.update() && millis() - ntpStart < 15000) {
    delay(500); Serial.print(".");
  }
  Serial.println(timeClient.getEpochTime() > 100000 ? "\nNTP synced" : "\nNTP timeout");

  // ── Firebase ───────────────────────────────────────────────
  fbConfig.database_url = DATABASE_URL;
  fbConfig.signer.tokens.legacy_token = DATABASE_SECRET;
  Firebase.begin(&fbConfig, &fbAuth);
  Firebase.reconnectWiFi(true);
  fbData.setResponseSize(4096);
  Serial.println("Firebase connected");

  seedConfig();
  seedDevices();

  writeMs("/system/lastSeen", nowMillis());
  Firebase.setString(fbData, "/system/firmwareVersion", FW_VERSION);
  Serial.println("Setup complete. Firmware v" FW_VERSION);
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

  readSensors(ms, logHistory);
  syncDevices(ms);

  writeMs("/system/lastSeen", ms);
  Serial.println("---- cycle done ----");
}

// ═════════════════════════════════════════════════════════════
// SENSORS — CALIBRATED FORMULAS
// ═════════════════════════════════════════════════════════════
void readSensors(double ms, bool logHistory) {
  // BME280
  float temperature = bme.readTemperature();
  float humidity    = bme.readHumidity();
  bool bmeOk = (!isnan(temperature) && !isnan(humidity) &&
                temperature > TEMP_MIN_VALID && temperature < TEMP_MAX_VALID &&
                humidity > HUMIDITY_MIN_VALID && humidity < HUMIDITY_MAX_VALID);
  pushSensor("temperature", temperature - TEMP_OFFSET, bmeOk, ms, logHistory);
  pushSensor("humidity",    humidity - HUM_OFFSET,     bmeOk, ms, logHistory);

  // Simulated Lux (BH1750 faulty)
  float lux = getSimulatedLux();
  pushSensor("light", lux, true, ms, logHistory);

  // Moisture (Capacitive v2.0, calibrated) — PIN 36
  int rawMoist = analogRead(PIN_MOISTURE);
  bool moistRaw = (rawMoist > DISCONNECTED_LOW && rawMoist < DISCONNECTED_HIGH);
  if (moistRaw) {
    if (moistureDisconnectCount > 0) moistureDisconnectCount--;
    float voltage = rawMoist * (3.3f / 4095.0f);
    float pct = calculateMoisture(voltage);
    pushSensor("moisture", pct, true, ms, logHistory);
  } else if (++moistureDisconnectCount >= DISCONNECT_THRESHOLD) {
    pushSensor("moisture", latestValue[sensorIndex("moisture")], false, ms, logHistory);
  }

  // pH (pH-4502C with 2:1 divider, calibrated)
  int rawPH = readAnalogAvg(PIN_PH);
  bool phRaw = (rawPH > DISCONNECTED_LOW && rawPH < DISCONNECTED_HIGH);
  if (phRaw) {
    if (phDisconnectCount > 0) phDisconnectCount--;
    float voltage = rawPH * (3.3f / 4095.0f);
    float ph = calculatePH(voltage);
    pushSensor("ph", ph, true, ms, logHistory);
  } else if (++phDisconnectCount >= DISCONNECT_THRESHOLD) {
    pushSensor("ph", latestValue[sensorIndex("ph")], false, ms, logHistory);
  }

  // TDS → EC (TDS v1.0, calibrated)
  int rawTDS = readAnalogAvg(PIN_TDS);
  bool tdsRaw = (rawTDS > DISCONNECTED_LOW && rawTDS < DISCONNECTED_HIGH);
  if (tdsRaw) {
    if (tdsDisconnectCount > 0) tdsDisconnectCount--;
    float voltage = rawTDS * (3.3f / 4095.0f);
    float ec = calculateEC(voltage);
    pushSensor("ec", ec, true, ms, logHistory);
  } else if (++tdsDisconnectCount >= DISCONNECT_THRESHOLD) {
    pushSensor("ec", latestValue[sensorIndex("ec")], false, ms, logHistory);
  }
}

// ── CALIBRATED CALCULATION HELPERS ──────────────────────────

float calculatePH(float voltage) {
  // Two-point calibration: pH 6.86 as reference
  float pH = 6.86f + (PH_PIN_V_686 - voltage) / PH_SLOPE - PH_OFFSET;
  if (pH < 0.0f) pH = 0.0f;
  if (pH > 14.0f) pH = 14.0f;
  return pH;
}

float calculateEC(float voltage) {
  // Linear calibration: distilled water = 0 EC, 1.4 EC solution = 1.104V
  if (TDS_EC_SLOPE == 0.0f) return 0.0f;
  float ec = (voltage - TDS_VOLTAGE_0EC) / TDS_EC_SLOPE;
  if (ec < 0.0f) ec = 0.0f;
  if (ec > 5.0f) ec = 5.0f;
  return ec;
}

float calculateMoisture(float voltage) {
  // Two-point calibration: dry air = 0%, water = 100%
  float m = (MOIST_VOLTAGE_DRY - voltage) / (MOIST_VOLTAGE_DRY - MOIST_VOLTAGE_WET) * 100.0f;
  if (m < 0.0f) m = 0.0f;
  if (m > 100.0f) m = 100.0f;
  return m;
}

// Simulated lux (BH1750 faulty, replaced with 25-50 range)
float getSimulatedLux() {
  return random(250, 500) / 10.0f;  // 25.0 to 50.0
}

int readAnalogAvg(int pin) {
  long sum = 0;
  for (int i = 0; i < 10; i++) { sum += analogRead(pin); delay(10); }
  return (int)(sum / 10);
}

void pushSensor(const char* id, float value, bool connected, double ms, bool logHistory) {
  int idx = sensorIndex(id);
  if (idx < 0) return;

  float safeValue = isnan(value) ? (latestValid[idx] ? latestValue[idx] : 0.0f) : value;
  latestValue[idx] = safeValue;
  latestValid[idx] = connected;

  FirebaseJson json;
  json.set("value", (double)safeValue);
  json.set("timestamp", ms);
  json.set("connected", connected);
  if (!Firebase.setJSON(fbData, String("/sensors/") + id, json)) {
    Serial.printf("Failed /sensors/%s: %s\n", id, fbData.errorReason().c_str());
  }

  if (logHistory && connected) {
    FirebaseJson h;
    h.set("value", (double)safeValue);
    h.set("timestamp", ms);
    Firebase.setJSON(fbData, String("/history/") + id + "/" + String((long long)ms), h);
  }

  if (connected) evaluateAlert(idx, safeValue, ms);
}

// ═════════════════════════════════════════════════════════════
// ALERTS
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
    a.set("alertType",   "alert");
    a.set("createdAt",   ms);
    a.set("isResolved",  false);
    if (Firebase.pushJSON(fbData, "/alerts", a)) {
      activeAlertKey[idx] = fbData.pushName();
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
// DEVICES — BATCH COMMAND COLLECTION + STAGGERED SWITCHING
// ═════════════════════════════════════════════════════════════
void syncDevices(double ms) {
  // ── STEP 1: Collect all pending commands ───────────────────
  PendingCommand pending[DEVICE_COUNT];
  int pendingCount = 0;

  for (int i = 0; i < DEVICE_COUNT; i++) {
    Device& d = DEVICES[i];
    String path = String("/commands/") + d.id;

    if (!Firebase.getJSON(fbData, path)) continue;
    FirebaseJson& json = fbData.jsonObject();
    FirebaseJsonData out;

    json.get(out, "status");
    if (!out.success || out.stringValue != "pending") continue;

    String modeStr = "auto";
    bool target = false;
    unsigned long cmdTimestamp = 0;
    if (json.get(out, "mode")) modeStr = out.stringValue;
    if (json.get(out, "targetState")) target = out.boolValue;
    if (json.get(out, "timestamp")) cmdTimestamp = (unsigned long)out.intValue;

    int mode = (modeStr == "manual_on") ? 1 : (modeStr == "manual_off") ? 2 : 0;

    // Arduino C++ doesn't support brace init with String - assign fields individually
    pending[pendingCount].deviceIndex = i;
    pending[pendingCount].targetState = target;
    pending[pendingCount].mode = mode;
    pending[pendingCount].reason = "Manual override";
    pending[pendingCount].timestamp = cmdTimestamp;
    pendingCount++;

    // ACK immediately (don't wait for stagger)
    FirebaseJson ack;
    ack.set("status", "acknowledged");
    ack.set("acknowledgedAt", ms);
    Firebase.updateNode(fbData, path, ack);
  }

  // ── STEP 2: Apply all commands in staggered sequence ──────
  if (pendingCount > 0) {
    Serial.printf("=== BATCH: Applying %d commands with %dms stagger ===\n",
                  pendingCount, RELAY_STAGGER_ON_MS);
    for (int i = 0; i < pendingCount; i++) {
      Device& d = DEVICES[pending[i].deviceIndex];
      d.mode = pending[i].mode;
      d.isOn = pending[i].targetState;
      d.reason = pending[i].reason.c_str();

      relayWrite(d.relayPin, d.isOn);

      // Update timestamp tracking for deduplication
      if (pending[i].timestamp > 0) {
        lastCommandTimestamp[pending[i].deviceIndex] = pending[i].timestamp;
      }

      Serial.printf("  [%d/%d] %s: %s (pin %d)\n",
                    i + 1, pendingCount, d.label,
                    d.isOn ? "ON" : "OFF", d.relayPin);

      // CRITICAL: Write to /devices immediately so Flutter sees the change
      writeDeviceState(pending[i].deviceIndex, ms);

      // Stagger delay (skip after last device)
      if (i < pendingCount - 1) {
        unsigned long staggerMs = d.isOn ? RELAY_STAGGER_ON_MS : RELAY_STAGGER_OFF_MS;
        Serial.printf("  ... staggering %lu ms ...\n", staggerMs);
        delay(staggerMs);
      }
    }

    // Mark all commands as completed
    for (int i = 0; i < pendingCount; i++) {
      Device& d = DEVICES[pending[i].deviceIndex];
      String path = String("/commands/") + d.id;
      FirebaseJson done;
      done.set("status", "completed");
      done.set("completedAt", ms);
      done.set("executedBy", "esp32");
      Firebase.updateNode(fbData, path, done);
    }

    Serial.println("=== BATCH complete ===");
  }

  // ── STEP 3: Run automation (skip devices that were commanded) ─
  for (int i = 0; i < DEVICE_COUNT; i++) {
    bool wasCommanded = false;
    for (int j = 0; j < pendingCount; j++) {
      if (pending[j].deviceIndex == i) { wasCommanded = true; break; }
    }
    if (!wasCommanded) runAutomation(i, ms);
  }
}

// Automation with staggered switching
void runAutomation(int i, double ms) {
  Device& d = DEVICES[i];
  if (d.mode != 0) return;

  bool desired = d.isOn;
  int it = sensorIndex("temperature");
  int ih = sensorIndex("humidity");
  int im = sensorIndex("moisture");
  int il = sensorIndex("light");

  if (strcmp(d.id, "exhaust_fan") == 0 && latestValid[it]) {
    if (latestValue[it] > 28.0) desired = true;
    else if (latestValue[it] <= 26.0) desired = false;
  } else if (strcmp(d.id, "circulation_fans") == 0 && latestValid[ih]) {
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

    // Stagger delay to protect power supply
    unsigned long staggerMs = d.isOn ? RELAY_STAGGER_ON_MS : RELAY_STAGGER_OFF_MS;
    Serial.printf("Automation: %s -> %s (stagger %lu ms)\n",
                  d.id, d.isOn ? "ON" : "OFF", staggerMs);
    delay(staggerMs);

    writeDeviceState(i, ms);
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
// CONFIG SEED
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

  struct Rule { const char* sid; const char* did; double lo; double hi; const char* desc; };
  const Rule rules[] = {
    {"temperature", "exhaust_fan",       0,     28.0,  "Turn ON exhaust fan when temp > 28C, OFF when <= 26C"},
    {"humidity",    "circulation_fans",  0,     75.0,  "Turn ON circulation fans when RH > 75%, OFF when <= 70%"},
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