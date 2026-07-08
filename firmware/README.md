# AuTOMATO ESP32 Firmware

Firmware that feeds the AuTOMATO Flutter app with live greenhouse data over
Firebase Realtime Database, and applies device commands from the app.

## Setup

1. Copy the secrets template and fill in your values:
   ```bash
   cp autmato_esp32/secrets.example.h autmato_esp32/secrets.h
   ```
   `secrets.h` is gitignored. If your `DATABASE_SECRET` was ever shared, regenerate
   it first (Firebase Console → Project Settings → Service accounts → Database
   secrets).

2. Install libraries (Arduino IDE / arduino-cli):
   - **Firebase ESP32 Client** by Mobizt (`FirebaseESP32`)
   - **Adafruit BME280** (+ Adafruit Unified Sensor)
   - **BH1750**
   - **NTPClient**
   - ESP32 board core (Espressif)

   > Tested against the same FirebaseESP32 (Mobizt) API style as the original
   > sketch (`FirebaseData`, `setDouble`, `jsonObject()`, `pushName()`). If you are
   > on the newer `Firebase_ESP_Client`, the JSON accessors differ slightly.

3. Wire relays to the GPIOs at the top of `autmato_esp32.ino`
   (`RELAY_*`). Set `RELAY_ACTIVE_LOW` to match your relay module.

4. Flash `autmato_esp32/autmato_esp32.ino`.

## What it writes / reads (RTDB contract)

| Path | Direction | Notes |
|------|-----------|-------|
| `/config/sensors/{id}` | write (boot) | label/unit/min/max/warning thresholds/icon |
| `/config/automationRules/*` | write (boot) | informational, mirrors app display |
| `/sensors/{id}` | write | `{ value, timestamp(ms), connected }` |
| `/history/{id}/{ms}` | write | throttled to once/min |
| `/system/lastSeen` | write | **milliseconds**, heartbeat each cycle |
| `/system/firmwareVersion` | write | |
| `/alerts/{pushKey}` | write | created on threshold breach, resolved on recovery |
| `/commands/{deviceId}` | read + ack | applies command, sets `status=acknowledged` |
| `/devices/{deviceId}` | write | real actuator state after applying command/automation |

All timestamps are **milliseconds since epoch** (the Flutter app uses
`DateTime.fromMillisecondsSinceEpoch`).

## Key behaviors

- **Timestamps in ms** via `setDouble` (avoids the 32-bit `setInt` overflow).
- **Device control**: polls `/commands/{id}` each cycle; manual mode honors the
  requested state, auto mode is driven by `runAutomation()`; state is written back
  to `/devices/{id}` and the command is acked.
- **Alerts**: one open alert per sensor; resolves automatically when back in range.
- **Always writes a numeric `value`** so the app's `(json['value'] as num)` never
  hits null. The app currently ignores `connected` — handling it is part of the
  upcoming app-side (b) work.
